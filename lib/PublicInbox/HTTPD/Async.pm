# Copyright (C) 2016-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
#
# XXX This is a totally unstable API for public-inbox internal use only
# This is exposed via the 'pi-httpd.async' key in the PSGI env hash.
# The name of this key is not even stable!
# Currently is is intended for use with read-only pipes.
package PublicInbox::HTTPD::Async;
use strict;
use warnings;
use base qw(Danga::Socket);
use fields qw(cb cleanup);
require PublicInbox::EvCleanup;

sub new {
	my ($class, $io, $cb, $cleanup) = @_;
	my $self = fields::new($class);
	IO::Handle::blocking($io, 0);
	$self->SUPER::new($io);
	$self->{cb} = $cb;
	$self->{cleanup} = $cleanup;
	$self->watch_read(1);
	$self;
}

sub restart_read_cb ($) {
	my ($self) = @_;
	sub { $self->watch_read(1) }
}

sub main_cb ($$$) {
	my ($http, $fh, $bref) = @_;
	sub {
		my ($self) = @_;
		my $r = sysread($self->{sock}, $$bref, 8192);
		if ($r) {
			$fh->write($$bref);
			return if $http->{closed};
			if ($http->{write_buf_size}) {
				$self->watch_read(0);
				$http->write(restart_read_cb($self));
			}
			# stay in watch_read, but let other clients
			# get some work done, too.
			return;
		} elsif (!defined $r) {
			return if $!{EAGAIN} || $!{EINTR};
		}

		# Done! Error handling will happen in $fh->close
		# called by the {cleanup} handler
		$http->{forward} = undef;
		$self->close;
	}
}

sub async_pass {
	my ($self, $http, $fh, $bref) = @_;
	# In case the client HTTP connection ($http) dies, it
	# will automatically close this ($self) object.
	$http->{forward} = $self;
	$fh->write($$bref); # PublicInbox:HTTP::{chunked,identity}_wcb
	$self->{cb} = main_cb($http, $fh, $bref);
}

sub event_read { $_[0]->{cb}->(@_) }
sub event_hup { $_[0]->{cb}->(@_) }
sub event_err { $_[0]->{cb}->(@_) }
sub sysread { shift->{sock}->sysread(@_) }

sub close {
	my $self = shift;
	my $cleanup = $self->{cleanup};
	$self->{cleanup} = $self->{cb} = undef;
	$self->SUPER::close(@_);

	# we defer this to the next timer loop since close is deferred
	PublicInbox::EvCleanup::next_tick($cleanup) if $cleanup;
}

1;
