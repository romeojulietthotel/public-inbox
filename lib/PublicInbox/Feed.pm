# Copyright (C) 2013-2015, all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
package PublicInbox::Feed;
use strict;
use warnings;
use Email::Address;
use Email::MIME;
use Date::Parse qw(strptime);
use PublicInbox::Hval;
use PublicInbox::GitCatFile;
use PublicInbox::View;
use PublicInbox::MID qw/mid_clean mid_compress/;
use constant {
	DATEFMT => '%Y-%m-%dT%H:%M:%SZ', # atom standard
	MAX_PER_PAGE => 25, # this needs to be tunable
};

use Encode qw/find_encoding/;
my $enc_utf8 = find_encoding('UTF-8');

# main function
sub generate {
	my ($ctx) = @_;
	sub { emit_atom($_[0], $ctx) };
}

sub generate_html_index {
	my ($ctx) = @_;
	sub { emit_html_index($_[0], $ctx) };
}

# private subs

sub emit_atom {
	my ($cb, $ctx) = @_;
	require POSIX;
	my $fh = $cb->([ 200, ['Content-Type' => 'application/xml']]);
	my $max = $ctx->{max} || MAX_PER_PAGE;
	my $feed_opts = get_feedopts($ctx);
	my $addr = $feed_opts->{address};
	$addr = $addr->[0] if ref($addr);
	$addr ||= 'public-inbox@example.com';
	my $title = $feed_opts->{description} || "unnamed feed";
	$title = PublicInbox::Hval->new_oneline($title)->as_html;
	my $type = index($title, '&') >= 0 ? "\ntype=\"html\"" : '';
	my $url = $feed_opts->{url} || "http://example.com/";
	my $atomurl = $feed_opts->{atomurl};
	$fh->write(qq(<?xml version="1.0" encoding="us-ascii"?>\n) .
		qq{<feed\nxmlns="http://www.w3.org/2005/Atom">} .
		qq{<title$type>$title</title>} .
		qq{<link\nhref="$url"/>} .
		qq{<link\nrel="self"\nhref="$atomurl"/>} .
		qq{<id>mailto:$addr</id>} .
		'<updated>' . POSIX::strftime(DATEFMT, gmtime) . '</updated>');

	my $git = PublicInbox::GitCatFile->new($ctx->{git_dir});
	each_recent_blob($ctx, sub {
		my ($add, undef) = @_;
		add_to_feed($feed_opts, $fh, $add, $git);
	});
	$git = undef; # destroy pipes
	Email::Address->purge_cache;
	$fh->write("</feed>");
	$fh->close;
}


sub emit_html_index {
	my ($cb, $ctx) = @_;
	my $fh = $cb->([200,['Content-Type'=>'text/html; charset=UTF-8']]);

	my $max = $ctx->{max} || MAX_PER_PAGE;
	my $feed_opts = get_feedopts($ctx);

	my $title = $feed_opts->{description} || '';
	$title = PublicInbox::Hval->new_oneline($title)->as_html;
	my $atom_url = $feed_opts->{atomurl};

	$fh->write("<html><head><title>$title</title>" .
		   "<link\nrel=alternate\ntitle=\"Atom feed\"\n".
		   "href=\"$atom_url\"\ntype=\"application/atom+xml\"/>" .
		   '</head><body>' . PublicInbox::View::PRE_WRAP .
		   "<b>$title</b> (<a\nhref=\"$atom_url\">Atom feed</a>)\n");

	my $state;
	my $git = PublicInbox::GitCatFile->new($ctx->{git_dir});
	my $topics;
	my $srch = $ctx->{srch};
	$srch and $topics = [ [], {} ];
	my (undef, $last) = each_recent_blob($ctx, sub {
		my ($path, $commit, $ts, $u, $subj) = @_;
		$state ||= {
			ctx => $ctx,
			seen => {},
			first_commit => $commit,
			anchor_idx => 0,
		};

		if ($srch) {
			add_topic($git, $srch, $topics, $path, $ts, $u, $subj);
		} else {
			my $mime = do_cat_mail($git, $path) or return 0;
			PublicInbox::View::index_entry($fh, $mime, 0, $state);
			1;
		}
	});
	Email::Address->purge_cache;
	$git = undef; # destroy pipes.

	my $footer = nav_footer($ctx->{cgi}, $last, $feed_opts, $state);
	if ($footer) {
		my $list_footer = $ctx->{footer};
		$footer .= "\n" . $list_footer if $list_footer;
		$footer = "<hr /><pre>$footer</pre>";
	}
	$fh->write(dump_topics($topics)) if $topics;
	$fh->write("$footer</body></html>");
	$fh->close;
}

