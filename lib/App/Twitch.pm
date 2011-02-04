package App::Twitch;
# ABSTRACT: Your personal Twitter b...... lalalala

sub POE::Kernel::USE_SIGCHLD () { 1 }
use MooseX::POE;

with qw(
	MooseX::Getopt
	MooseX::SimpleConfig
	MooseX::LogDispatch
	MooseX::Daemonize
);

use POE qw(
	Component::Client::HTTP
	Component::Client::Keepalive
	Component::FeedAggregator
	Component::WWW::Shorten
);

use HTTP::Request;
use Text::Trim;
use URI;
use POSIX;
use IO::All;
use String::Truncate qw(elide);
use utf8;
use Text::Keywords;
use Text::Keywords::Container;
use Text::Keywords::List;
use Text::Tweet;
use HTML::ExtractContent;
use Carp qw( croak );

# could be ... ah forget it :-P
use Net::Twitter;

our $VERSION ||= '0.0development';

after start => sub {
	my $self = shift;
	return unless $self->is_daemon;
	POE::Kernel->run;
};

has '+basedir' => (
	documentation => 'Basepath for configfile or pidfile (default: current directory)',
);

has '+pidbase' => (
	default => sub { shift->tmpdir },
	documentation => 'Directory for the pid file (default: tmpdir)',
);

has '+pidfile' => (
	documentation => 'Filename for the pidfile (default: basedir/progname.pid)',
);

has '+use_logger_singleton' => (
	traits => [ 'NoGetopt' ],
);

has '+progname' => (
	default => sub { 'twitch' },
	documentation => 'Name for the application, like configfile name base and so on (default: twitch)',
);

has '+logger' => (
	traits => [ 'NoGetopt' ],
);

has '+foreground' => (
	documentation => 'Run on the console and don\'t detach into background (default: off)',
);

has '+configfile' => (
	default => sub { 'twitch.yml' },
	documentation => 'Configuration file used for all those settings (default: twitch.yml)',
);

has log_dispatch_conf => (
	is => 'ro',
	isa => 'HashRef',
	lazy => 1,
	required => 1,
	traits => [ 'NoGetopt' ],
	default => sub {
		my $self = shift;
		return {} if $self->no_logging;
		my $format = '[%p] %m';
		my $minlevel = $self->debug ? 'debug' : 'info';
		if ($self->foreground || !$self->logfile) {
			return {
				class     => 'Log::Dispatch::Screen',
				min_level => $minlevel,
				stderr    => 1,
				format    => $format,
				newline		=> 1,
			}
		} else {
			return {
				class		=> 'Log::Dispatch::File',
				min_level	=> $minlevel,
				filename	=> $self->configdir.'/'.$self->logfile,
				mode		=> '>>',
				format		=> '[%d] '.$format,
				newline		=> 1,
			}
		}
	},
);

sub run {
	my ( $self ) = @_;
	POE::Kernel->run;
	if (!blessed $self) {
		$self = $self->new_with_options;
	}
	my ( $command ) = @{$self->extra_argv};

	if (!defined $command) {
		if ($self->status) {
			print "App::Twitch already running...\n";
			exit 0;
		} else {
			$command = 'start';
		}
	}
	
	$self->start if $command eq 'start';
	if ($command eq 'status') {
		print "App::Twitch is ".( $self->status ? '' : 'not ')."running...\n";
		exit $self->status ? 0 : 1;
	}
	$self->restart if $command eq 'restart';
	$self->stop if $command eq 'stop';
	
	exit $self->exit_code;
}

has consumer_key => (
	isa => 'Str',
	is => 'ro',
	required => 1,
	documentation => 'Consumer Key of your Twitter application',
);

has consumer_secret => (
	isa => 'Str',
	is => 'ro',
	required => 1,
	documentation => 'Consumer Secret of your Twitter application',
);

has access_token => (
	isa => 'Str',
	is => 'ro',
	required => 1,
	documentation => 'Access Token of the Twitter user for the application',
);

has access_token_secret => (
	isa => 'Str',
	is => 'ro',
	required => 1,
	documentation => 'Access Token Secret of the Twitter user for the application',
);

has feeds => (
	traits  => [ 'Array' ],
	is      => 'ro',
	isa     => 'ArrayRef[Str]',
	default => sub {
		my $self = shift;
		my @lines;
		if ($self->feeds_file) {
			@lines = grep {
				$_ = trim($_);
				/^http:\/\//
			} io($self->feeds_file)->slurp;
		}
		return \@lines;
	},
	#documentation => 'Feeds (must be given via config file as array [TODO])',
	handles => {
		feeds_shift => 'shift',
		feeds_count => 'count',
	},
);

has feeds_file => (
	isa => 'Str',
	is => 'ro',
	default => sub { 'feeds.txt' },
	documentation => 'File with the list of Feeds (one per line, default: feeds.txt)',
);

