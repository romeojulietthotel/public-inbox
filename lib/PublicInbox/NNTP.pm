# Copyright (C) 2015 all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
package PublicInbox::NNTP;
use strict;
use warnings;
use base qw(Danga::Socket);
use fields qw(nntpd article ng);
use PublicInbox::Msgmap;
use PublicInbox::GitCatFile;
use PublicInbox::MID qw(mid2path);
use Email::Simple;
use Data::Dumper qw(Dumper);
use POSIX qw(strftime);
use constant {
	r501 => '501 command syntax error',
};

my @OVERVIEW = qw(Subject From Date Message-ID References Bytes Lines);
my %OVERVIEW = map { $_ => 1 } @OVERVIEW;

# disable commands with easy DoS potential:
# LISTGROUP could get pretty bad, too...
my %DISABLED; # = map { $_ => 1 } qw(xover list_overview_fmt newnews xhdr);

sub new {
	my ($class, $sock, $nntpd) = @_;
	my $self = fields::new($class);
	$self->SUPER::new($sock);
	$self->{nntpd} = $nntpd;
	res($self, '201 server ready - post via email');
	$self->watch_read(1);
	$self;
}

# returns 1 if we can continue, 0 if not due to buffered writes or disconnect
sub process_line {
	my ($self, $l) = @_;
	my ($req, @args) = split(/\s+/, $l);
	$req = lc($req);
	$req = eval {
		no strict 'refs';
		$req = $DISABLED{$req} ? undef : *{'cmd_'.$req}{CODE};
	};
	return res($self, '500 command not recognized') unless $req;

	my $res = eval { $req->($self, @args) };
	my $err = $@;
	if ($err && !$self->{closed}) {
		chomp($l = Dumper(\$l));
		warning('error from: ', $l, ' ', $err);
		$res = '503 program fault - command not performed';
	}
	return 0 unless defined $res;
	res($self, $res);
}

sub cmd_mode {
	my ($self, $arg) = @_;
	return r501 unless defined $arg;
	$arg = uc $arg;
	return r501 unless $arg eq 'READER';
	'200 reader status acknowledged';
}

sub cmd_slave {
	my ($self, @x) = @_;
	return r501 if @x;
	'202 slave status noted';
}

sub cmd_xgtitle {
	my ($self, $wildmat) = @_;
	more($self, '282 list of groups and descriptions follows');
	list_newsgroups($self, $wildmat);
	'.'
}

sub list_overview_fmt {
	my ($self) = @_;
	more($self, $_ . ':') foreach @OVERVIEW;
}

sub list_active {
	my ($self, $wildmat) = @_;
	wildmat2re($wildmat);
	foreach my $ng (values %{$self->{nntpd}->{groups}}) {
		$ng->{name} =~ $wildmat or next;
		group_line($self, $ng);
	}
}

sub list_active_times {
	my ($self, $wildmat) = @_;
	wildmat2re($wildmat);
	foreach my $ng (values %{$self->{nntpd}->{groups}}) {
		$ng->{name} =~ $wildmat or next;
		my $c = eval { $ng->mm->created_at } || time;
		more($self, "$ng->{name} $c $ng->{address}");
	}
}

sub list_newsgroups {
	my ($self, $wildmat) = @_;
	wildmat2re($wildmat);
	foreach my $ng (values %{$self->{nntpd}->{groups}}) {
		$ng->{name} =~ $wildmat or next;
		my $d = $ng->description;
		more($self, "$ng->{name} $d");
	}
}

# LIST SUBSCRIPTIONS not supported
sub cmd_list {
	my ($self, $arg, $wildmat, @x) = @_;
	if (defined $arg) {
		$arg = lc $arg;
		$arg =~ tr/./_/;
		$arg = "list_$arg";
		return '503 function not performed' if $DISABLED{$arg};
		$arg = eval {
			no strict 'refs';
			*{$arg}{CODE};
		};
		return r501 unless $arg;
		more($self, '215 information follows');
		$arg->($self, $wildmat, @x);
	} else {
		more($self, '215 list of newsgroups follows');
		foreach my $ng (values %{$self->{nntpd}->{groups}}) {
			group_line($self, $ng);
		}
	}
	'.'
}

