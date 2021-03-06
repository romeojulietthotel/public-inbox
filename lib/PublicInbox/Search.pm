# Copyright (C) 2015-2018 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
# based on notmuch, but with no concept of folders, files or flags
#
# Read-only search interface for use by the web and NNTP interfaces
package PublicInbox::Search;
use strict;
use warnings;

# values for searching
use constant TS => 0; # timestamp
use constant NUM => 1; # NNTP article number
use constant BYTES => 2; # :bytes as defined in RFC 3977
use constant LINES => 3; # :lines as defined in RFC 3977
use constant YYYYMMDD => 4; # for searching in the WWW UI

use Search::Xapian qw/:standard/;
use PublicInbox::SearchMsg;
use PublicInbox::MIME;
use PublicInbox::MID qw/mid_clean id_compress/;

# This is English-only, everything else is non-standard and may be confused as
# a prefix common in patch emails
our $REPLY_RE = qr/^re:\s+/i;
our $LANG = 'english';

use constant {
	# SCHEMA_VERSION history
	# 0 - initial
	# 1 - subject_path is lower-cased
	# 2 - subject_path is id_compress in the index, only
	# 3 - message-ID is compressed if it includes '%' (hack!)
	# 4 - change "Re: " normalization, avoid circular Reference ghosts
	# 5 - subject_path drops trailing '.'
	# 6 - preserve References: order in document data
	# 7 - remove references and inreplyto terms
	# 8 - remove redundant/unneeded document data
	# 9 - disable Message-ID compression (SHA-1)
	# 10 - optimize doc for NNTP overviews
	# 11 - merge threads when vivifying ghosts
	# 12 - change YYYYMMDD value column to numeric
	# 13 - fix threading for empty References/In-Reply-To
	#      (commit 83425ef12e4b65cdcecd11ddcb38175d4a91d5a0)
	# 14 - fix ghost root vivification
	SCHEMA_VERSION => 14,

	# n.b. FLAG_PURE_NOT is expensive not suitable for a public website
	# as it could become a denial-of-service vector
	QP_FLAGS => FLAG_PHRASE|FLAG_BOOLEAN|FLAG_LOVEHATE|FLAG_WILDCARD,
};

# setup prefixes
my %bool_pfx_internal = (
	type => 'T', # "mail" or "ghost"
	thread => 'G', # newsGroup (or similar entity - e.g. a web forum name)
);

my %bool_pfx_external = (
	mid => 'Q', # uniQue id (Message-ID)
);

my %prob_prefix = (
	# for mairix compatibility
	s => 'S',
	m => 'XMID', # 'mid:' (bool) is exact, 'm:' (prob) can do partial
	f => 'A',
	t => 'XTO',
	tc => 'XTO XCC',
	c => 'XCC',
	tcf => 'XTO XCC A',
	a => 'XTO XCC A',
	b => 'XNQ XQUOT',
	bs => 'XNQ XQUOT S',
	n => 'XFN',

	q => 'XQUOT',
	nq => 'XNQ',
	dfn => 'XDFN',
	dfa => 'XDFA',
	dfb => 'XDFB',
	dfhh => 'XDFHH',
	dfctx => 'XDFCTX',
	dfpre => 'XDFPRE',
	dfpost => 'XDFPOST',
	dfblob => 'XDFPRE XDFPOST',

	# default:
	'' => 'XMID S A XNQ XQUOT XFN',
);

# not documenting m: and mid: for now, the using the URLs works w/o Xapian
our @HELP = (
	's:' => 'match within Subject  e.g. s:"a quick brown fox"',
	'd:' => <<EOF,
date range as YYYYMMDD  e.g. d:19931002..20101002
Open-ended ranges such as d:19931002.. and d:..20101002
are also supported
EOF
	'b:' => 'match within message body, including text attachments',
	'nq:' => 'match non-quoted text within message body',
	'q:' => 'match quoted text within message body',
	'n:' => 'match filename of attachment(s)',
	't:' => 'match within the To header',
	'c:' => 'match within the Cc header',
	'f:' => 'match within the From header',
	'a:' => 'match within the To, Cc, and From headers',
	'tc:' => 'match within the To and Cc headers',
	'bs:' => 'match within the Subject and body',
	'dfn:' => 'match filename from diff',
	'dfa:' => 'match diff removed (-) lines',
	'dfb:' => 'match diff added (+) lines',
	'dfhh:' => 'match diff hunk header context (usually a function name)',
	'dfctx:' => 'match diff context lines',
	'dfpre:' => 'match pre-image git blob ID',
	'dfpost:' => 'match post-image git blob ID',
	'dfblob:' => 'match either pre or post-image git blob ID',
);
chomp @HELP;