has feed_delay => (
	isa => 'Int',
	is => 'ro',
	required => 1,
	default => sub { 600 },
	documentation => 'How often every feed should be checked in seconds (default: 600)',
);

has hashtags_at_end => (
	is => 'ro',
	default => sub { 0 },
	documentation => 'Put all hashtag keywords after the URL (default: 0)',
);

has dryrun => (
	is => 'ro',
	default => sub { 0 },
	documentation => 'Do not actually generate tweets, but do all other steps (default: 0)',
);

has dryrun_url => (
	is => 'ro',
	default => sub { 'http://xrl.us/DrYRuN' },
	documentation => 'ShortenURL used for the dryrun debugging informations (default: http://xrl.us/DrYRuN)',
);

has tweet_everything => (
	is => 'ro',
	default => sub { 0 },
	documentation => 'Do not require a trigger keyword in the RSS for a tweet (default: 0)',
);

has triggercontainer => (
	traits  => [ 'Array' ],
	is      => 'ro',
	isa     => 'ArrayRef',
	default => sub {[]},
	documentation => 'Give list of triggering keyword files (comma seperated list of filenames)',
);

has container => (
	traits  => [ 'Array' ],
	is      => 'ro',
	isa     => 'ArrayRef',
	default => sub {[]},
	documentation => 'Give list of keyword files (comma seperated list of filenames)',
);

has blockercontainer => (
	traits  => [ 'Array' ],
	is      => 'ro',
	isa     => 'ArrayRef',
	default => sub {[]},
	documentation => 'Give list of keyword files, which block tweeting that entry (comma seperated list of filenames)',
);

has shorten_type => (
	isa => 'Str',
	is => 'ro',
	required => 1,
	default => sub { 'Metamark' },
	documentation => 'Which shorten service to be used, see WWW::Shorten (default: Metamark)',
);

has shorten_params => (
	isa => 'ArrayRef',
	is => 'ro',
	required => 1,
	default => sub {[]},
	documentation => 'Parameter used for the WWW::Shorten call, see WWW::Shorten (default: none)',
);

has tmpdir => (
	isa => 'Str',
	is => 'ro',
	required => 1,
	default => sub { getcwd },
	documentation => 'Temp directory for the application (default: working directory)',
);

has configdir => (
	isa => 'Str',
	is => 'ro',
	required => 1,
	default => sub { getcwd },
	documentation => 'Configuration directory for the application (default: working directory)',
);

has debug => (
	isa => 'Bool',
	is => 'ro',
	default => sub { 0 },
	documentation => 'Write debugging into logfile (default: 0)',
);

has no_logging => (
	isa => 'Bool',
	is => 'ro',
	default => sub { 0 },
	documentation => 'Do not log on screen or file (default: 0)',
);

has logfile => (
	isa => 'Str',
	is => 'ro',
	default => sub { 'twitch.log' },
	documentation => 'Name of the logfile in the configuration directory (default: twitch.log)',
);

has ignore_first => (
	isa => 'Str',
	is => 'ro',
	required => 1,
	default => sub { 1 },
	documentation => 'When no cache file exist, ignore the first incoming feed news (default: 1)',
);

has http_agent => (
	isa => 'Str',
	is => 'ro',
	default => sub { __PACKAGE__.'/'.$VERSION },
	documentation => 'HTTP-agent to be used for the HTTP request to fetch the content (default: App::Twitch/VERSION)',
);

# No idea why this doesn't work....
has [ '+no_double_fork', '+ignore_zombies', '+dont_close_all_files', '+stop_timeout' ] => (
	documentation => 'Please see MooseX::Daemonize documentation',
);

#--------------------------------------------------------

sub _generate_containers {
	my ( $self, $array, $params ) = @_;
	my @containers;
	$params = {} if !$params;
	for (@{$array}) {
		$self->logger->debug('Preparing Keywords::Container for blockercontainer');
		my @lists;
		for (split(',',$_)) {
			$self->logger->debug('Preparing Keywords::List '.$_);
			my @lines = grep { $_ = trim($_); } io($self->configdir.'/'.$_)->slurp;
			push @lists, Text::Keywords::List->new(
				keywords => \@lines,
			);
		}
		push @containers, Text::Keywords::Container->new(
			lists => \@lists,
			params => $params,
		);
	}
	return @containers;
}

has _containers => (
	traits  => [ 'NoGetopt', 'Array' ],
	is      => 'ro',
	isa     => 'ArrayRef[Text::Keywords::Container]',
	lazy    => 1,
	default => sub {
		my ( $self ) = @_;
		$self->logger->debug('Generating all Keywords::Container');
		my @containers;
		push @containers, $self->_generate_containers($self->blockercontainer, { blocker => 1 });
		push @containers, $self->_generate_containers($self->triggercontainer, { trigger => 1 });
		push @containers, $self->_generate_containers($self->container);
		return \@containers;
	},
);