sub cmd_listgroup {
	my ($self, $group) = @_;
	if (defined $group) {
		my $res = cmd_group($self, $group);
		return $res if ($res !~ /\A211 /);
		more($self, $res);
	}

	my $ng = $self->{ng} or return '412 no newsgroup selected';
	# Ugh this can be silly expensive for big groups
	$ng->mm->each_id_batch(sub {
		my ($ary) = @_;
		more($self, join("\r\n", @$ary));
	});
	'.'
}

sub parse_time {
	my ($date, $time, $gmt) = @_;
	use Time::Local qw();
	my ($YY, $MM, $DD) = unpack('A2A2A2', $date);
	my ($hh, $mm, $ss) = unpack('A2A2A2', $time);
	if (defined $gmt) {
		$gmt =~ /\A(?:UTC|GMT)\z/i or die "GM invalid: $gmt\n";
		$gmt = 1;
	}
	my @now = $gmt ? gmtime : localtime;
	if ($YY > strftime('%y', @now)) {
		my $cur_year = $now[5] + 1900;
		$YY += int($cur_year / 1000) * 1000 - 100;
	}

	if ($gmt) {
		Time::Local::timegm($ss, $mm, $hh, $DD, $MM - 1, $YY);
	} else {
		Time::Local::timelocal($ss, $mm, $hh, $DD, $MM - 1, $YY);
	}
}

sub group_line {
	my ($self, $ng) = @_;
	my ($min, $max) = $ng->mm->minmax;
	more($self, "$ng->{name} $max $min n") if defined $min && defined $max;
}

sub cmd_newgroups {
	my ($self, $date, $time, $gmt, $dists) = @_;
	my $ts = eval { parse_time($date, $time, $gmt) };
	return r501 if $@;

	# TODO dists
	more($self, '231 list of new newsgroups follows');
	foreach my $ng (values %{$self->{nntpd}->{groups}}) {
		my $c = eval { $ng->mm->created_at } || 0;
		next unless $c > $ts;
		group_line($self, $ng);
	}
	'.'
}

sub wildmat2re {
	return $_[0] = qr/.*/ if (!defined $_[0] || $_[0] eq '*');
	my %keep;
	my $salt = rand;
	use Digest::SHA qw(sha1_hex);
	my $tmp = $_[0];

	$tmp =~ s#(?<!\\)\[(.+)(?<!\\)\]#
		my $orig = $1;
		my $key = sha1_hex($orig . $salt);
		$orig =~ s/([^\w\-])+/\Q$1/g;
		$keep{$key} = $orig;
		$key
		#gex;
	my %map = ('*' => '.*', '?' => '.' );
	$tmp =~ s#(?<!\\)([^\w\\])#$map{$1} || "\Q$1"#ge;
	if (scalar %keep) {
		$tmp =~ s#([a-f0-9]{40})#
			my $orig = $keep{$1};
			defined $orig ? $orig : $1;
			#ge;
	}
	$_[0] = qr/\A$tmp\z/;
}

sub ngpat2re {
	return $_[0] = qr/\A\z/ unless defined $_[0];
	my %map = ('*' => '.*', ',' => '|');
	$_[0] =~ s!(.)!$map{$1} || "\Q$1"!ge;
	$_[0] = qr/\A(?:$_[0])\z/;
}

sub cmd_newnews {
	my ($self, $newsgroups, $date, $time, $gmt, $dists) = @_;
	my $ts = eval { parse_time($date, $time, $gmt) };
	return r501 if $@;
	more($self, '230 list of new articles by message-id follows');
	my ($keep, $skip) = split('!', $newsgroups, 2);
	ngpat2re($keep);
	ngpat2re($skip);
	$ts .= '..';

	my $opts = { asc => 1, limit => 1000 };
	foreach my $ng (values %{$self->{nntpd}->{groups}}) {
		$ng->{name} =~ $keep or next;
		$ng->{name} =~ $skip and next;
		my $srch = $ng->search or next;
		$opts->{offset} = 0;

		while (1) {
			my $res = $srch->query($ts, $opts);
			my $msgs = $res->{msgs};
			my $nr = scalar @$msgs or last;
			more($self, '<' .
				join(">\r\n<", map { $_->mid } @$msgs ).
				'>');
			$opts->{offset} += $nr;
		}
	}
	'.';
}

sub cmd_group {
	my ($self, $group) = @_;
	my $no_such = '411 no such news group';
	my $ng = $self->{nntpd}->{groups}->{$group} or return $no_such;

	$self->{ng} = $ng;
	my ($min, $max) = $ng->mm->minmax;
	$min ||= 0;
	$max ||= 0;
	$self->{article} = $min;
	my $est_size = $max - $min;
	"211 $est_size $min $max $group";
}

