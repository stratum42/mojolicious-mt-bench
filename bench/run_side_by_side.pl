#!/usr/bin/env perl
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempfile);
use Getopt::Long qw(GetOptions);
use IO::Socket::INET;
use JSON::PP qw(decode_json);
use POSIX qw(:sys_wait_h);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC sleep);

sub _find_bin {
  my (@cands) = @_;
  for my $cand (@cands) {
    if ($cand =~ m{/}) {
      return $cand if -x $cand;
    }
    else {
      for my $dir (split /:/, ($ENV{PATH} // '')) {
        my $p = File::Spec->catfile($dir, $cand);
        return $p if -x $p;
      }
    }
  }
  return undef;
}

my $BENCH_REPO_DIR    = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
my $PARENT_DIR        = File::Spec->rel2abs(File::Spec->catdir($BENCH_REPO_DIR, '..'));
my $MOJO_MT_DIR       = $ENV{MOJO_MT_DIR}       // File::Spec->catdir($PARENT_DIR, 'mojolicious-mt');
my $MOJO_UPSTREAM_DIR = $ENV{MOJO_UPSTREAM_DIR} // File::Spec->catdir($MOJO_MT_DIR, '.upstream-base');
my $UPSTREAM_LIB      = File::Spec->catdir($MOJO_UPSTREAM_DIR, 'lib');
my $PERL5_MT_DIR      = $ENV{PERL5_MT_DIR}      // do {
  my $pgo = File::Spec->catdir($PARENT_DIR, 'perl5-mt-pgo');
  -d $pgo ? $pgo : File::Spec->catdir($PARENT_DIR, 'perl5-mt');
};
my $APP_SCRIPT   = File::Spec->catfile($Bin, 'app.pl');
my $POST_LUA     = File::Spec->catfile($Bin, 'post_json.lua');
my $MICRO_SCRIPT = File::Spec->catfile($Bin, 'microbench.pl');

my $STOCK_PERL   = $ENV{STOCK_PERL}   // (-x '/opt/homebrew/bin/perl' ? '/opt/homebrew/bin/perl' : (_find_bin('perl') // 'perl'));
my $MT_PERL      = $ENV{PERL5_MT}     // File::Spec->catfile($PERL5_MT_DIR, 'perl');
my $MT_PERL_LIB  = $ENV{PERL5_MT_LIB} // File::Spec->catdir($PERL5_MT_DIR, 'lib');
my $WRK_BIN      = $ENV{WRK_BIN}      // _find_bin('/opt/homebrew/bin/wrk', 'wrk') // 'wrk';

my $smoke       = 0;
my $out_file    = File::Spec->catfile($BENCH_REPO_DIR, 'BENCHMARK_RESULTS.md');
my $out_set     = 0;
my $duration    = 6;
my $passes      = 3;
my $warmup      = 2;
my $threads     = 4;
my $connections = 64;
my $skip_micro  = 0;

GetOptions(
  'smoke'         => \$smoke,
  'out=s'         => sub { $out_file = $_[1]; $out_set = 1; },
  'duration=i'    => \$duration,
  'passes=i'      => \$passes,
  'warmup=i'      => \$warmup,
  'threads=i'     => \$threads,
  'connections=i' => \$connections,
  'skip-micro'    => \$skip_micro,
) or die "Usage: $0 [--smoke] [--out FILE] [--duration 6] [--passes 3] [--warmup 2] [--threads 4] [--connections 64] [--skip-micro]\n";

if ($smoke) {
  $duration    = 2  if $duration == 6;
  $passes      = 1  if $passes == 3;
  $warmup      = 1  if $warmup == 2;
  $threads     = 2  if $threads == 4;
  $connections = 16 if $connections == 64;
}

my $ACTIVE_SERVER_PID;
my $ACTIVE_KEYDB_PID;
my $ACTIVE_KEYDB_LOG;

sub _cleanup_all {
  _stop_server($ACTIVE_SERVER_PID) if defined $ACTIVE_SERVER_PID;
  _stop_keydb() if defined $ACTIVE_KEYDB_PID;
}

END { local $?; _cleanup_all(); }
$SIG{PIPE} = 'IGNORE';
$SIG{INT}  = sub { _cleanup_all(); exit 130; };
$SIG{TERM} = sub { _cleanup_all(); exit 143; };

my @ENDPOINTS = (
  {id => 'plaintext', label => 'GET /plaintext',          path => '/plaintext',          lua => undef},
  {id => 'json_get',  label => 'GET /json (50 records)',  path => '/json',               lua => undef},
  {id => 'json_post', label => 'POST /json (50 records)', path => '/json',               lua => $POST_LUA},
  {id => 'template',  label => 'GET /template (25 rows)', path => '/template',           lua => undef},
  {id => 'static',    label => 'GET /static/payload.txt', path => '/static/payload.txt', lua => undef},
  {id => 'keydb',     label => 'GET /keydb/bench-key',    path => '/keydb/bench-key',    lua => undef},
  {id => 'cache',     label => 'GET /cache/bench-key',    path => '/cache/bench-key',    lua => undef},
);