has _max_feeds_count => (
	traits => [ 'NoGetopt' ],
	isa => 'Int',
	is => 'ro',
	default => sub { shift->feeds_count },
);

has _feedaggregator => (
	traits  => [ 'NoGetopt' ],
	isa => 'POE::Component::FeedAggregator',
	is => 'ro',
	lazy => 1,
	default => sub {
		my $self = shift;
		$self->logger->debug('Starting POE::Component::FeedAggregator');
		POE::Component::FeedAggregator->new(
			tmpdir   => $self->tmpdir,
		);
	},
);

has _twitter => (
	traits  => [ 'NoGetopt' ],
	isa => 'Net::Twitter',
	is => 'ro',
	lazy => 1,
	default => sub {
		my $self = shift;
		$self->logger->debug('Starting Net::Twitter');
		Net::Twitter->new(
			traits   => [qw/ API::REST API::Search OAuth /],
			consumer_key		=> $self->consumer_key,
			consumer_secret		=> $self->consumer_secret,
			access_token		=> $self->access_token,
			access_token_secret	=> $self->access_token_secret,
		),
	},
);

has _session => (
	is => 'rw',
	isa => 'POE::Session',
	traits => [ 'NoGetopt' ],
);

has _keywords => (
	is => 'ro',
	isa => 'Text::Keywords',
	traits => [ 'NoGetopt' ],
	lazy => 1,
	default => sub {
		Text::Keywords->new(
			containers => shift->_containers,
		)
	},
);

has _tweet => (
	is => 'ro',
	isa => 'Text::Tweet',
	traits => [ 'NoGetopt' ],
	lazy => 1,
	default => sub {
		Text::Tweet->new()
	},
);

has _http_alias => (
	is => 'rw',
	isa => 'Str',
	traits => [ 'NoGetopt' ],
	default => sub { 'http' },
);

has _keepalive => (
	isa => 'POE::Component::Client::Keepalive',
	is => 'ro',
	traits => [ 'NoGetopt' ],
	lazy => 1,
	default => sub {
		POE::Component::Client::Keepalive->new(
			keep_alive    => 20, # seconds to keep connections alive
			max_open      => 100, # max concurrent connections - total
			max_per_host  => 100, # max concurrent connections - per host
			timeout       => 10, # max time (seconds) to establish a new connection
		)
	},
);

has _shorten => (
	isa => 'POE::Component::WWW::Shorten',
	is => 'ro',
	traits => [ 'NoGetopt' ],
	lazy => 1,
	default => sub {
		my ( $self ) = @_;
		$self->logger->debug('Startup '.$self->shorten_type.' Shorten Service...');
		return POE::Component::WWW::Shorten->spawn(
			alias => $self->_shorten_alias,
			type => $self->shorten_type,
			params => $self->shorten_params,
		);
	},
);

has _shorten_alias => (
	is => 'rw',
	isa => 'Str',
	traits => [ 'NoGetopt' ],
	default => sub { 'shorten' },
);

has _entry_count => (
	traits  => ['Counter'],
	is      => 'ro',
	isa     => 'Num',
	default => 0,
	handles => {
		_entry_count_inc => 'inc',
	},
);

sub START {
	my ( $self, $session ) = @_[ OBJECT, SESSION ];
	$self->logger->info('Starting up... '.__PACKAGE__);
	$self->logger->debug('Assigning POE::Session');
	$self->_session($session);
	$self->_containers;
	$self->_twitter if !$self->dryrun;
	$self->_tweet;
	$self->_keywords;
	$self->_feedaggregator;
	$self->_shorten if !$self->dryrun;
	$self->logger->debug('Startup HTTP Service...');
	POE::Component::Client::HTTP->spawn(
		Agent				=> $self->http_agent,
		Alias				=> $self->_http_alias,
		Timeout				=> 30,
		ConnectionManager	=> $self->_keepalive,
		FollowRedirects		=> 5,
	);
	$self->_max_feeds_count;
	$self->yield('add_feed');
}

event add_feed => sub {
	my ( $self, $kernel ) = @_[ OBJECT, KERNEL ];
	my $feed_url = $self->feeds_shift;
	$self->logger->info('Adding feed: '.$feed_url);
	eval {
		my $feed = {
			url				=> $feed_url,
			delay			=> $self->feed_delay,
			max_headlines	=> 100,
			ignore_first	=> $self->ignore_first,
		};
		$self->_feedaggregator->add_feed($feed);
	};
	$self->logger->error('ERROR ['.$feed_url.']: '.$@) if $@;
	my $delay = floor( $self->feed_delay / $self->_max_feeds_count );
	$kernel->delay('add_feed',$delay) if $self->feeds_count;
};