sub article_adj {
	my ($self, $off) = @_;
	my $ng = $self->{ng} or return '412 no newsgroup selected';

	my $n = $self->{article};
	defined $n or return '420 no current article has been selected';

	$n += $off;
	my $mid = $ng->mm->mid_for($n);
	unless ($mid) {
		$n = $off > 0 ? 'next' : 'previous';
		return "421 no $n article in this group";
	}
	$self->{article} = $n;
	"223 $n <$mid> article retrieved - request text separately";
}

sub cmd_next { article_adj($_[0], 1) }
sub cmd_last { article_adj($_[0], -1) }

# We want to encourage using email and CC-ing everybody involved to avoid
# the single-point-of-failure a single server provides.
sub cmd_post {
	my ($self) = @_;
	my $ng = $self->{ng};
	$ng ? "440 mailto:$ng->{address} to post" : '440 posting not allowed'
}

sub cmd_quit {
	my ($self) = @_;
	res($self, '205 closing connection - goodbye!');
	$self->close;
	undef;
}

sub art_lookup {
	my ($self, $art, $set_headers) = @_;
	my $ng = $self->{ng} or return '412 no newsgroup has been selected';
	my ($n, $mid);
	my $err;
	if (defined $art) {
		if ($art =~ /\A\d+\z/o) {
			$err = '423 no such article number in this group';
			$n = int($art);
			goto find_mid;
		} elsif ($art =~ /\A<([^>]+)>\z/) {
			$err = '430 no such article found';
			$mid = $1;
			$n = $ng->mm->num_for($mid);
			defined $mid or return $err;
		} else {
			return r501;
		}
	} else {
		$err = '420 no current article has been selected';
		$n = $self->{article};
		defined $n or return $err;
find_mid:
		$mid = $ng->mm->mid_for($n);
		defined $mid or return $err;
	}

	my $o = 'HEAD:' . mid2path($mid);
	my $s = eval { Email::Simple->new($ng->gcf->cat_file($o)) };
	return $err unless $s;
	if ($set_headers) {
		$s->header_set('Newsgroups', $ng->{name});
		$s->header_set('Lines', $s->body =~ tr!\n!\n!);
		$s->header_set('Xref', "$ng->{domain} $ng->{name}:$n");

		# must be last
		if ($set_headers == 2) {
			$s->header_set('Bytes', bytes::length($s->as_string));
			$s->body_set('');
		}
	}
	[ $n, $mid, $s ];
}

sub simple_body_write {
	my ($self, $s) = @_;
	my $body = $s->body;
	$s->body_set('');
	$body =~ s/^\./../smg;
	do_more($self, $body);
	'.'
}

sub header_str {
	my ($s) = @_;
	my $h = $s->header_obj;
	$h->header_set('Bytes');
	$h->as_string
}

sub cmd_article {
	my ($self, $art) = @_;
	my $r = $self->art_lookup($art, 1);
	return $r unless ref $r;
	my ($n, $mid, $s) = @$r;
	more($self, "220 $n <$mid> article retrieved - head and body follow");
	do_more($self, header_str($s));
	do_more($self, "\r\n");
	simple_body_write($self, $s);
}

sub cmd_head {
	my ($self, $art) = @_;
	my $r = $self->art_lookup($art, 2);
	return $r unless ref $r;
	my ($n, $mid, $s) = @$r;
	more($self, "221 $n <$mid> article retrieved - head follows");
	do_more($self, header_str($s));
	'.'
}

sub cmd_body {
	my ($self, $art) = @_;
	my $r = $self->art_lookup($art, 0);
	return $r unless ref $r;
	my ($n, $mid, $s) = @$r;
	more($self, "222 $n <$mid> article retrieved - body follows");
	simple_body_write($self, $s);
}

sub cmd_stat {
	my ($self, $art) = @_;
	my $r = $self->art_lookup($art, 0);
	return $r unless ref $r;
	my ($n, $mid, undef) = @$r;
	"223 $n <$mid> article retrieved - request text separately";
}

sub cmd_ihave { '435 article not wanted - do not send it' }

sub cmd_date { '111 '.strftime('%Y%m%d%H%M%S', gmtime(time)) }

sub cmd_help {
	my ($self) = @_;
	more($self, '100 help text follows');
	'.'
}

