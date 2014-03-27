# Copyright (C) 2014, Eric Wong <normalperson@yhbt.net> and all contributors
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
use strict;
use warnings;
use Test::More;
use PublicInbox::Config;
use File::Temp qw/tempdir/;
my $tmpdir = tempdir(CLEANUP => 1);

{
	is(system(qw(git init -q --bare), $tmpdir), 0, "git init successful");
	{
		local $ENV{GIT_DIR} = $tmpdir;
		is(system(qw(git config foo.bar hihi)), 0, "set config");
	}

	my $tmp = PublicInbox::Config->new("$tmpdir/config");

	is("hihi", $tmp->{"foo.bar"}, "config read correctly");
	is("true", $tmp->{"core.bare"}, "used --bare repo");
}

{
	my $f = "examples/public-inbox-config";
	ok(-r $f, "$f is readable");

	my $cfg = PublicInbox::Config->new($f);
	is_deeply($cfg->lookup('bugs@public-inbox.org'), {
		'failrepo' => '/home/pi/bugs-fail.git',
		'mainrepo' => '/home/pi/bugs-main.git',
		'address' => 'bugs@public-inbox.org',
		'description' => 'development discussion'
	}, "lookup matches expected output");

	is($cfg->lookup('blah@example.com'), undef,
		"non-existent lookup returns undef");
}

done_testing();
