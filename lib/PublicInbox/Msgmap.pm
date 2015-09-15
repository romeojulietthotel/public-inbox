# Copyright (C) 2015 all contributors <meta@public-inbox.org>
# License: AGPLv3 or later (https://www.gnu.org/licenses/agpl-3.0.txt)
# bidirectional Message-ID <-> Article Number mapping
package PublicInbox::Msgmap;
use strict;
use warnings;
use fields qw(dbh mid_insert mid_for num_for);
use DBI;
use DBD::SQLite;

sub new {
	my ($class, $git_dir, $writable) = @_;
	my $d = "$git_dir/public-inbox";
	if ($writable && !-d $d && !mkdir $d) {
		my $err = $!;
		-d $d or die "$d not created: $err";
	}
	my $f = "$d/msgmap.sqlite3";
	my $dbh = DBI->connect("dbi:SQLite:dbname=$f",'','', {
		AutoCommit => 1,
		RaiseError => 1,
		PrintError => 0,
		sqlite_use_immediate_transaction => 1,
	});
	$dbh->do('PRAGMA case_sensitive_like = ON');

	$writable and create_tables($dbh);
	my $self = fields::new($class);
	$self->{dbh} = $dbh;
	$self;
}

# accessor
sub last_commit {
	my ($self, $commit) = @_;
	my $dbh = $self->{dbh};
	my $prev;
	use constant {
		key => 'last_commit',
		meta_select => 'SELECT val FROM meta WHERE key = ? LIMIT 1',
		meta_update => 'UPDATE meta SET val = ? WHERE key = ? LIMIT 1',
		meta_insert => 'INSERT INTO meta (key,val) VALUES (?,?)',
	};

	defined $commit or
		return $dbh->selectrow_array(meta_select, undef, key);

	$dbh->begin_work;
	eval {
		$prev = $dbh->selectrow_array(meta_select, undef, key);

		if (defined $prev) {
			$dbh->do(meta_update, undef, $commit, key);
		} else {
			$dbh->do(meta_insert, undef, key, $commit);
		}
		$dbh->commit;
	};
	return $prev unless $@;

	$dbh->rollback;
	die $@;
}

sub mid_insert {
	my ($self, $mid) = @_;
	my $dbh = $self->{dbh};
	use constant MID_INSERT => 'INSERT INTO msgmap (mid) VALUES (?)';
	my $sth = $self->{mid_insert} ||= $dbh->prepare(MID_INSERT);
	$sth->bind_param(1, $mid);
	$sth->execute;
	$dbh->last_insert_id(undef, undef, 'msgmap', 'num');
}

use constant MID_FOR => 'SELECT mid FROM msgmap WHERE num = ? LIMIT 1';
sub mid_for {
	my ($self, $num) = @_;
	my $dbh = $self->{dbh};
	my $sth = $self->{mid_for} ||= $dbh->prepare(MID_FOR);
	$sth->bind_param(1, $num);
	$sth->execute;
	$sth->fetchrow_array;
}

sub num_for {
	my ($self, $mid) = @_;
	my $dbh = $self->{dbh};
	use constant NUM_FOR => 'SELECT num FROM msgmap WHERE mid = ? LIMIT 1';
	my $sth = $self->{num_for} ||= $dbh->prepare(NUM_FOR);
	$sth->bind_param(1, $mid);
	$sth->execute;
	$sth->fetchrow_array;
}

sub mid_prefixes {
	my ($self, $pfx, $limit) = @_;

	die "No prefix given" unless (defined $pfx && $pfx ne '');
	$pfx =~ s/([%_])/\\$1/g;
	$pfx .= '%';

	$limit ||= 100;
	$limit += 0; # force to integer
	$limit ||= 100;

	$self->{dbh}->selectcol_arrayref('SELECT mid FROM msgmap ' .
					 'WHERE mid LIKE ? ESCAPE ? ' .
					 "ORDER BY num DESC LIMIT $limit",
					 undef, $pfx, '\\');
}

sub mid_delete {
	my ($self, $mid) = @_;
	my $dbh = $self->{dbh};
	use constant MID_DELETE => 'DELETE FROM msgmap WHERE mid = ?';
	my $sth = $dbh->prepare(MID_DELETE);
	$sth->bind_param(1, $mid);
	$sth->execute;
}

sub create_tables {
	my ($dbh) = @_;
	my $e;

	$e = eval { $dbh->selectrow_array('EXPLAIN SELECT * FROM msgmap;') };
	defined $e or $dbh->do('CREATE TABLE msgmap (' .
			'num INTEGER PRIMARY KEY AUTOINCREMENT, '.
			'mid VARCHAR(1000) NOT NULL, ' .
			'UNIQUE (mid) )');

	$e = eval { $dbh->selectrow_array('EXPLAIN SELECT * FROM meta') };
	defined $e or $dbh->do('CREATE TABLE meta (' .
			'key VARCHAR(32) PRIMARY KEY, '.
			'val VARCHAR(255) NOT NULL)');
}

1;