sub nav_footer {
	my ($cgi, $last, $feed_opts, $state) = @_;
	$cgi or return '';
	my $old_r = $cgi->param('r');
	my $head = '    ';
	my $next = '    ';
	my $first = $state->{first_commit};
	my $anchor = $state->{anchor_idx};

	if ($last) {
		$next = qq!<a\nhref="?r=$last">next</a>!;
	}
	if ($old_r) {
		$head = $cgi->path_info;
		$head = qq!<a\nhref="$head">head</a>!;
	}
	my $atom = "<a\nhref=\"$feed_opts->{atomurl}\">atom</a>";
	my $permalink = "<a\nhref=\"?r=$first\">permalink</a>";
	"<a\nname=\"s$anchor\">page:</a> $next $head $atom $permalink";
}

sub each_recent_blob {
	my ($ctx, $cb) = @_;
	my $max = $ctx->{max} || MAX_PER_PAGE;
	my $hex = '[a-f0-9]';
	my $addmsg = qr!^:000000 100644 \S+ \S+ A\t(${hex}{2}/${hex}{38})$!;
	my $delmsg = qr!^:100644 000000 \S+ \S+ D\t(${hex}{2}/${hex}{38})$!;
	my $refhex = qr/(?:HEAD|${hex}{4,40})(?:~\d+)?/;
	my $cgi = $ctx->{cgi};

	# revision ranges may be specified
	my $range = 'HEAD';
	my $r = $cgi->param('r') if $cgi;
	if ($r && ($r =~ /\A(?:$refhex\.\.)?$refhex\z/o)) {
		$range = $r;
	}

	# get recent messages
	# we could use git log -z, but, we already know ssoma will not
	# leave us with filenames with spaces in them..
	my @cmd = ('git', "--git-dir=$ctx->{git_dir}",
			qw/log --no-notes --no-color --raw -r
			   --abbrev=16 --abbrev-commit/,
			"--format=%h%x00%ct%x00%an%x00%s%x00");
	push @cmd, $range;

	my $pid = open(my $log, '-|', @cmd) or
		die('open `'.join(' ', @cmd) . " pipe failed: $!\n");
	my %deleted; # only an optimization at this point
	my $last;
	my $nr = 0;
	my ($cur_commit, $first_commit, $last_commit);
	my ($ts, $subj, $u);
	while (defined(my $line = <$log>)) {
		if ($line =~ /$addmsg/o) {
			my $add = $1;
			next if $deleted{$add}; # optimization-only
			$nr += $cb->($add, $cur_commit, $ts, $u, $subj);
			if ($nr >= $max) {
				$last = 1;
				last;
			}
		} elsif ($line =~ /$delmsg/o) {
			$deleted{$1} = 1;
		} elsif ($line =~ /^${hex}{7,40}/o) {
			($cur_commit, $ts, $u, $subj) = split("\0", $line);
			unless (defined $first_commit) {
				$first_commit = $cur_commit;
			}
		}
	}

	if ($last) {
		while (my $line = <$log>) {
			if ($line =~ /^(${hex}{7,40})/o) {
				$last_commit = $1;
				last;
			}
		}
	}

	close $log; # we may EPIPE here
	# for pagination
	($first_commit, $last_commit);
}

# private functions below
sub get_feedopts {
	my ($ctx) = @_;
	my $pi_config = $ctx->{pi_config};
	my $listname = $ctx->{listname};
	my $cgi = $ctx->{cgi};
	my %rv;
	if (open my $fh, '<', "$ctx->{git_dir}/description") {
		chomp($rv{description} = <$fh>);
		close $fh;
	}

	if ($pi_config && defined $listname && length $listname) {
		foreach my $key (qw(address)) {
			$rv{$key} = $pi_config->get($listname, $key) || "";
		}
	}
	my $url_base;
	if ($cgi) {
		my $path_info = $cgi->path_info;
		my $base;
		if (ref($cgi) eq 'CGI') {
			$base = $cgi->url(-base);
		} else {
			$base = $cgi->base->as_string;
			$base =~ s!/\z!!;
		}
		$url_base = $path_info;
		if ($url_base =~ s!/(?:|index\.html)?\z!!) {
			$rv{atomurl} = "$base$url_base/atom.xml";
		} else {
			$url_base =~ s!/atom\.xml\z!!;
			$rv{atomurl} = $base . $path_info;
			$url_base = $base . $url_base; # XXX is this needed?
		}
	} else {
		$url_base = "http://example.com";
		$rv{atomurl} = "$url_base/atom.xml";
	}
	$rv{url} ||= "$url_base/";
	$rv{midurl} = "$url_base/m/";
	$rv{fullurl} = "$url_base/f/";

	\%rv;
}

sub mime_header {
	my ($mime, $name) = @_;
	PublicInbox::Hval->new_oneline($mime->header($name))->raw;
}