event new_feed_entry => sub {
	my ( $self, $feed, $entry ) = @_[ OBJECT, ARG0..$#_ ];
	$self->_entry_count_inc;
	my $url = $entry->link;
	$url =~ s/ //g;
	my $event = {
		entry => $entry,
		url => $url,
		run_id => $self->_entry_count,
	};
	$self->logger->debug('('.$event->{run_id}.') New feed entry: '.$url);
	POE::Kernel->post(
		$self->_http_alias,
		'request',
		'new_content',
		HTTP::Request->new(GET => $url),
		$event,
	);
};

use Encode;
require Encode::Detect;

event new_content => sub {
	my ( $self, $request_packet, $response_packet ) = @_[ OBJECT, ARG0..$#_ ];
	my $event = $request_packet->[1];
	my $response = $response_packet->[0];
	eval {
		if ($response->code == 200) {
			my $extractor = HTML::ExtractContent->new;
			my $content = $response->decoded_content;
			my $title = $event->{entry}->title;
			if (!utf8::is_utf8($content)) {
				$self->logger->debug('('.$event->{run_id}.') No utf8, trying recode content');
				$content = decode("Detect", $content);
			}
			if (utf8::is_utf8($content)) {
				$extractor->extract($content);
				my $extracted_text = $extractor->as_text;
				$self->logger->debug('('.$event->{run_id}.') Extracted content with '.length($extracted_text).' chars');
				$event->{content} = $extracted_text;
				my @keywords = $self->_keywords->from($title, $extracted_text);
				if ($self->debug && @keywords) {
					my @keywords_text;
					push @keywords_text, $_->found for (@keywords);
					$self->logger->debug('('.$event->{run_id}.') Keywords found: '.join(", ",@keywords_text));
				}
				if ( $keywords[0] && $keywords[0]->container->params->{blocker} ) {
					$self->logger->debug('('.$event->{run_id}.') Blocker found, ignoring entry');
				} elsif ( $self->tweet_everything || ( $keywords[0] && $keywords[0]->container->params->{trigger} ) ) {
					$event->{keywords} = \@keywords;
					$self->logger->debug('('.$event->{run_id}.') Trigger keyword found in: '.$title) if (!$self->tweet_everything);
					if ($self->dryrun) {
						$self->yield('new_shortened',{
							short => $self->dryrun_url,
							_twitch_event => $event,
						});
					} else {
						$self->_shorten->shorten({
							url => $event->{url},
							event => 'new_shortened',
							_twitch_event => $event,
						});
					}
				} else {
					$self->logger->debug('('.$event->{run_id}.') Yeah... what i care... doing nothing with it');
				}
			} else {
				$self->logger->debug('('.$event->{run_id}.') Is no UTF8');
			}
		} else {
			$self->logger->error('('.$event->{run_id}.') Wrong HTTP Code '.$response->code);
		}
	};
	$self->logger->error('('.$event->{run_id}.') ERROR [content handling]: '.$@) if $@;
};

event new_shortened => sub {
	my ( $self, $returned ) = @_[ OBJECT, ARG0..$#_ ];
	my $event = $returned->{_twitch_event};
	eval {
		my $title = $event->{entry}->title;
		my $content = $event->{content};
		my $url = $event->{url};
		my @keywords = @{$event->{keywords}};
		if ($returned->{short}) {
			$self->logger->debug('('.$event->{run_id}.') Received ShortURL');
			my $short = $returned->{short};
			my @keywords_text;
			for (@keywords) {
				push @keywords_text, $_->found;
			}
			$event->{tweet} = $self->_tweet->make(\@keywords_text,$title,\$short);
			$self->twitter_update($event);
		} else {
			$self->logger->error('('.$event->{run_id}.') Failing generation of ShortURL');
		}
	};
	$self->logger->error('('.$event->{run_id}.') ERROR [finalize and tweeting]: '.$@) if $@;
};

sub twitter_update {
	my ( $self, $event ) = @_;
	my $tweet = $event->{tweet};
	$self->logger->info('('.$event->{run_id}.') Twitter update: '.$tweet);
	if (!$self->dryrun) {
		eval {
			$self->_twitter->update({ status => $tweet });
		};
		if ($@) {
			$self->logger->error('('.$event->{run_id}.') ERROR [twitter]: '.$@);
			return 0;
		}
	} else {
		$self->logger->debug('('.$event->{run_id}.') dryrun set, not really twittering it!');
	}
	return 1;
}

__PACKAGE__->meta->make_immutable;

1;

__END__

=head1 DESCRIPTION

More documentation coming soon....

=head1 SEE ALSO

=for :list
* L<Net::Twitter>
* L<POE::Component::FeedAggregator>
* L<MooseX::POE>
