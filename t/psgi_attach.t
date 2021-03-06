# Copyright (C) 2016-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use Email::MIME;
use File::Temp qw/tempdir/;
my $tmpdir = tempdir('psgi-attach-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $maindir = "$tmpdir/main.git";
my $addr = 'test-public@example.com';
my $cfgpfx = "publicinbox.test";
my @mods = qw(HTTP::Request::Common Plack::Test URI::Escape);
foreach my $mod (@mods) {
	eval "require $mod";
	plan skip_all => "$mod missing for plack.t" if $@;
}
use_ok $_ foreach @mods;
use PublicInbox::Import;
use PublicInbox::Git;
use PublicInbox::Config;
use PublicInbox::WWW;
use_ok 'PublicInbox::WwwAttach';
use Plack::Builder;
my $config = PublicInbox::Config->new({
	"$cfgpfx.address" => $addr,
	"$cfgpfx.mainrepo" => $maindir,
});
is(0, system(qw(git init -q --bare), $maindir), "git init (main)");
my $git = PublicInbox::Git->new($maindir);
my $im = PublicInbox::Import->new($git, 'test', $addr);

{
	open my $fh, '<', '/dev/urandom' or die "unable to open urandom: $!\n";
	sysread($fh, my $buf, 8);
	is(8, length($buf), 'read some random data');
	my $qp = "abcdef=g\n==blah\n";
	my $b64 = 'b64'.$buf."\n";
	my $txt = "plain\ntext\npass\nthrough\n";
	my $dot = "dotfile\n";
	my $parts = [
		Email::MIME->create(
			attributes => {
				filename => 'queue-pee',
				content_type => 'text/plain',
				encoding => 'quoted-printable'
			},
			body => $qp),
		Email::MIME->create(
			attributes => {
				filename => 'bayce-sixty-four',
				content_type => 'appication/octet-stream',
				encoding => 'base64',
			},
			body => $b64),
		Email::MIME->create(
			attributes => {
				filename => 'noop.txt',
				content_type => 'text/plain',
			},
			body => $txt),
		Email::MIME->create(
			attributes => {
				filename => '.dotfile',
				content_type => 'text/plain',
			},
			body => $dot),
	];
	my $mime = Email::MIME->create(
		parts => $parts,
		header_str => [ From => 'root@z', 'Message-Id' => '<Z@B>',
			Subject => 'hi']
	);
	$mime = $mime->as_string;
	$mime =~ s/\r\n/\n/g; # normalize to LF only
	$mime = Email::MIME->new($mime);
	$im->add($mime);
	$im->done;

	my $www = PublicInbox::WWW->new($config);
	test_psgi(sub { $www->call(@_) }, sub {
		my ($cb) = @_;
		my $res;
		$res = $cb->(GET('/test/Z%40B/'));
		my @href = ($res->content =~ /^href="([^"]+)"/gms);
		@href = grep(/\A[\d\.]+-/, @href);
		is_deeply([qw(1-queue-pee 2-bayce-sixty-four 3-noop.txt
				4-a.txt)],
			\@href, 'attachment links generated');

		$res = $cb->(GET('/test/Z%40B/1-queue-pee'));
		my $qp_res = $res->content;
		ok(length($qp_res) >= length($qp), 'QP length is close');
		like($qp_res, qr/\n\z/s, 'trailing newline exists');
		# is(index($qp_res, $qp), 0, 'QP trailing newline is there');
		$qp_res =~ s/\r\n/\n/g;
		is(index($qp_res, $qp), 0, 'QP trailing newline is there');

		$res = $cb->(GET('/test/Z%40B/2-base-sixty-four'));
		is(quotemeta($res->content), quotemeta($b64),
			'Base64 matches exactly');

		$res = $cb->(GET('/test/Z%40B/3-noop.txt'));
		my $txt_res = $res->content;
		ok(length($txt_res) >= length($txt),
			'plain text almost matches');
		like($txt_res, qr/\n\z/s, 'trailing newline exists in text');
		is(index($txt_res, $txt), 0, 'plain text not truncated');

		$res = $cb->(GET('/test/Z%40B/4-a.txt'));
		my $dot_res = $res->content;
		ok(length($dot_res) >= length($dot), 'dot almost matches');
		$res = $cb->(GET('/test/Z%40B/4-any-filename.txt'));
		is($res->content, $dot_res, 'user-specified filename is OK');

	});
}
done_testing();
