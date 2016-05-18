#!/usr/bin/perl -w
# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# Parallel WWW checker
my $usage = "$0 [-j JOBS] [-s SLOW_THRESHOLD] URL_OF_INBOX\n";
use strict;
use warnings;
use File::Temp qw(tempfile);
use GDBM_File;
use Getopt::Long qw(:config gnu_getopt no_ignore_case auto_abbrev);
use IO::Socket;
use LWP::ConnCache;
use POSIX qw(:sys_wait_h);
use Time::HiRes qw(gettimeofday tv_interval);
use WWW::Mechanize;
my $nproc = 4;
my $slow = 0.5;
my %opts = (
	'-j|jobs=i' => \$nproc,
	'-s|slow-threshold=f' => \$slow,
);
GetOptions(%opts) or die "bad command-line args\n$usage";
my $root_url = shift or die $usage;

my %workers;
$SIG{TERM} = sub { exit 0 };
$SIG{CHLD} = sub {
	while (1) {
		my $pid = waitpid(-1, WNOHANG);
		return if !defined $pid || $pid <= 0;
		my $p = delete $workers{$pid} || '(unknown)';
		warn("$pid [$p] exited with $?\n") if $?;
	}
};

my @todo = IO::Socket->socketpair(AF_UNIX, SOCK_SEQPACKET, 0);
die "socketpair failed: $!" unless $todo[1];
my @done = IO::Socket->socketpair(AF_UNIX, SOCK_SEQPACKET, 0);
die "socketpair failed: $!" unless $done[1];
$| = 1;

foreach my $p (1..$nproc) {
	my $pid = fork;
	die "fork failed: $!\n" unless defined $pid;
	if ($pid) {
		$workers{$pid} = $p;
	} else {
		$todo[1]->close;
		$done[0]->close;
		worker_loop($todo[0], $done[1]);
	}
}

my ($fh, $tmp) = tempfile('www-check-XXXXXXXX',
			SUFFIX => '.gdbm', UNLINK => 1, TMPDIR => 1);
my $gdbm = tie my %seen, 'GDBM_File', $tmp, &GDBM_WRCREAT, 0600;
defined $gdbm or die "gdbm open failed: $!\n";
$todo[0]->close;
$done[1]->close;

my ($rvec, $wvec);
$todo[1]->blocking(0);
$done[0]->blocking(0);
$seen{$root_url} = 1;
my $ndone = 0;
my $nsent = 1;
my @queue = ($root_url);
my $timeout = $slow * 4;
while (keys %workers) { # reacts to SIGCHLD
	$wvec = $rvec = '';
	my $u;
	vec($rvec, fileno($done[0]), 1) = 1;
	if (@queue) {
		vec($wvec, fileno($todo[1]), 1) = 1;
	} elsif ($ndone == $nsent) {
		kill 'TERM', keys %workers;
		exit;
	}
	if (!select($rvec, $wvec, undef, $timeout)) {
		while (my ($k, $v) = each %seen) {
			next if $v == 2;
			print "WAIT ($ndone/$nsent) <$k>\n";
		}
	}
	while ($u = shift @queue) {
		my $s = $todo[1]->send($u, MSG_EOR);
		if ($!{EAGAIN}) {
			unshift @queue, $u;
			last;
		}
	}
	my $r;
	do {
		$r = $done[0]->recv($u, 65535, 0);
	} while (!defined $r && $!{EINTR});
	next unless $u;
	if ($u =~ s/\ADONE\t//) {
		$ndone++;
		$seen{$u} = 2;
	} else {
		next if $seen{$u};
		$seen{$u} = 1;
		$nsent++;
		push @queue, $u;
	}
}

sub worker_loop {
	my ($todo_rd, $done_wr) = @_;
	my $m = WWW::Mechanize->new(autocheck => 0);
	my $cc = LWP::ConnCache->new;
	$m->conn_cache($cc);
	while (1) {
		$todo_rd->recv(my $u, 65535, 0);
		next unless $u;

		my $t = [ gettimeofday ];
		my $r = $m->get($u);
		$t = tv_interval($t);
		printf "SLOW %0.06f % 5d %s\n", $t, $$, $u if $t > $slow;
		my @links;
		if ($r->is_success) {
			my %links = map {
				(split('#', $_->URI->abs->as_string))[0] => 1;
			} grep {
				$_->tag && $_->url !~ /:/
			} $m->links;
			@links = keys %links;
		} elsif ($r->code != 300) {
			warn "W: ".$r->code . " $u\n"
		}

		# check bad links
		my @at = grep(/@/, @links);
		print "BAD: $u ", join("\n", @at), "\n" if @at;

		my $s;
		# blocking
		foreach my $l (@links, "DONE\t$u") {
			next if $l eq '';
			do {
				$s = $done_wr->send($l, MSG_EOR);
			} while (!defined $s && $!{EINTR});
			die "$$ send $!\n" unless defined $s;
			my $n = length($l);
			die "$$ send truncated $s < $n\n" if $s != $n;
		}
	}
}