my @SCALING_WORKERS   = (1, 2, 4, 8, 12);
my @SCALING_ENDPOINTS = ($ENDPOINTS[0], $ENDPOINTS[1]); # /plaintext and /json

if ($smoke) {
  run_smoke();
  exit 0;
}

run_full_suite();
exit 0;

# ---------------------------------------------------------------------------
# Helpers: process management, port selection, RSS sampling, wrk parsing
# ---------------------------------------------------------------------------

sub _find_free_port {
  my $sock = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1',
    LocalPort => 0,
    Proto     => 'tcp',
    Listen    => 1,
    ReuseAddr => 1,
  ) or die "Cannot allocate ephemeral port: $!\n";
  my $port = $sock->sockport;
  close $sock;
  return $port;
}

sub _find_keydb_bin {
  for my $cand ('keydb-server', '/opt/homebrew/bin/keydb-server', '/opt/homebrew/bin/redis-server', 'redis-server') {
    if ($cand =~ m{/}) {
      return $cand if -x $cand;
    }
    else {
      for my $dir (split /:/, ($ENV{PATH} // '')) {
        my $p = File::Spec->catfile($dir, $cand);
        return $p if -x $p;
      }
    }
  }
  die "Neither keydb-server nor redis-server found for /keydb benchmark\n";
}

sub _start_keydb {
  my $bin  = _find_keydb_bin();
  my $port = _find_free_port();
  my ($log_fh, $log_path) = tempfile('mojo_keydb_XXXX', TMPDIR => 1, UNLINK => 0);
  close $log_fh;

  my @cmd = ($bin, '--port', $port, '--bind', '127.0.0.1', '--save', '', '--appendonly', 'no', '--loglevel', 'warning');
  push @cmd, '--server-threads', '4' if $bin =~ /keydb-server/;
  my $pid = fork();
  die "fork keydb failed: $!\n" unless defined $pid;
  if ($pid == 0) {
    setpgrp(0, 0);
    open STDOUT, '>', $log_path or exit 126;
    open STDERR, '>&', \*STDOUT  or exit 126;
    exec(@cmd) or exit 127;
  }

  $ACTIVE_KEYDB_PID = $pid;
  $ACTIVE_KEYDB_LOG = $log_path;

  my $deadline = clock_gettime(CLOCK_MONOTONIC) + 10.0;
  my $ready    = 0;
  while (clock_gettime(CLOCK_MONOTONIC) < $deadline) {
    my $dead = waitpid($pid, WNOHANG);
    if ($dead > 0) {
      $ACTIVE_KEYDB_PID = undef;
      my $log = _slurp($log_path);
      unlink $log_path;
      die "RESP2 server ($bin) exited prematurely:\n$log\n";
    }
    my $sock = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Proto => 'tcp', Timeout => 0.2);
    if ($sock) {
      print $sock "*1\r\n\$4\r\nPING\r\n";
      my $line = <$sock>;
      close $sock;
      if (defined $line && $line =~ /^\+PONG/) {
        $ready = 1;
        last;
      }
    }
    sleep 0.02;
  }
  die "Timed out waiting for RESP2 server on port $port\n" unless $ready;

  my $ver = _cmd_line($bin, '--version');
  $ENV{MOJO_KEYDB_PORT} = $port;
  print STDERR "[bench] Started ephemeral RESP2 server on 127.0.0.1:$port ($ver)\n";
  return {pid => $pid, port => $port, bin => $bin, version => $ver};
}

sub _stop_keydb {
  my $pid = $ACTIVE_KEYDB_PID;
  return unless defined $pid;
  $ACTIVE_KEYDB_PID = undef;
  kill 'TERM', -$pid;
  kill 'TERM', $pid;
  my $deadline = clock_gettime(CLOCK_MONOTONIC) + 5.0;
  while (clock_gettime(CLOCK_MONOTONIC) < $deadline) {
    my $res = waitpid($pid, WNOHANG);
    last if $res > 0 || $res == -1;
    sleep 0.05;
  }
  kill 'KILL', -$pid;
  kill 'KILL', $pid;
  waitpid($pid, WNOHANG);
  unlink $ACTIVE_KEYDB_LOG if defined $ACTIVE_KEYDB_LOG && -f $ACTIVE_KEYDB_LOG;
  $ACTIVE_KEYDB_LOG = undef;
}

sub _mt_inc_flags {
  my @inc = ($MT_PERL_LIB);
  for my $xs_dir (qw(xs xs-keydb)) {
    my $xs_lib  = File::Spec->catdir($MOJO_MT_DIR, $xs_dir, 'blib', 'lib');
    my $xs_arch = File::Spec->catdir($MOJO_MT_DIR, $xs_dir, 'blib', 'arch');
    push @inc, $xs_lib, $xs_arch if -d $xs_lib && -d $xs_arch;
  }
  push @inc, File::Spec->catdir($MOJO_MT_DIR, 'lib');
  return map { "-I$_" } @inc;
}

