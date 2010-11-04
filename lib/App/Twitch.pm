package App::Twitch;
# ABSTRACT: Your personal Twitter b...... lalalala

use MooseX::POE;

with qw(
	MooseX::Getopt
	MooseX::LogDispatch
);

use POE qw(
	Component::RSSAggregator
);

use Data::Dumper;
use Text::Trim;
use URI;
use POSIX;
use IO::All;
use String::Truncate qw(elide);
use utf8;

# could be flexible, who cares.... ;)
use WWW::Shorten::Bitly;

# could be ... ah forget it :-P
use Net::Twitter;

has consumer_key => (
	isa => 'Str',
	is => 'ro',
	required => 1,
);

has consumer_secret => (
	isa => 'Str',
	is => 'ro',
	required => 1,
);

has access_token => (
	isa => 'Str',
	is => 'ro',
	required => 1,
);

has access_token_secret => (
	isa => 'Str',
	is => 'ro',
	required => 1,
);

has rss_file => (
	isa => 'Str',
	is => 'ro',
	required => 1,
	default => sub { 'rss.txt' },
);

has keyword_file => (
	isa => 'Str',
	is => 'ro',
	required => 1,
	default => sub { 'keyword.txt' },
);

has bitly_username => (
	isa => 'Str',
	is => 'ro',
	required => 1,
);

has bitly_apikey => (
	isa => 'Str',
	is => 'ro',
	required => 1,
);

has rss_delay => (
	isa => 'Int',
	is => 'ro',
	required => 1,
	default => sub { 100 },
);

has rss_headline_max => (
	isa => 'Int',
	is => 'ro',
	required => 1,
	default => sub { 3 },
);

has rss_ignore_first => (
	isa => 'Bool',
	is => 'ro',
	required => 1,
	default => sub { 1 },
);

has tmpdir => (
	isa => 'Str',
	is => 'ro',
	required => 1,
	default => sub { '/tmp' },
);

#--------------------------------------------------------

has feeds => (
	traits  => [ 'NoGetopt', 'Array' ],
	is      => 'ro',
	isa     => 'ArrayRef[Str]',
	lazy    => 1,
	default => sub {
		my ( $self ) = @_;
		$self->logger->debug('Getting feed list from '.$self->rss_file);
		my @lines = grep {
			$_ = trim($_);
			/^http:\/\//
		} io($self->rss_file)->slurp;
		return \@lines;
	},
	handles => {
		feeds_shift => 'shift',
		feeds_count => 'count',
	},
);

has keywords => (
	traits  => [ 'NoGetopt', 'Array' ],
	is      => 'ro',
	isa     => 'ArrayRef[Str]',
	lazy    => 1,
	default => sub {
		my ( $self ) = @_;
		$self->logger->debug('Getting keyword list from '.$self->keyword_file);
		my @lines = grep {
			$_ = trim($_);
		} io($self->keyword_file)->slurp;
		return \@lines;
	},
);

has max_feeds_count => (
	isa => 'Int',
	is => 'rw',
);

has rss => (
	traits  => [ 'NoGetopt' ],
	isa => 'POE::Component::RSSAggregator',
	is => 'ro',
	lazy => 1,
	default => sub {
		my $self = shift;
		$self->logger->debug('Starting POE::Component::RSSAggregator');
		POE::Component::RSSAggregator->new(
			alias    => 'rss',
			debug    => 5,
			callback => $self->session->postback('new_headline'),
			tmpdir   => $self->tmpdir,
		);
	},
);

has twitter => (
	traits  => [ 'NoGetopt' ],
	isa => 'Net::Twitter',
	is => 'ro',
	lazy => 1,
	default => sub {
		my $self = shift;
		$self->logger->debug('Starting Net::Twitter');
		Net::Twitter->new(
			traits   => [qw/API::REST API::Search OAuth/],
			consumer_key		=> $self->consumer_key,
			consumer_secret		=> $self->consumer_secret,
			access_token		=> $self->access_token,
			access_token_secret	=> $self->access_token_secret,
		),
	},
);

has session => (
	is => 'rw',
	isa => 'POE::Session',
);

