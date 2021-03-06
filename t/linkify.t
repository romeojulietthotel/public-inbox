# Copyright (C) 2016-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
use strict;
use warnings;
use Test::More;
use PublicInbox::Linkify;

{
	my $l = PublicInbox::Linkify->new;
	my $u = 'http://example.com/url-with-trailing-period';
	my $s = $u . '.';
	$s = $l->linkify_1($s);
	$s = $l->linkify_2($s);
	is($s, qq(<a\nhref="$u">$u</a>.), 'trailing period not in URL');
}

# handle URLs in parenthesized statements
{
	my $l = PublicInbox::Linkify->new;
	my $u = 'http://example.com/';
	my $s = "(see: $u)";
	$s = $l->linkify_1($s);
	$s = $l->linkify_2($s);
	is($s, qq{(see: <a\nhref="$u">$u</a>)}, 'trailing ) not in URL');
}

{
	my $l = PublicInbox::Linkify->new;
	my $u = 'http://example.com/url-with-trailing-semicolon';
	my $s = $u . ';';
	$s = $l->linkify_1($s);
	$s = $l->linkify_2($s);
	is($s, qq(<a\nhref="$u">$u</a>;), 'trailing semicolon not in URL');
}

{
	my $l = PublicInbox::Linkify->new;
	my $u = 'http://example.com/url-with-(parens)';
	my $s = "hello $u world";
	$s = $l->linkify_1($s);
	$s = $l->linkify_2($s);
	is($s, qq(hello <a\nhref="$u">$u</a> world), 'URL preserved');

	$u .= "?query=a";
	$s = "hello $u world";
	$s = $l->linkify_1($s);
	$s = $l->linkify_2($s);
	is($s, qq(hello <a\nhref="$u">$u</a> world), 'query preserved');

	$u .= "#fragment";
	$s = "hello $u world";
	$s = $l->linkify_1($s);
	$s = $l->linkify_2($s);
	is($s, qq(hello <a\nhref="$u">$u</a> world),
	  'query + fragment preserved');

	$u = "http://example.com/";
	$s = "hello $u world";
	$s = $l->linkify_1($s);
	$s = $l->linkify_2($s);
	is($s, qq(hello <a\nhref="$u">$u</a> world), "root URL preserved");

	$u = "http://example.com/#fragment";
	$s = "hello $u world";
	$s = $l->linkify_1($s);
	$s = $l->linkify_2($s);
	is($s, qq(hello <a\nhref="$u">$u</a> world), "root + fragment");
}

# Markdown compatibility
{
	my $l = PublicInbox::Linkify->new;
	my $u = 'http://example.com/';
	my $s = "[markdown]($u)";
	$s = $l->linkify_1($s);
	$s = $l->linkify_2($s);
	is($s, qq![markdown](<a\nhref="$u">$u</a>)!, 'Markdown-compatible');

	$s = qq![markdown]($u "title")!;
	$s = $l->linkify_1($s);
	$s = $l->linkify_2($s);
	is($s, qq![markdown](<a\nhref="$u">$u</a> "title")!,
		'Markdown title compatible');

	$s = qq![markdown]($u).!;
	$s = $l->linkify_1($s);
	$s = $l->linkify_2($s);
	is($s, qq![markdown](<a\nhref="$u">$u</a>).!,
		'Markdown-compatible end of sentence');
}

done_testing();