sub feed_date {
	my ($date) = @_;
	my @t = eval { strptime($date) };

	scalar(@t) ? POSIX::strftime(DATEFMT, @t) : 0;
}

# returns 0 (skipped) or 1 (added)
sub add_to_feed {
	my ($feed_opts, $fh, $add, $git) = @_;

	my $mime = do_cat_mail($git, $add) or return 0;
	my $fullurl = $feed_opts->{fullurl} || 'http://example.com/f/';

	my $header_obj = $mime->header_obj;
	my $mid = $header_obj->header('Message-ID');
	defined $mid or return 0;
	$mid = PublicInbox::Hval->new_msgid($mid);
	my $href = $mid->as_href . '.html';
	my $content = PublicInbox::View->feed_entry($mime, $fullurl . $href);
	defined($content) or return 0;
	$mime = undef;

	my $title = mime_header($header_obj, 'Subject') or return 0;
	$title = PublicInbox::Hval->new_oneline($title)->as_html;
	my $type = index($title, '&') >= 0 ? "\ntype=\"html\"" : '';

	my $from = mime_header($header_obj, 'From') or return 0;
	my @from = Email::Address->parse($from) or return 0;
	my $name = PublicInbox::Hval->new_oneline($from[0]->name)->as_html;
	my $email = $from[0]->address;
	$email = PublicInbox::Hval->new_oneline($email)->as_html;

	my $date = $header_obj->header('Date');
	$date = PublicInbox::Hval->new_oneline($date);
	$date = feed_date($date->raw) or return 0;

	$fh->write("<entry><author><name>$name</name><email>$email</email>" .
		   "</author><title$type>$title</title>" .
		   "<updated>$date</updated>" .
		   qq{<content\ntype="xhtml">} .
		   qq{<div\nxmlns="http://www.w3.org/1999/xhtml">});
	$fh->write($content);

	$add =~ tr!/!!d;
	my $h = '[a-f0-9]';
	my (@uuid5) = ($add =~ m!\A($h{8})($h{4})($h{4})($h{4})($h{12})!o);
	my $id = 'urn:uuid:' . join('-', @uuid5);
	my $midurl = $feed_opts->{midurl} || 'http://example.com/m/';
	$fh->write(qq{</div></content><link\nhref="$midurl$href"/>}.
		   "<id>$id</id></entry>");
	1;
}

sub do_cat_mail {
	my ($git, $path) = @_;
	my $mime = eval {
		my $str = $git->cat_file("HEAD:$path");
		Email::MIME->new($str);
	};
	$@ ? undef : $mime;
}

# accumulate recent topics if search is supported
sub add_topic {
	my ($git, $srch, $topics, $path, $ts, $u, $subj) = @_;
	my ($order, $subjs) = @$topics;
	my $header_obj;

	# legacy ssoma did not set commit titles based on Subject
	$subj = $enc_utf8->decode($subj);
	if ($subj eq 'mda') {
		my $mime = do_cat_mail($git, $path) or return 0;
		$header_obj = $mime->header_obj;
		$subj = mime_header($header_obj, 'Subject');
	}

	my $topic = $subj = $srch->subject_normalized($subj);

	# kill "[PATCH v2]" etc. for summarization
	$topic =~ s/\A\s*\[[^\]]+\]\s*//g;

	if (++$subjs->{$topic} == 1) {
		unless ($header_obj) {
			my $mime = do_cat_mail($git, $path) or return 0;
			$header_obj = $mime->header_obj;
		}
		my $mid = $header_obj->header('Message-ID');
		$mid = mid_compress(mid_clean($mid));
		$u = $enc_utf8->decode($u);
		push @$order, [ $mid, $ts, $u, $subj ];
		return 1;
	}
	0; # old topic, continue going
}

sub dump_topics {
	my ($topics) = @_;
	my ($order, $subjs) = @$topics;
	my $dst = '';
	$dst .= "\n[No recent topics]" unless (scalar @$order);
	while (defined(my $info = shift @$order)) {
		my ($mid, $ts, $u, $subj) = @$info;
		my $n = delete $subjs->{$subj};
		$mid = PublicInbox::Hval->new($mid)->as_href;
		$subj = PublicInbox::Hval->new($subj)->as_html;
		$u = PublicInbox::Hval->new($u)->as_html;
		$dst .= "\n<a\nhref=\"t/$mid.html#u\"><b>$subj</b></a>\n- ";
		$ts = POSIX::strftime('%Y-%m-%d %H:%M', gmtime($ts));
		if ($n == 1) {
			$dst .= "created by $u @ $ts UTC\n"
		} else {
			# $n isn't the total number of posts on the topic,
			# just the number of posts in the current "git log"
			# window, so leave it unlabeled
			$dst .= "updated by $u @ $ts UTC ($n)\n"
		}
	}
	$dst .= '</pre>'
}

1;