my $mail_query = Search::Xapian::Query->new('T' . 'mail');

sub xdir {
	my (undef, $git_dir) = @_;
	"$git_dir/public-inbox/xapian" . SCHEMA_VERSION;
}

sub new {
	my ($class, $git_dir, $altid) = @_;
	my $dir = $class->xdir($git_dir);
	my $db = Search::Xapian::Database->new($dir);
	bless { xdb => $db, git_dir => $git_dir, altid => $altid }, $class;
}

sub reopen { $_[0]->{xdb}->reopen }

# read-only
sub query {
	my ($self, $query_string, $opts) = @_;
	my $query;

	$opts ||= {};
	unless ($query_string eq '') {
		$query = $self->qp->parse_query($query_string, QP_FLAGS);
		$opts->{relevance} = 1 unless exists $opts->{relevance};
	}

	_do_enquire($self, $query, $opts);
}

sub get_thread {
	my ($self, $mid, $opts) = @_;
	my $smsg = eval { $self->lookup_message($mid) };

	return { total => 0, msgs => [] } unless $smsg;
	my $qtid = Search::Xapian::Query->new('G' . $smsg->thread_id);
	my $path = $smsg->path;
	if (defined $path && $path ne '') {
		my $path = id_compress($smsg->path);
		my $qsub = Search::Xapian::Query->new('XPATH' . $path);
		$qtid = Search::Xapian::Query->new(OP_OR, $qtid, $qsub);
	}
	$opts ||= {};
	$opts->{limit} ||= 1000;

	# always sort threads by timestamp, this makes life easier
	# for the threading algorithm (in SearchThread.pm)
	$opts->{asc} = 1;

	_do_enquire($self, $qtid, $opts);
}

sub retry_reopen {
	my ($self, $cb) = @_;
	my $ret;
	for (1..10) {
		eval { $ret = $cb->() };
		return $ret unless $@;
		# Exception: The revision being read has been discarded -
		# you should call Xapian::Database::reopen()
		if (ref($@) eq 'Search::Xapian::DatabaseModifiedError') {
			reopen($self);
		} else {
			die;
		}
	}
}

sub _do_enquire {
	my ($self, $query, $opts) = @_;
	retry_reopen($self, sub { _enquire_once($self, $query, $opts) });
}

sub _enquire_once {
	my ($self, $query, $opts) = @_;
	my $enquire = $self->enquire;
	if (defined $query) {
		$query = Search::Xapian::Query->new(OP_AND,$query,$mail_query);
	} else {
		$query = $mail_query;
	}
	$enquire->set_query($query);
	$opts ||= {};
        my $desc = !$opts->{asc};
	if ($opts->{relevance}) {
		$enquire->set_sort_by_relevance_then_value(TS, $desc);
	} elsif ($opts->{num}) {
		$enquire->set_sort_by_value(NUM, 0);
	} else {
		$enquire->set_sort_by_value_then_relevance(TS, $desc);
	}
	my $offset = $opts->{offset} || 0;
	my $limit = $opts->{limit} || 50;
	my $mset = $enquire->get_mset($offset, $limit);
	return $mset if $opts->{mset};
	my @msgs = map {
		PublicInbox::SearchMsg->load_doc($_->get_document);
	} $mset->items;

	{ total => $mset->get_matches_estimated, msgs => \@msgs }
}

# read-write
sub stemmer { Search::Xapian::Stem->new($LANG) }

