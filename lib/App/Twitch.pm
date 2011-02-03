package App::Twitch;
# ABSTRACT: Your personal Twitter b...... lalalala

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

# could be flexible, who cares.... ;)
use WWW::Shorten::Bitly;

# could be ... ah forget it :-P
use Net::Twitter;

our $VERSION ||= '0.0development';

after start => sub {
	my $self = shift;
	return unless $self->is_daemon;
	POE::Kernel->run;
};

has '+pidbase' => (
	default => sub { getcwd },
);

has '+use_logger_singleton' => (
	traits => [ 'NoGetopt' ],
);

has '+progname' => (
	default => sub { 'twitch' },
);

has '+logger' => (
	traits => [ 'NoGetopt' ],
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

has bitly_username => (
	isa => 'Str',
	is => 'ro',
	required => 1,
	documentation => 'bit.ly API Username',
);

has bitly_apikey => (
	isa => 'Str',
	is => 'ro',
	required => 1,
	documentation => 'bit.ly API Key',
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

has '+basedir' => (
	documentation => 'Basepath for configfile or pidfile (default: current directory)',
);

has '+pidfile' => (
	documentation => 'Filename for the pidfile (default: basedir/progname.pid)',
);

has '+progname' => (
	documentation => 'Name for the application, like configfile name base and so on (default: twitch)',
);

has '+foreground' => (
	documentation => 'Run on the console and don\'t detach into background (default: off)',
);

has '+configfile' => (
	default => sub { 'twitch.yml' },
	documentation => 'Configuration file used for all those settings (default: twitch.yml)',
);

has '+pidbase' => (
	default => sub {
		my $self = shift;
		$self->tmpdir;
	},
	documentation => 'Directory for the pid file (default: working directory)',
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

#--------------------------------------------------------

has _containers => (
	traits  => [ 'NoGetopt', 'Array' ],
	is      => 'ro',
	isa     => 'ArrayRef[Text::Keywords::Container]',
	lazy    => 1,
	default => sub {
		my ( $self ) = @_;
		$self->logger->debug('Generating all Keywords::Container');
		my @containers;
		for (@{$self->blockercontainer}) {
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
				params => {
					blocker => 1,
				},
			);
		}
		for (@{$self->triggercontainer}) {
			$self->logger->debug('Preparing Keywords::Container for triggercontainer');
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
				params => {
					trigger => 1,
				},
			);
		}
		for (@{$self->container}) {
			$self->logger->debug('Preparing Keywords::Container for container');
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
			);
		}
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
		$self->logger->debug('Startup Bit.ly Shorten Service...');
		return POE::Component::WWW::Shorten->spawn(
			alias => $self->_shorten_alias,
			type => 'Bitly',
			params => [ $self->bitly_username, $self->bitly_apikey ],
		);
	},
);

has _shorten_alias => (
	is => 'rw',
	isa => 'Str',
	traits => [ 'NoGetopt' ],
	default => sub { 'shorten' },
);

sub START {
	my ( $self, $session ) = @_[ OBJECT, SESSION ];
	$self->logger->info('Starting up... '.__PACKAGE__);
	$self->logger->debug('Assigning POE::Session');
	$self->_session($session);
	$self->_containers;
	$self->_twitter;
	$self->_tweet;
	$self->_keywords;
	$self->_feedaggregator;
	$self->_shorten;
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
	my $event = {
		entry => $entry,
	};
	$self->logger->debug('New feed entry: '.$entry->link);
	my $url = $entry->link;
	$url =~ s/ //g;
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
	if ($response->code == 200) {
		my $extractor = HTML::ExtractContent->new;
		my $content = $response->decoded_content;
		my $title = $event->{entry}->title;
		if (!utf8::is_utf8($content)) {
			$self->logger->debug('Recode content fetched from: '.$event->{entry}->link);
			$content = decode("Detect", $content);
		}		
		if (utf8::is_utf8($content)) {
			$self->logger->debug('New content fetched from: '.$event->{entry}->link);
			$extractor->extract($content);
			my @keywords = $self->_keywords->from($title, $extractor->as_text);
			if ($self->debug) {
				my @keywords_text;
				for (@keywords) {
					push @keywords_text, $_->found;
				}
				$self->logger->debug('Keywords found: |'.join("|",@keywords_text).'|');
			}
			if ( $keywords[0] && $keywords[0]->container->params->{blocker} ) {
				$self->logger->debug('Blocker found, ignoring entry');
			} elsif ( $self->tweet_everything || ( $keywords[0] && $keywords[0]->container->params->{trigger} ) ) {
				$event->{keywords} = \@keywords;
				$self->logger->debug('Trigger keyword found in: '.$title);
				my $url = $event->{entry}->link;
				$url =~ s/ //g;
				$self->_shorten->shorten({
					url => $url,
					event => 'new_shortened',
					_twitch_event => $event,
				});
			}
		} else {
			$self->logger->debug('Is no UTF8 from: '.$event->{entry}->link);
		}
	} else {
		$self->logger->error('HTTP Code '.$response->code.' on: '.$event->{entry}->link);
	}
};

event new_shortened => sub {
	my ( $self, $returned ) = @_[ OBJECT, ARG0..$#_ ];
	my $event = $returned->{_twitch_event};
	my $title = $event->{entry}->title;
	my $content = $event->{content};
	my $url = $event->{entry}->link;
	$url =~ s/ //g;
	my @keywords = @{$event->{keywords}};
	if ($returned->{short}) {
		$self->logger->debug('Received ShortURL for: '.$url);
		my $short = $returned->{short};
		my @keywords_text;
		for (@keywords) {
			push @keywords_text, $_->found;
		}
		$self->twitter_update($self->_tweet->make(\@keywords_text,$title,\$short));
	} else {
		$self->logger->error('Failing generation of ShortURL for: '.$event->{entry}->link);
	}
};

sub twitter_update {
	my ( $self, $text ) = @_;
	$self->logger->info('Twitter update: '.$text);
	if (!$self->dryrun) {
		eval {
			$self->_twitter->update({ status => $text });
		};
		if ($@) {
			$self->logger->error('ERROR [twitter]: '.$@);
			return 0;
		}
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