sub get_range {
	my ($self, $range) = @_;
	my $ng = $self->{ng} or return '412 no news group has been selected';
	defined $range or return '420 No article(s) selected';
	my ($beg, $end);
	my ($min, $max) = $ng->mm->minmax;
	if ($range =~ /\A(\d+)\z/) {
		$beg = $end = $1;
	} elsif ($range =~ /\A(\d+)-\z/) {
		($beg, $end) = ($1, $max);
	} elsif ($range =~ /\A(\d+)-(\d+)\z/) {
		($beg, $end) = ($1, $2);
	} else {
		return r501;
	}
	$beg = $min if ($beg < $min);
	$end = $max if ($end > $max);
	return '420 No article(s) selected' if ($beg > $end);
	[ $beg, $end ];
}

sub xhdr {
	my ($r, $header) = @_;
	$r = $r->[2]->header_obj->header($header);
	defined $r or return;
	$r =~ s/[\r\n\t]+/ /sg;
	$r;
}

sub cmd_xhdr {
	my ($self, $header, $range) = @_;
	defined $self->{ng} or return '412 no news group currently selected';
	unless (defined $range) {
		defined($range = $self->{article}) or
			return '420 no current article has been selected';
	}
	if ($range =~ /\A<(.+)>\z/) { # Message-ID
		my $r = $self->art_lookup($range, 2);
		return $r unless ref $r;
		more($self, '221 Header follows');
		if (defined($r = xhdr($r, $header))) {
			more($self, "<$range> $r");
		}
	} else { # numeric range
		my $r = get_range($self, $range);
		return $r unless ref $r;
		my ($beg, $end) = @$r;
		more($self, '221 Header follows');
		foreach my $i ($beg..$end) {
			$r = $self->art_lookup($i, 2);
			next unless ref $r;
			defined($r = xhdr($r, $header)) or next;
			more($self, "$i $r");
		}
	}
	'.';
}

sub cmd_xover {
	my ($self, $range) = @_;
	my $r = get_range($self, $range);
	return $r unless ref $r;
	my ($beg, $end) = @$r;
	more($self, "224 Overview information follows for $beg to $end");
	foreach my $i ($beg..$end) {
		my $r = $self->art_lookup($i, 2);
		next unless ref $r;
		more($self, join("\t", $r->[0],
				map {
					my $h = xhdr($r, $_);
					defined $h ? $h : '';
				} @OVERVIEW ));
	}
	'.';
}

sub res {
	my ($self, $line) = @_;
	do_write($self, $line . "\r\n");
}

sub more {
	my ($self, $line) = @_;
	do_more($self, $line . "\r\n");
}

sub do_write {
	my ($self, $data) = @_;
	my $done = $self->write($data);
	die if $self->{closed};

	# Do not watch for readability if we have data in the queue,
	# instead re-enable watching for readability when we can
	$self->watch_read(0) unless $done;

	$done;
}

use constant MSG_MORE => ($^O eq 'linux') ? 0x8000 : 0;

sub do_more {
	my ($self, $data) = @_;
	if (MSG_MORE && !$self->{write_buf_size}) {
		my $n = send($self->{sock}, $data, MSG_MORE);
		if (defined $n) {
			my $dlen = bytes::length($data);
			return 1 if $n == $dlen; # all done!
			$data = bytes::substr($data, $n, $dlen - $n);
		}
	}
	$self->do_write($data);
}

# callbacks for by Danga::Socket

sub event_hup { $_[0]->close }
sub event_err { $_[0]->close }

sub event_write {
	my ($self) = @_;
	# only continue watching for readability when we are done writing:
	$self->write(undef) == 1 and $self->watch_read(1);
}

sub event_read {
	my ($self) = @_;
	use constant LINE_MAX => 512; # RFC 977 section 2.3
	use Time::HiRes qw(gettimeofday tv_interval);
	my $r = 1;
	my $buf = $self->read(LINE_MAX) or return $self->close;
	while ($r > 0 && $$buf =~ s/\A([^\r\n]+)\r?\n//) {
		my $line = $1;
		my $t0 = [ gettimeofday ];
		$r = eval { $self->process_line($line) };
		printf(STDERR "$line %0.6f\n",
			tv_interval($t0, [gettimeofday]));
	}
	return $self->close if $r < 0;
	my $len = bytes::length($$buf);
	return $self->close if ($len >= LINE_MAX);
	$self->push_back_read($buf) if ($len);
}

sub warning { print STDERR @_, "\n" }

1;