has first_run => (
	is => 'ro',
	isa => 'HashRef',
	default => sub {{}},
);

sub START {
	my ( $self, $session ) = @_[ OBJECT, SESSION ];
	$self->logger->info('Starting up... '.__PACKAGE__.' '.$VERSION);
	$self->logger->debug('Assigning POE::Session');
	$self->session($session);
	$self->twitter;
	$self->rss;
	$self->logger->debug('Setting max_feeds_count to '.$self->feeds_count);
	$self->max_feeds_count($self->feeds_count);
	$self->yield('add_feed');
}

event add_feed => sub {
	my ( $self, $kernel ) = @_[ OBJECT, KERNEL ];
	my $feed_url = $self->feeds_shift;
	eval {
		my $uri = URI->new($feed_url);
		my $host = $uri->host;
		$host =~ s/\./_/g;
		my $line_number = $self->max_feeds_count - $self->feeds_count;
		my $feed = {
			url				=> $feed_url,
			name			=> $line_number.'_'.$host,
			delay			=> $self->rss_delay,
			max_headlines	=> 100,
			headline_as_id  => 1,
		};
		$kernel->post('rss','add_feed',$feed);
	};
	if ($@) {
		$self->logger->error('ERROR ['.$feed_url.']: '.$@);
	}
	my $delay = floor( $self->rss_delay / $self->max_feeds_count );
	$kernel->delay('add_feed',$delay) if $self->feeds_count;
};

event new_headline => sub {
	my ( $self, $arg ) = @_[ OBJECT, ARG1 ];
	my $feed = $arg->[0];
	my $count;
	if ( $self->first_run->{$feed->url} || !$self->rss_ignore_first) {
		for my $headline ( $feed->late_breaking_news ) {
			my $headline_text = $headline->headline;
			$self->logger->debug('New headline: '.$headline_text);
			my $text = $self->shorten_text($self->hashtag_keywords($headline_text));
			my $url = $self->shorten_url($headline->url);
			$self->twitter_update($text." ".$url) if $url;
			$count++;
			return if ($count >= $self->rss_headline_max);
		}
	} else {
		$self->logger->debug('First fetch of '.$feed->url.' ignored');
		$self->first_run->{$feed->url} = 1;
	}
};

sub hashtag_keywords {
	my ( $self, $text ) = @_;
	for (@{$self->keywords}) {
		$text =~ s/($_)/\#$1/i;
	}
	return $text;
}

sub twitter_update {
	my ( $self, $text ) = @_;
	$self->logger->info('Twitter update: '.$text);
	eval {
		$self->twitter->update({ status => $text });
	};
	if ($@) {
		$self->logger->error('ERROR [twitter]: '.$@);
		return 0;
	}
	return 1;
}


sub shorten_text {
	my ( $self, $text ) = @_;
	# twitter 140, bit.ly 20, 1 space, 1 buffer
	elide(trim($text), 140 - 20 - 1 - 1, {
		at_space => 1,
	});
}

sub shorten_url {
	my ( $self, $url ) = @_;
	my $shorten_url;
	eval {
		$shorten_url = makeashorterlink($url, $self->bitly_username, $self->bitly_apikey);
	};
	if ($@) {
		$self->logger->error('ERROR [bit.ly]: '.$@);
		return 0;
	}
	$self->logger->debug('From '.$url.' to '.$shorten_url);
	$shorten_url;
}

no MooseX::POE;
__PACKAGE__->meta->make_immutable;

1;

__END__

=head1 SYNOPSIS

  script/twitch --consumer_key 1a2b3c4d --consumer_secret 1a2b3c4d --access_token 1a2b3c4d --access_token_secret 1a2b3c4d \
    --rss_file rsss.txt --keywords_file keywords.txt --bitly_user username --bitly_apikey 1a2b3c4d

=head1 DESCRIPTION

Take it or leave it, so far just released for having it on CPAN. If you want provide docs, i would be happy. Also, 
its just a tool, its not based on an intelligent or effective design and just is made for a specific requirement case.

=head1 SEE ALSO

=for :list
* L<Net::Twitter>
