# Copyright (C) 2016 all contributors <meta@public-inbox.org>
# License: AGPL-3.0+ <https://www.gnu.org/licenses/agpl-3.0.txt>
package PublicInbox::Spawn;
use strict;
use warnings;
use base qw(Exporter);
our @EXPORT_OK = qw/which spawn/;

my $vfork_spawn = <<'VFORK_SPAWN';
#include <sys/types.h>
#include <sys/uio.h>
#include <unistd.h>
#include <alloca.h>

#define AV_ALLOCA(av, max) alloca((max = (av_len((av)) + 1)) * sizeof(char *))

static void av2c_copy(char **dst, AV *src, I32 max)
{
	I32 i;

	for (i = 0; i < max; i++) {
		SV **sv = av_fetch(src, i, 0);
		dst[i] = sv ? SvPV_nolen(*sv) : 0;
	}
	dst[max] = 0;
}

static void *deconst(const char *s)
{
	union { const char *in; void *out; } u;
	u.in = s;
	return u.out;
}

/* needs to be safe inside a vfork'ed process */
static void xerr(const char *msg)
{
	struct iovec iov[3];
	const char *err = strerror(errno); /* should be safe in practice */

	iov[0].iov_base = deconst(msg);
	iov[0].iov_len = strlen(msg);
	iov[1].iov_base = deconst(err);
	iov[1].iov_len = strlen(err);
	iov[2].iov_base = deconst("\n");
	iov[2].iov_len = 1;
	writev(2, iov, 3);
	_exit(1);
}

#define REDIR(var,fd) do { \
	if (var != fd && dup2(var, fd) < 0) \
		xerr("error redirecting std"#var ": "); \
} while (0)

/*
 * unstable internal API.  This was easy to implement but does not
 * support arbitrary redirects.  It'll be updated depending on
 * whatever we'll need in the future.
 * Be sure to update PublicInbox::SpawnPP if this changes
 */
int public_inbox_fork_exec(int in, int out, int err,
			SV *file, SV *cmdref, SV *envref)
{
	AV *cmd = (AV *)SvRV(cmdref);
	AV *env = (AV *)SvRV(envref);
	const char *filename = SvPV_nolen(file);
	pid_t pid;
	char **argv, **envp;
	I32 max;

	argv = AV_ALLOCA(cmd, max);
	av2c_copy(argv, cmd, max);

	envp = AV_ALLOCA(env, max);
	av2c_copy(envp, env, max);

	pid = vfork();
	if (pid == 0) {
		REDIR(in, 0);
		REDIR(out, 1);
		REDIR(err, 2);
		execve(filename, argv, envp);
		xerr("execve failed");
	}

	return (int)pid;
}
VFORK_SPAWN

my $inline_dir = $ENV{PERL_INLINE_DIRECTORY};
$vfork_spawn = undef unless defined $inline_dir && -d $inline_dir && -w _;
if (defined $vfork_spawn) {
	# Inline 0.64 or later has locking in multi-process env,
	# but we support 0.5 on Debian wheezy
	use Fcntl qw(:flock);
	eval {
		my $f = "$inline_dir/.public-inbox.lock";
		open my $fh, '>', $f or die "failed to open $f: $!\n";
		flock($fh, LOCK_EX) or die "LOCK_EX failed on $f: $!\n";
		eval 'use Inline C => $vfork_spawn';
		flock($fh, LOCK_UN) or die "LOCK_UN failed on $f: $!\n";
	};
	if ($@) {
		warn "Inline::C failed for vfork: $@\n";
		$vfork_spawn = undef;
	}
}

unless (defined $vfork_spawn) {
	require PublicInbox::SpawnPP;
	no warnings 'once';
	*public_inbox_fork_exec = *PublicInbox::SpawnPP::public_inbox_fork_exec
}

sub which ($) {
	my ($file) = @_;
	foreach my $p (split(':', $ENV{PATH})) {
		$p .= "/$file";
		return $p if -x $p;
	}
	undef;
}

sub spawn ($;$$) {
	my ($cmd, $env, $opts) = @_;
	my $f = which($cmd->[0]);
	defined $f or die "$cmd->[0]: command not found\n";
	my @env;
	$opts ||= {};

	my %env = $opts->{-env} ? () : %ENV;
	if ($env) {
		foreach my $k (keys %$env) {
			my $v = $env->{$k};
			if (defined $v) {
				$env{$k} = $v;
			} else {
				delete $env{$k};
			}
		}
	}
	while (my ($k, $v) = each %env) {
		push @env, "$k=$v";
	}
	my $in = $opts->{0} || 0;
	my $out = $opts->{1} || 1;
	my $err = $opts->{2} || 2;
	public_inbox_fork_exec($in, $out, $err, $f, $cmd, \@env);
}

1;