# read-only
sub qp {
	my ($self) = @_;

	my $qp = $self->{query_parser};
	return $qp if $qp;

	# new parser
	$qp = Search::Xapian::QueryParser->new;
	$qp->set_default_op(OP_AND);
	$qp->set_database($self->{xdb});
	$qp->set_stemmer($self->stemmer);
	$qp->set_stemming_strategy(STEM_SOME);
	$qp->add_valuerangeprocessor(
		Search::Xapian::NumberValueRangeProcessor->new(YYYYMMDD, 'd:'));

	while (my ($name, $prefix) = each %bool_pfx_external) {
		$qp->add_boolean_prefix($name, $prefix);
	}

	# we do not actually create AltId objects,
	# just parse the spec to avoid the extra DB handles for now.
	if (my $altid = $self->{altid}) {
		my $user_pfx = $self->{-user_pfx} ||= [];
		for (@$altid) {
			# $_ = 'serial:gmane:/path/to/gmane.msgmap.sqlite3'
			/\Aserial:(\w+):/ or next;
			my $pfx = $1;
			push @$user_pfx, "$pfx:", <<EOF;
alternate serial number  e.g. $pfx:12345 (boolean)
EOF
			# gmane => XGMANE
			$qp->add_boolean_prefix($pfx, 'X'.uc($pfx));
		}
		chomp @$user_pfx;
	}

	while (my ($name, $prefix) = each %prob_prefix) {
		$qp->add_prefix($name, $_) foreach split(/ /, $prefix);
	}

	$self->{query_parser} = $qp;
}

sub num_range_processor {
	$_[0]->{nrp} ||= Search::Xapian::NumberValueRangeProcessor->new(NUM);
}

# only used for NNTP server
sub query_xover {
	my ($self, $beg, $end, $offset) = @_;
	my $qp = Search::Xapian::QueryParser->new;
	$qp->set_database($self->{xdb});
	$qp->add_valuerangeprocessor($self->num_range_processor);
	my $query = $qp->parse_query("$beg..$end", QP_FLAGS);

	_do_enquire($self, $query, {num => 1, limit => 200, offset => $offset});
}

sub lookup_message {
	my ($self, $mid) = @_;
	$mid = mid_clean($mid);

	my $doc_id = $self->find_unique_doc_id('Q' . $mid);
	my $smsg;
	if (defined $doc_id) {
		# raises on error:
		my $doc = $self->{xdb}->get_document($doc_id);
		$smsg = PublicInbox::SearchMsg->wrap($doc, $mid);
		$smsg->{doc_id} = $doc_id;
	}
	$smsg;
}

sub lookup_mail { # no ghosts!
	my ($self, $mid) = @_;
	retry_reopen($self, sub {
		my $smsg = lookup_message($self, $mid) or return;
		$smsg->load_expand;
	});
}

sub find_unique_doc_id {
	my ($self, $termval) = @_;

	my ($begin, $end) = $self->find_doc_ids($termval);

	return undef if $begin->equal($end); # not found

	my $rv = $begin->get_docid;

	# sanity check
	$begin->inc;
	$begin->equal($end) or die "Term '$termval' is not unique\n";
	$rv;
}

# returns begin and end PostingIterator
sub find_doc_ids {
	my ($self, $termval) = @_;
	my $db = $self->{xdb};

	($db->postlist_begin($termval), $db->postlist_end($termval));
}

# normalize subjects so they are suitable as pathnames for URLs
# XXX: consider for removal
sub subject_path {
	my $subj = pop;
	$subj = subject_normalized($subj);
	$subj =~ s![^a-zA-Z0-9_\.~/\-]+!_!g;
	lc($subj);
}

sub subject_normalized {
	my $subj = pop;
	$subj =~ s/\A\s+//s; # no leading space
	$subj =~ s/\s+\z//s; # no trailing space
	$subj =~ s/\s+/ /gs; # no redundant spaces
	$subj =~ s/\.+\z//; # no trailing '.'
	$subj =~ s/$REPLY_RE//igo; # remove reply prefix
	$subj;
}

sub enquire {
	my ($self) = @_;
	$self->{enquire} ||= Search::Xapian::Enquire->new($self->{xdb});
}

sub help {
	my ($self) = @_;
	$self->qp; # parse altids
	my @ret = @HELP;
	if (my $user_pfx = $self->{-user_pfx}) {
		push @ret, @$user_pfx;
	}
	\@ret;
}

1;