sub _build_server_cmd {
  my ($cfg, $port) = @_;
  my $listen   = "http://127.0.0.1:$port";
  my $repo_lib = File::Spec->catdir($MOJO_MT_DIR, 'lib');

  if ($cfg->{mode} eq 'stock_daemon') {
    return (
      $STOCK_PERL, "-I$UPSTREAM_LIB", "-I$repo_lib", $APP_SCRIPT,
      'daemon', '-m', 'production', '-l', $listen,
      '-r', '100000', '-c', '1000',
    );
  }
  elsif ($cfg->{mode} eq 'mt_upstream_daemon') {
    return (
      $MT_PERL, "-I$MT_PERL_LIB", "-I$UPSTREAM_LIB", "-I$repo_lib", $APP_SCRIPT,
      'daemon', '-m', 'production', '-l', $listen,
      '-r', '100000', '-c', '1000',
    );
  }
  elsif ($cfg->{mode} eq 'stock_prefork') {
    my $w = $cfg->{workers} // 1;
    return (
      $STOCK_PERL, "-I$UPSTREAM_LIB", "-I$repo_lib", $APP_SCRIPT,
      'prefork', '-m', 'production', '-l', $listen,
      '-w', $w, '-s', '0', '-a', '1000000', '-r', '100000', '-c', '1000',
    );
  }
  elsif ($cfg->{mode} eq 'mt_server') {
    my $w = $cfg->{workers} // 1;
    return (
      $MT_PERL, _mt_inc_flags(), $APP_SCRIPT,
      'mt', '-w', $w, '-l', $listen, '-r', '100000', '-c', '1000', '-s',
    );
  }
  die "Unknown server mode: $cfg->{mode}\n";
}

sub _http_get_ok {
  my ($port, $path) = @_;
  my $sock = IO::Socket::INET->new(
    PeerAddr => '127.0.0.1',
    PeerPort => $port,
    Proto    => 'tcp',
    Timeout  => 0.25,
  ) or return 0;

  print $sock "GET $path HTTP/1.1\r\nHost: 127.0.0.1:$port\r\nConnection: close\r\n\r\n";
  my $line = <$sock>;
  close $sock;
  return (defined $line && $line =~ m{^HTTP/1\.[01]\s+200\b}) ? 1 : 0;
}

