# Copyright (C) 2015 all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
#
# Used by the web interface to link to messages outside of the our
# public-inboxes.  Mail threads may cross projects/threads; so
# we should ensure users can find more easily find them on other
# sites.
package PublicInbox::ExtMsg;
use strict;
use warnings;
use URI::Escape qw(uri_escape_utf8);
use PublicInbox::Hval;
use PublicInbox::MID qw/mid2path/;

# TODO: user-configurable
our @EXT_URL = (
	'http://mid.gmane.org/%s',
	'https://lists.debian.org/msgid-search/%s',
	# leading "//" denotes protocol-relative (http:// or https://)
	'//mid.mail-archive.com/%s',
	'//marc.info/?i=%s',
);

sub ext_msg {
	my ($ctx) = @_;
	my $pi_config = $ctx->{pi_config};
	my $listname = $ctx->{listname};
	my $mid = $ctx->{mid};

	eval { require PublicInbox::Search };
	my $have_xap = $@ ? 0 : 1;
	my (@nox, @pfx);

	foreach my $k (keys %$pi_config) {
		$k =~ /\Apublicinbox\.([A-Z0-9a-z-]+)\.url\z/ or next;
		my $list = $1;
		next if $list eq $listname;

		my $git_dir = $pi_config->{"publicinbox.$list.mainrepo"};
		defined $git_dir or next;

		my $url = $pi_config->{"publicinbox.$list.url"};
		defined $url or next;

		$url =~ s!/+\z!!;

		# try to find the URL with Xapian to avoid forking
		if ($have_xap) {
			my $s;
			my $doc_id = eval {
				$s = PublicInbox::Search->new($git_dir);
				$s->find_unique_doc_id('mid', $mid);
			};
			if ($@) {
				# xapian not configured for this repo
			} else {
				# maybe we found it!
				return r302($url, $mid) if (defined $doc_id);

				# no point in trying the fork fallback if we
				# know Xapian is up-to-date but missing the
				# message in the current repo
				push @pfx, { git_dir => $git_dir, url => $url };
				next;
			}
		}

		# queue up for forking after we've tried Xapian on all of them
		push @nox, { git_dir => $git_dir, url => $url };
	}

	# Xapian not installed or configured for some repos
	my $path = "HEAD:" . mid2path($mid);

	foreach my $n (@nox) {
		# TODO: reuse existing PublicInbox::Git objects to save forks
		my $git = PublicInbox::Git->new($n->{git_dir});
		my (undef, $type, undef) = $git->check($path);
		return r302($n->{url}, $mid) if ($type && $type eq 'blob');
	}

	# fall back to partial MID matching
	my $n_partial = 0;
	my @partial;

	eval { require PublicInbox::Msgmap };
	my $have_mm = $@ ? 0 : 1;
	my $cgi = $ctx->{cgi};
	my $base_url = $cgi->base->as_string;
	if ($have_mm) {
		my $tmp_mid = $mid;
		my $url;
again:
		$url = $base_url . $listname;
		unshift @pfx, { git_dir => $ctx->{git_dir}, url => $url };
		foreach my $pfx (@pfx) {
			my $git_dir = delete $pfx->{git_dir} or next;
			my $mm = eval { PublicInbox::Msgmap->new($git_dir) };

			$mm or next;
			if (my $res = $mm->mid_prefixes($tmp_mid)) {
				$n_partial += scalar(@$res);
				$pfx->{res} = $res;
				push @partial, $pfx;
			}
		}
		# fixup common errors:
		if (!$n_partial && $tmp_mid =~ s,/[tTf],,) {
			goto again;
		}
	}

	my $code = 404;
	my $h = PublicInbox::Hval->new_msgid($mid, 1);
	my $href = $h->as_href;
	my $html = $h->as_html;
	my $title = "Message-ID &lt;$html&gt; not found";
	my $s = "<html><head><title>$title</title>" .
		"</head><body><pre><b>$title</b>\n";

	if ($n_partial) {
		$code = 300;
		my $es = $n_partial == 1 ? '' : 'es';
		$s.= "\n$n_partial partial match$es found:\n\n";
		foreach my $pfx (@partial) {
			my $u = $pfx->{url};
			foreach my $m (@{$pfx->{res}}) {
				my $p = PublicInbox::Hval->new_msgid($m);
				my $r = $p->as_href;
				my $t = $p->as_html;
				$s .= qq{<a\nhref="$u/$r/">$u/$t/</a>\n};
			}
		}
	}

	# Fall back to external repos if configured
	if (@EXT_URL && index($mid, '@') >= 0) {
		$code = 300;
		$s .= "\nPerhaps try an external site:\n\n";
		my $env = $cgi->{env};
		foreach my $url (@EXT_URL) {
			my $u = PublicInbox::Hval::prurl($env, $url);
			my $r = sprintf($u, $href);
			my $t = sprintf($u, $html);
			$s .= qq{<a\nhref="$r">$t</a>\n};
		}
	}
	$s .= '</pre></body></html>';

	[$code, ['Content-Type'=>'text/html; charset=UTF-8'], [$s]];
}

# Redirect to another public-inbox which is mapped by $pi_config
sub r302 {
	my ($url, $mid) = @_;
	$url .= '/' . uri_escape_utf8($mid) . '/';
	[ 302,
	  [ 'Location' => $url, 'Content-Type' => 'text/plain' ],
	  [ "Redirecting to\n$url\n" ] ]
}

1;