sub _start_server {
  my ($cfg) = @_;
  my $port = _find_free_port();
  my @cmd  = _build_server_cmd($cfg, $port);

  my ($log_fh, $log_path) = tempfile('mojo_bench_XXXX', TMPDIR => 1, UNLINK => 0);
  close $log_fh;

  my $t0  = clock_gettime(CLOCK_MONOTONIC);
  my $pid = fork();
  die "fork failed: $!\n" unless defined $pid;

  if ($pid == 0) {
    setpgrp(0, 0);
    $ENV{MOJO_MODE}        = 'production';
    $ENV{MOJO_LOG_LEVEL}   = 'error';
    $ENV{MOJO_NO_MT_ACCEL} = 1 if $cfg->{mode} eq 'mt_upstream_daemon';
    open STDOUT, '>', $log_path or exit 126;
    open STDERR, '>&', \*STDOUT  or exit 126;
    exec(@cmd) or do {
      print STDERR "exec failed for @cmd: $!\n";
      exit 127;
    };
  }

  $ACTIVE_SERVER_PID = $pid;

  # Wait until first 200 OK on /plaintext (max 20s)
  my $deadline   = $t0 + 20.0;
  my $startup_ms = undef;
  while (clock_gettime(CLOCK_MONOTONIC) < $deadline) {
    my $dead = waitpid($pid, WNOHANG);
    if ($dead > 0) {
      $ACTIVE_SERVER_PID = undef;
      my $log = _slurp($log_path);
      unlink $log_path;
      die "Server '$cfg->{name}' exited prematurely (status=$?):\n$log\n";
    }
    if (_http_get_ok($port, '/plaintext')) {
      $startup_ms = (clock_gettime(CLOCK_MONOTONIC) - $t0) * 1000.0;
      last;
    }
    sleep 0.005;
  }

  if (!defined $startup_ms) {
    _stop_server($pid);
    my $log = _slurp($log_path);
    unlink $log_path;
    die "Server '$cfg->{name}' timed out waiting for 200 OK on port $port:\n$log\n";
  }

  # Brief settle for prefork workers to finish spawning if >1 worker
  if ($cfg->{mode} eq 'stock_prefork' && ($cfg->{workers} // 1) > 1) {
    my $target = ($cfg->{workers} // 1) + 1; # manager + N workers
    my $settle_deadline = clock_gettime(CLOCK_MONOTONIC) + 5.0;
    while (clock_gettime(CLOCK_MONOTONIC) < $settle_deadline) {
      my ($rss, $cnt) = _sample_tree_rss($pid);
      last if $cnt >= $target;
      sleep 0.05;
    }
  }

  return {
    pid        => $pid,
    port       => $port,
    log_path   => $log_path,
    startup_ms => $startup_ms,
    workers    => $cfg->{workers} // 1,
    name       => $cfg->{name},
  };
}

sub _stop_server {
  my ($pid) = @_;
  return unless defined $pid;
  $ACTIVE_SERVER_PID = undef if defined $ACTIVE_SERVER_PID && $ACTIVE_SERVER_PID == $pid;

  # Signal entire process group
  kill 'TERM', -$pid;
  kill 'TERM', $pid;

  my $deadline = clock_gettime(CLOCK_MONOTONIC) + 5.0;
  while (clock_gettime(CLOCK_MONOTONIC) < $deadline) {
    my $res = waitpid($pid, WNOHANG);
    return if $res > 0 || $res == -1;
    sleep 0.05;
  }

  kill 'KILL', -$pid;
  kill 'KILL', $pid;
  waitpid($pid, 0);
}

sub _sample_tree_rss {
  my ($root_pid) = @_;
  open my $ps, '-|', 'ps', '-o', 'pid=,ppid=,rss=', '-ax' or return (0, 0);
  my (%children, %rss);
  while (my $line = <$ps>) {
    if ($line =~ /^\s*(\d+)\s+(\d+)\s+(\d+)/) {
      my ($p, $pp, $r) = ($1, $2, $3);
      $rss{$p} = $r;
      push @{$children{$pp}}, $p;
    }
  }
  close $ps;

  return (0, 0) unless exists $rss{$root_pid};

  my @queue = ($root_pid);
  my %seen  = ($root_pid => 1);
  my $total_kib = 0;
  my $count     = 0;
  while (my $p = shift @queue) {
    $total_kib += ($rss{$p} // 0);
    $count++;
    for my $c (@{$children{$p} // []}) {
      next if $seen{$c}++;
      push @queue, $c;
    }
  }
  return ($total_kib / 1024.0, $count);
}

sub _to_ms {
  my ($val, $unit) = @_;
  return $val / 1000.0 if $unit eq 'us';
  return $val          if $unit eq 'ms';
  return $val * 1000.0 if $unit eq 's';
  return $val * 60000.0 if $unit eq 'm';
  return $val;
}

sub _to_mbs {
  my ($val, $unit) = @_;
  return $val / (1024.0 * 1024.0) if $unit eq 'B';
  return $val / 1024.0            if $unit eq 'KB';
  return $val                     if $unit eq 'MB';
  return $val * 1024.0            if $unit eq 'GB';
  return $val;
}

sub _parse_wrk {
  my ($out) = @_;
  my %r = (
    rps          => 0,
    mbs          => undef,
    avg_ms       => undef,
    p50_ms       => undef,
    p99_ms       => undef,
    non_2xx      => 0,
    sock_errors  => 0,
    raw          => $out,
  );

  if ($out =~ /Requests\/sec:\s+([\d.]+)/) {
    $r{rps} = $1 + 0;
  }
  if ($out =~ /Transfer\/sec:\s+([\d.]+)(B|KB|MB|GB)/) {
    $r{mbs} = _to_mbs($1 + 0, $2);
  }
  if ($out =~ /Latency\s+([\d.]+)(us|ms|s|m)/) {
    $r{avg_ms} = _to_ms($1 + 0, $2);
  }
  if ($out =~ /^\s*50%\s+([\d.]+)(us|ms|s|m)/m) {
    $r{p50_ms} = _to_ms($1 + 0, $2);
  }
  if ($out =~ /^\s*99%\s+([\d.]+)(us|ms|s|m)/m) {
    $r{p99_ms} = _to_ms($1 + 0, $2);
  }
  if ($out =~ /Non-2xx or 3xx responses:\s+(\d+)/) {
    $r{non_2xx} = $1 + 0;
  }
  if ($out =~ /Socket errors:\s+connect\s+(\d+),\s+read\s+(\d+),\s+write\s+(\d+),\s+timeout\s+(\d+)/) {
    $r{sock_errors} = $1 + $2 + $3 + $4;
  }

  return \%r;
}

sub _run_wrk_with_rss {
  my ($server_pid, $url, $t, $c, $d, $lua, $sample_rss) = @_;
  my @cmd = ($WRK_BIN, "-t$t", "-c$c", "-d${d}s", '--latency');
  push @cmd, '-s', $lua if defined $lua;
  push @cmd, $url;

  my ($out_fh, $out_path) = tempfile('wrk_out_XXXX', TMPDIR => 1, UNLINK => 0);
  close $out_fh;

  my $wpid = fork();
  die "fork wrk failed: $!\n" unless defined $wpid;
  if ($wpid == 0) {
    open STDOUT, '>', $out_path or exit 126;
    open STDERR, '>&', \*STDOUT  or exit 126;
    exec @cmd;
    exit 127;
  }

  my @rss_samples;
  my $proc_count = 0;
  while (1) {
    my $res = waitpid($wpid, WNOHANG);
    last if $res > 0 || $res == -1;
    if ($sample_rss) {
      my ($mib, $cnt) = _sample_tree_rss($server_pid);
      push @rss_samples, $mib if $mib > 0;
      $proc_count = $cnt if $cnt > $proc_count;
    }
    sleep 0.4;
  }

  my $out = _slurp($out_path);
  unlink $out_path;

  my $parsed = _parse_wrk($out);
  if ($sample_rss) {
    if (!@rss_samples) {
      my ($mib, $cnt) = _sample_tree_rss($server_pid);
      push @rss_samples, $mib if $mib > 0;
      $proc_count = $cnt;
    }
    $parsed->{rss_mib}    = _median(@rss_samples);
    $parsed->{proc_count} = $proc_count;
  }
  return $parsed;
}

sub _bench_endpoint {
  my ($srv, $ep) = @_;
  my $url = "http://127.0.0.1:$srv->{port}$ep->{path}";

  # Warmup
  _run_wrk_with_rss($srv->{pid}, $url, ($threads > 2 ? 2 : $threads), ($connections > 16 ? 16 : $connections), $warmup, $ep->{lua}, 0);

  my @runs;
  for my $p (1 .. $passes) {
    my $r = _run_wrk_with_rss($srv->{pid}, $url, $threads, $connections, $duration, $ep->{lua}, 1);
    if ($r->{non_2xx} > 0 || $r->{sock_errors} > 0 || $r->{rps} <= 0) {
      die sprintf(
        "Benchmark error on %s %s (pass %d): rps=%.1f, non_2xx=%d, sock_errors=%d\n%s\n",
        $srv->{name}, $ep->{label}, $p, $r->{rps}, $r->{non_2xx}, $r->{sock_errors}, $r->{raw}
      );
    }
    push @runs, $r;
  }

  # Select median pass by rps
  @runs = sort { $a->{rps} <=> $b->{rps} } @runs;
  my $med = $runs[int(@runs / 2)];
  $med->{rss_per_worker} = ($med->{rss_mib} // 0) / ($srv->{workers} || 1);
  return $med;
}

sub _bench_server_endpoints {
  my ($cfg, $endpoints) = @_;
  print STDERR sprintf("[bench] Starting %-36s (workers=%d)...\n", $cfg->{name}, $cfg->{workers} // 1);
  my $srv = _start_server($cfg);
  print STDERR sprintf("        ready in %.1f ms (port %d)\n", $srv->{startup_ms}, $srv->{port});

  my %res = (
    startup_ms => $srv->{startup_ms},
    workers    => $srv->{workers},
    endpoints  => {},
  );

  eval {
    for my $ep (@$endpoints) {
      my $m = _bench_endpoint($srv, $ep);
      $res{endpoints}{$ep->{id}} = $m;
      print STDERR sprintf(
        "        %-24s %9.0f req/s | avg %5.2f ms | p50 %5.2f ms | p99 %5.2f ms | RSS %5.1f MiB (%.1f/w)\n",
        $ep->{label}, $m->{rps}, $m->{avg_ms} // 0, $m->{p50_ms} // 0, $m->{p99_ms} // 0,
        $m->{rss_mib} // 0, $m->{rss_per_worker} // 0,
      );
    }
  };
  my $err = $@;

  _stop_server($srv->{pid});
  unlink $srv->{log_path} if defined $srv->{log_path} && -f $srv->{log_path};
  die $err if $err;

  return \%res;
}

sub _slurp {
  my ($path) = @_;
  open my $fh, '<', $path or return '';
  local $/;
  my $s = <$fh>;
  close $fh;
  return $s // '';
}

sub _median {
  my @s = sort { $a <=> $b } @_;
  return 0 unless @s;
  my $mid = int(@s / 2);
  return (@s % 2) ? $s[$mid] : ($s[$mid - 1] + $s[$mid]) / 2;
}

sub _fmt_num {
  my ($n) = @_;
  return 'N/A' unless defined $n;
  my $s = sprintf('%.0f', $n);
  1 while $s =~ s/^(-?\d+)(\d{3})/$1,$2/;
  return $s;
}

sub _fmt_mbs {
  my ($n) = @_;
  return 'N/A' unless defined $n;
  return sprintf('%.2f', $n);
}

sub _fmt_ms {
  my ($n) = @_;
  return 'N/A' unless defined $n;
  return sprintf('%.2f ms', $n);
}

sub _fmt_mib {
  my ($n) = @_;
  return 'N/A' unless defined $n;
  return sprintf('%.1f MiB', $n);
}

sub _fmt_mult {
  my ($val, $base) = @_;
  return 'N/A' unless defined $val && defined $base && $base > 0;
  return sprintf('%.2fx', $val / $base);
}

sub _cmd_line {
  my @cmd = @_;
  open my $fh, '-|', @cmd or return 'unknown';
  my $line = <$fh>;
  close $fh;
  chomp($line //= 'unknown');
  return $line;
}

sub _display_path {
  my ($p) = @_;
  return $p unless defined $p;
  my $parent = $PARENT_DIR;
  $p =~ s/^\Q$parent\E(?=\/|$)/../;
  if (defined $ENV{HOME} && length $ENV{HOME}) {
    $p =~ s/^\Q$ENV{HOME}\E(?=\/|$)/~/;
  }
  return $p;
}

# ---------------------------------------------------------------------------
# Smoke mode (quick verification against Stock Perl + upstream Mojolicious)
# ---------------------------------------------------------------------------

sub run_smoke {
  print STDERR "=== Smoke Verification (Stock Perl 5.44 + .upstream-base) ===\n";
  _start_keydb();
  my $r1 = _bench_server_endpoints(
    {name => 'Stock 5.44 upstream (daemon)', mode => 'stock_daemon', workers => 1},
    \@ENDPOINTS,
  );
  my $r2 = _bench_server_endpoints(
    {name => 'Stock 5.44 upstream (prefork -w 2)', mode => 'stock_prefork', workers => 2},
    \@SCALING_ENDPOINTS,
  );
  _stop_keydb();
  print STDERR "=== Smoke Verification PASSED (0 non-2xx, 0 socket errors) ===\n";
}

# ---------------------------------------------------------------------------
# Full 3-way side-by-side benchmark suite + BENCHMARK_RESULTS.md writer
# ---------------------------------------------------------------------------

sub run_full_suite {
  my @md;

  my $keydb   = _start_keydb();
  my $cpu     = _cmd_line('sysctl', '-n', 'machdep.cpu.brand_string');
  my $ncpu    = _cmd_line('sysctl', '-n', 'hw.ncpu');
  my $macos   = _cmd_line('sw_vers', '-productVersion');
  my $stock_v = _cmd_line($STOCK_PERL, '-e', 'printf "%vd", $^V');
  my $mt_v    = _cmd_line($MT_PERL,    '-e', 'printf "%vd", $^V');
  my $git_sha = _cmd_line('git', '-C', $MOJO_MT_DIR, 'rev-parse', '--short', 'HEAD');
  my $up_sha  = _cmd_line('git', '-C', $MOJO_MT_DIR, 'rev-parse', '--short', 'upstream-base');

  my $stock_disp = _display_path($STOCK_PERL);
  my $mt_disp    = _display_path($MT_PERL);

  push @md, "# mojolicious-mt Benchmark Results\n";
  push @md, "Side-by-side comparison of unmodified upstream Mojolicious (`$up_sha`) vs `mojolicious-mt` (`$git_sha`) on `$cpu` ($ncpu cores, macOS $macos).\n";
  push @md, "## Test Environment & Methodology\n";
  push @md, "- **CPU / OS**: $cpu ($ncpu logical cores), macOS $macos (arm64)";
  push @md, "- **Stock Perl**: `v$stock_v` (`$stock_disp`) + `.upstream-base/lib`";
  push @md, "- **perl5-mt (PGO+native)**: `v$mt_v` (`$mt_disp`) + `mojolicious-mt` (`xs/blib` + `xs-keydb/blib` + `lib`)";
  push @md, "- **RESP2 Server**: `$keydb->{version}` (ephemeral local TCP instance, persistence disabled)";
  push @md, "- **Load Generator**: `wrk -t$threads -c$connections -d${duration}s --latency` (${warmup}s warmup, median of $passes measured runs, 0 non-2xx / 0 socket errors enforced)";
  push @md, "- **RSS Measurement**: Total process-tree RSS (`ps -o pid=,ppid=,rss= -ax`) sampled during active load (median MiB); `RSS/worker = Total RSS / workers`";
  push @md, "- **Reproduce**: `perl bench/run_side_by_side.pl` and `perl bench/microbench.pl`\n";

  # 1. Microbenchmarks
  if (!$skip_micro) {
    print STDERR "\n=== Part 1: Isolated Microbenchmarks ===\n";
    open my $mfh, '-|', $STOCK_PERL, $MICRO_SCRIPT, '--json', '--duration', '1.5', '--passes', $passes
      or die "Failed to run microbench.pl: $!\n";
    local $/;
    my $mjson = <$mfh>;
    close $mfh;
    die "microbench.pl failed (exit $?)\n" if $? != 0;

    my $m = decode_json($mjson);
    my $accel_on = $m->{data}{mt_accel}{data}{has_mt_accel} ? 'ON (Tier-1 XS/NEON)' : 'OFF (pure-Perl)';
    my $keydb_on = $m->{data}{mt_accel}{data}{has_keydb_xs} ? 'ON (Tier-1 XS/NEON)' : 'OFF (pure-Perl)';

    push @md, "## 1. Isolated Microbenchmarks (ops/sec)\n";
    push @md, "_`Mojo::MT::Accel`: **$accel_on** | `Mojo::MT::KeyDB::XS`: **$keydb_on** (median of $m->{passes} x $m->{duration}s passes)._\n";
    push @md, "| Operation | Stock 5.44 + upstream | perl5-mt + upstream | perl5-mt + mojolicious-mt | vs Stock 5.44 | vs perl5-mt upstream |";
    push @md, "|---|---:|---:|---:|---:|---:|";
    for my $item (@{$m->{order}}) {
      my $k  = $item->{key};
      my $s  = $m->{data}{stock_upstream}{data}{results}{$k}{ops_sec};
      my $mu = $m->{data}{mt_upstream}{data}{results}{$k}{ops_sec};
      my $ma = $m->{data}{mt_accel}{data}{results}{$k}{ops_sec};
      push @md, sprintf(
        "| %s | %s | %s | %s | **%s** | **%s** |",
        $item->{label}, _fmt_num($s), _fmt_num($mu), _fmt_num($ma),
        _fmt_mult($ma, $s), _fmt_mult($ma, $mu)
      );
    }
    push @md, "";
  }

  # 2. 1-Worker All-Endpoints Comparison
  print STDERR "\n=== Part 2: 1-Worker All-Endpoints Comparison ===\n";
  my $w1_stock = _bench_server_endpoints(
    {name => 'Stock 5.44 + upstream (daemon)', mode => 'stock_daemon', workers => 1},
    \@ENDPOINTS,
  );
  my $w1_mt_up = _bench_server_endpoints(
    {name => 'perl5-mt + upstream (daemon)', mode => 'mt_upstream_daemon', workers => 1},
    \@ENDPOINTS,
  );
  my $w1_mt = _bench_server_endpoints(
    {name => 'perl5-mt + mojolicious-mt (mt -w 1)', mode => 'mt_server', workers => 1},
    \@ENDPOINTS,
  );

  push @md, "## 2. Single-Worker All-Endpoints Comparison\n";
  push @md, sprintf(
    "- **Cold startup to first 200 OK**: Stock 5.44 `daemon` = **%.1f ms** | `perl5-mt` upstream `daemon` = **%.1f ms** | `perl5-mt` `mt -w 1` = **%.1f ms**\n",
    $w1_stock->{startup_ms}, $w1_mt_up->{startup_ms}, $w1_mt->{startup_ms}
  );
  push @md, "| Endpoint | Stock 5.44 daemon (req/s) | perl5-mt upstream daemon (req/s) | perl5-mt `mt -w 1` (req/s) | Speedup vs Stock | `mt -w 1` MB/s | `mt -w 1` Avg / p50 / p99 | Stock RSS | `mt -w 1` RSS |";
  push @md, "|---|---:|---:|---:|---:|---:|---:|---:|---:|";
  for my $ep (@ENDPOINTS) {
    my $id = $ep->{id};
    my $s  = $w1_stock->{endpoints}{$id};
    my $mu = $w1_mt_up->{endpoints}{$id};
    my $ma = $w1_mt->{endpoints}{$id};
    push @md, sprintf(
      "| %s | %s | %s | %s | **%s** | %s | %s / %s / %s | %s | %s |",
      $ep->{label},
      _fmt_num($s->{rps}), _fmt_num($mu->{rps}), _fmt_num($ma->{rps}),
      _fmt_mult($ma->{rps}, $s->{rps}),
      _fmt_mbs($ma->{mbs}),
      _fmt_ms($ma->{avg_ms}), _fmt_ms($ma->{p50_ms}), _fmt_ms($ma->{p99_ms}),
      _fmt_mib($s->{rss_mib}), _fmt_mib($ma->{rss_mib}),
    );
  }
  push @md, "";

  # 3. 8-Worker All-Endpoints Comparison
  print STDERR "\n=== Part 3: 8-Worker All-Endpoints Comparison ===\n";
  my $w8_stock = _bench_server_endpoints(
    {name => 'Stock 5.44 + upstream (prefork -w 8)', mode => 'stock_prefork', workers => 8},
    \@ENDPOINTS,
  );
  my $w8_mt = _bench_server_endpoints(
    {name => 'perl5-mt + mojolicious-mt (mt -w 8)', mode => 'mt_server', workers => 8},
    \@ENDPOINTS,
  );

  push @md, "## 3. 8-Worker All-Endpoints Comparison (`prefork -w 8` vs `mt -w 8`)\n";
  push @md, sprintf(
    "- **Cold startup to first 200 OK**: Stock 5.44 `prefork -w 8` = **%.1f ms** | `perl5-mt` `mt -w 8` = **%.1f ms**\n",
    $w8_stock->{startup_ms}, $w8_mt->{startup_ms}
  );
  push @md, "| Endpoint | Stock 5.44 `prefork -w 8` (req/s) | perl5-mt `mt -w 8` (req/s) | Speedup | Stock / `mt` MB/s | Stock p50 / p99 | `mt -w 8` p50 / p99 | Stock RSS (total / per-w) | `mt -w 8` RSS (total / per-w) | RSS Savings |";
  push @md, "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|";
  for my $ep (@ENDPOINTS) {
    my $id = $ep->{id};
    my $s  = $w8_stock->{endpoints}{$id};
    my $m  = $w8_mt->{endpoints}{$id};
    my $rss_sav = ($s->{rss_mib} > 0) ? sprintf('%.1f%%', (1 - $m->{rss_mib} / $s->{rss_mib}) * 100) : 'N/A';
    push @md, sprintf(
      "| %s | %s | %s | **%s** | %s / %s | %s / %s | %s / %s | %s (%s) | %s (%s) | **%s** |",
      $ep->{label},
      _fmt_num($s->{rps}), _fmt_num($m->{rps}), _fmt_mult($m->{rps}, $s->{rps}),
      _fmt_mbs($s->{mbs}), _fmt_mbs($m->{mbs}),
      _fmt_ms($s->{p50_ms}), _fmt_ms($s->{p99_ms}),
      _fmt_ms($m->{p50_ms}), _fmt_ms($m->{p99_ms}),
      _fmt_mib($s->{rss_mib}), _fmt_mib($s->{rss_per_worker}),
      _fmt_mib($m->{rss_mib}), _fmt_mib($m->{rss_per_worker}),
      $rss_sav,
    );
  }
  push @md, "";
  my $mt_cache_rps   = $w8_mt->{endpoints}{cache}{rps};
  my $stock_kdb_rps  = $w8_stock->{endpoints}{keydb}{rps};
  my $mt_kdb_rps     = $w8_mt->{endpoints}{keydb}{rps};
  push @md, sprintf(
    "> **Shared State Architecture Note (8 workers)**: Apples-to-apples over loopback KeyDB/RESP2 (`/keydb/bench-key`), `perl5-mt mt -w 8` (`Mojo::MT::KeyDB::XS` `MY_CXT` persistent sockets) achieves **%s req/s** vs Stock 5.44 `prefork -w 8` at **%s req/s** (**%s**). When replacing external networked shared state with in-process zero-network `MT::SharedHash` (`/cache/bench-key` at **%s req/s**), `mojolicious-mt` delivers **%s** higher throughput than Stock `prefork` + KeyDB.\n",
    _fmt_num($mt_kdb_rps), _fmt_num($stock_kdb_rps), _fmt_mult($mt_kdb_rps, $stock_kdb_rps),
    _fmt_num($mt_cache_rps), _fmt_mult($mt_cache_rps, $stock_kdb_rps)
  );
  print STDERR "\n=== Part 4: Multi-Worker Scaling Sweep (1, 2, 4, 8, 12 workers) ===\n";
  my (%scale_stock, %scale_mt);
  for my $w (@SCALING_WORKERS) {
    if ($w == 8) {
      # Reuse 8-worker results from Part 3 to save time and ensure exact consistency
      $scale_stock{$w} = $w8_stock;
      $scale_mt{$w}    = $w8_mt;
      next;
    }
    $scale_stock{$w} = _bench_server_endpoints(
      {name => "Stock 5.44 prefork -w $w", mode => 'stock_prefork', workers => $w},
      \@SCALING_ENDPOINTS,
    );
    $scale_mt{$w} = _bench_server_endpoints(
      {name => "perl5-mt mt -w $w", mode => 'mt_server', workers => $w},
      \@SCALING_ENDPOINTS,
    );
  }

  push @md, "## 4. Multi-Worker Scaling Sweep (`1, 2, 4, 8, 12` workers)\n";
  for my $ep (@SCALING_ENDPOINTS) {
    my $id = $ep->{id};
    push @md, "### $ep->{label}\n";
    push @md, "| Workers | Stock `prefork` (req/s) | `perl5-mt mt` (req/s) | Speedup | Stock Avg / p50 / p99 | `mt` Avg / p50 / p99 | Stock RSS (Total / per-w) | `mt` RSS (Total / per-w) |";
    push @md, "|---:|---:|---:|---:|---:|---:|---:|---:|";
    for my $w (@SCALING_WORKERS) {
      my $s = $scale_stock{$w}{endpoints}{$id};
      my $m = $scale_mt{$w}{endpoints}{$id};
      push @md, sprintf(
        "| %d | %s | %s | **%s** | %s / %s / %s | %s / %s / %s | %s (%s) | %s (%s) |",
        $w,
        _fmt_num($s->{rps}), _fmt_num($m->{rps}), _fmt_mult($m->{rps}, $s->{rps}),
        _fmt_ms($s->{avg_ms}), _fmt_ms($s->{p50_ms}), _fmt_ms($s->{p99_ms}),
        _fmt_ms($m->{avg_ms}), _fmt_ms($m->{p50_ms}), _fmt_ms($m->{p99_ms}),
        _fmt_mib($s->{rss_mib}), _fmt_mib($s->{rss_per_worker}),
        _fmt_mib($m->{rss_mib}), _fmt_mib($m->{rss_per_worker}),
      );
    }
    push @md, "";
  }

  my $content = join("\n", @md) . "\n";
  open my $fh, '>', $out_file or die "Cannot write $out_file: $!\n";
  print $fh $content;
  close $fh;
  print STDERR "\nWrote benchmark report to $out_file\n";
}
