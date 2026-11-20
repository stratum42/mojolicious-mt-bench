#!/usr/bin/env perl
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempfile);
use Getopt::Long qw(GetOptions);
use IO::Socket::INET;
use JSON::PP qw(decode_json encode_json);
use POSIX qw(:sys_wait_h);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC sleep);

my $POLY_DIR          = $Bin;
my $BENCH_DIR         = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
my $BENCH_REPO_DIR    = File::Spec->rel2abs(File::Spec->catdir($BENCH_DIR, '..'));
my $PARENT_DIR        = File::Spec->rel2abs(File::Spec->catdir($BENCH_REPO_DIR, '..'));
my $MOJO_MT_DIR       = $ENV{MOJO_MT_DIR}       // File::Spec->catdir($PARENT_DIR, 'mojolicious-mt');
my $MOJO_UPSTREAM_DIR = $ENV{MOJO_UPSTREAM_DIR} // File::Spec->catdir($MOJO_MT_DIR, '.upstream-base');
my $UPSTREAM_LIB      = File::Spec->catdir($MOJO_UPSTREAM_DIR, 'lib');
my $PERL5_MT_DIR      = $ENV{PERL5_MT_DIR}      // do {
  my $pgo = File::Spec->catdir($PARENT_DIR, 'perl5-mt-pgo');
  -d $pgo ? $pgo : File::Spec->catdir($PARENT_DIR, 'perl5-mt');
};
my $APP_SCRIPT   = File::Spec->catfile($BENCH_DIR, 'app.pl');
my $POST_LUA     = File::Spec->catfile($BENCH_DIR, 'post_json.lua');
my $PUBLIC_DIR   = File::Spec->catdir($BENCH_DIR, 'public');
my $NODE_SERVER  = File::Spec->catfile($POLY_DIR, 'server.mjs');
my $GO_SOURCE    = File::Spec->catfile($POLY_DIR, 'server.go');
my $GO_SERVER    = File::Spec->catfile($POLY_DIR, 'server_go');

my $STOCK_PERL   = $ENV{STOCK_PERL}   // (-x '/opt/homebrew/bin/perl' ? '/opt/homebrew/bin/perl' : (_find_bin('perl') // 'perl'));
my $MT_PERL      = $ENV{PERL5_MT}     // File::Spec->catfile($PERL5_MT_DIR, 'perl');
my $MT_PERL_LIB  = $ENV{PERL5_MT_LIB} // File::Spec->catdir($PERL5_MT_DIR, 'lib');
my $NODE_BIN     = $ENV{NODE_BIN}     // _find_bin('node', '/opt/homebrew/bin/node');
my $GO_BIN       = $ENV{GO_BIN}       // _find_bin('go', '/opt/homebrew/bin/go');
my $WRK_BIN      = $ENV{WRK_BIN}      // _find_bin('wrk', '/opt/homebrew/bin/wrk');

my $smoke       = 0;
my $out_file    = File::Spec->catfile($BENCH_REPO_DIR, 'BENCHMARK_POLYGLOT.md');
my $workers     = 8;
my $duration    = 4;
my $passes      = 3;
my $warmup      = 1;
my $threads     = 4;
my $connections = 64;

GetOptions(
  'smoke'         => \$smoke,
  'out=s'         => \$out_file,
  'workers=i'     => \$workers,
  'duration=i'    => \$duration,
  'passes=i'      => \$passes,
  'warmup=i'      => \$warmup,
  'threads=i'     => \$threads,
  'connections=i' => \$connections,
) or die "Usage: $0 [--smoke] [--out FILE] [--workers 8] [--duration 4] [--passes 3] [--warmup 1] [--threads 4] [--connections 64]\n";

if ($smoke) {
  $duration    = 1  if $duration == 4;
  $passes      = 1  if $passes == 3;
  $warmup      = 1  if $warmup == 1;
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

run_polyglot_suite();
exit 0;

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

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

sub _cmd_line {
  my @cmd = @_;
  open my $fh, '-|', @cmd or return 'unknown';
  my $line = <$fh>;
  close $fh;
  chomp($line //= 'unknown');
  return $line;
}

sub _slurp {
  my ($path) = @_;
  open my $fh, '<', $path or return '';
  local $/;
  my $s = <$fh>;
  close $fh;
  return $s // '';
}

sub _ensure_go_binary {
  return 0 unless defined $GO_BIN && -x $GO_BIN;
  if (!-x $GO_SERVER || (stat($GO_SOURCE))[9] > (stat($GO_SERVER))[9]) {
    print STDERR "[bench] Building Go server: $GO_BIN build -o $GO_SERVER $GO_SOURCE\n";
    my $rc = system($GO_BIN, 'build', '-o', $GO_SERVER, $GO_SOURCE);
    die "go build failed (exit $rc)\n" if $rc != 0;
  }
  return 1;
}

sub _start_keydb {
  my $bin  = _find_bin('/opt/homebrew/bin/keydb-server', 'keydb-server', '/opt/homebrew/bin/redis-server', 'redis-server')
    or die "keydb-server / redis-server not found\n";
  my $port = _find_free_port();
  my ($log_fh, $log_path) = tempfile('mojo_poly_keydb_XXXX', TMPDIR => 1, UNLINK => 0);
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
      die "KeyDB exited prematurely:\n$log\n";
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
  die "Timed out waiting for KeyDB on port $port\n" unless $ready;

  my $ver = _cmd_line($bin, '--version');
  $ENV{MOJO_KEYDB_PORT} = $port;
  print STDERR "[bench] Started ephemeral KeyDB on 127.0.0.1:$port ($ver)\n";
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
  my ($cfg, $port, $keydb_port) = @_;
  my $listen   = "http://127.0.0.1:$port";
  my $repo_lib = File::Spec->catdir($MOJO_MT_DIR, 'lib');
  my $w        = $cfg->{workers};

  if ($cfg->{id} eq 'stock_perl') {
    return (
      $STOCK_PERL, "-I$UPSTREAM_LIB", "-I$repo_lib", $APP_SCRIPT,
      'prefork', '-m', 'production', '-l', $listen,
      '-w', $w, '-s', '0', '-a', '1000000', '-r', '100000', '-c', '1000',
    );
  }
  elsif ($cfg->{id} eq 'mojo_mt') {
    return (
      $MT_PERL, _mt_inc_flags(), $APP_SCRIPT,
      'mt', '-w', $w, '-l', $listen, '-r', '100000', '-c', '1000', '-s',
    );
  }
  elsif ($cfg->{id} eq 'nodejs') {
    return (
      $NODE_BIN, $NODE_SERVER,
      '--port', $port, '--workers', $w, '--keydb-port', $keydb_port, '--public-dir', $PUBLIC_DIR,
    );
  }
  elsif ($cfg->{id} eq 'golang') {
    return (
      $GO_SERVER,
      '-port', $port, '-workers', $w, '-keydb-port', $keydb_port, '-public-dir', $PUBLIC_DIR,
    );
  }
  die "Unknown runtime id: $cfg->{id}\n";
}

sub _http_request {
  my ($port, $method, $path, $body, $ctype) = @_;
  my $sock = IO::Socket::INET->new(
    PeerAddr => '127.0.0.1',
    PeerPort => $port,
    Proto    => 'tcp',
    Timeout  => 2.0,
  ) or return (0, '', '');

  my $req = "$method $path HTTP/1.1\r\nHost: 127.0.0.1:$port\r\nConnection: close\r\n";
  if (defined $body) {
    $req .= "Content-Type: " . ($ctype // 'application/json') . "\r\n";
    $req .= "Content-Length: " . length($body) . "\r\n";
  }
  $req .= "\r\n";
  $req .= $body if defined $body;

  print $sock $req;
  local $/;
  my $raw = <$sock>;
  close $sock;
  return (0, '', '') unless defined $raw && length $raw;

  my ($hdrs, $resp_body) = split /\r\n\r\n/, $raw, 2;
  $resp_body //= '';
  my $status = 0;
  if ($hdrs =~ m{^HTTP/1\.[01]\s+(\d{3})\b}) {
    $status = int($1);
  }
  return ($status, $hdrs, $resp_body);
}

sub _build_post_json_body {
  my @parts;
  for my $i (1 .. 50) {
    my $role   = ($i % 5 == 0) ? 'admin' : 'member';
    my $active = ($i % 3 != 0) ? 'true'  : 'false';
    my $score  = sprintf('%.2f', 10.5 + $i * 1.25);
    push @parts, sprintf(
      '{"id":%d,"name":"User %d <dev> & \\"ops\\"","email":"user%d@example.com","role":"%s","active":%s,"score":%s}',
      $i, $i, $i, $role, $active, $score
    );
  }
  return '{"status":"req","items":[' . join(',', @parts) . ']}';
}

sub _verify_parity {
  my ($cfg, $port) = @_;
  my %bytes;

  # 1. GET /plaintext
  {
    my ($st, $hdrs, $body) = _http_request($port, 'GET', '/plaintext');
    die "[$cfg->{name}] GET /plaintext failed: HTTP $st\n" unless $st == 200;
    die "[$cfg->{name}] GET /plaintext body mismatch: '$body'\n" unless $body eq 'Hello, World!';
    $bytes{plaintext} = length($body);
  }

  # 2. GET /json
  {
    my ($st, $hdrs, $body) = _http_request($port, 'GET', '/json');
    die "[$cfg->{name}] GET /json failed: HTTP $st\n" unless $st == 200;
    my $d = eval { decode_json($body) };
    die "[$cfg->{name}] GET /json invalid JSON: $@\n" if $@ || ref $d ne 'HASH';
    die "[$cfg->{name}] GET /json shape mismatch (count=$d->{count})\n"
      unless ($d->{status} // '') eq 'ok' && ($d->{count} // 0) == 50 && ref $d->{items} eq 'ARRAY' && scalar(@{$d->{items}}) == 50;
    $bytes{json_get} = length($body);
  }

  # 3. POST /json
  {
    my $req_body = _build_post_json_body();
    my ($st, $hdrs, $body) = _http_request($port, 'POST', '/json', $req_body, 'application/json');
    die "[$cfg->{name}] POST /json failed: HTTP $st\n" unless $st == 200;
    my $d = eval { decode_json($body) };
    die "[$cfg->{name}] POST /json invalid JSON: $@\n" if $@ || ref $d ne 'HASH';
    die "[$cfg->{name}] POST /json checksum mismatch: count=$d->{count}, checksum=$d->{checksum}\n"
      unless ($d->{status} // '') eq 'ok' && ($d->{count} // 0) == 50 && ($d->{checksum} // 0) == 211875;
    $bytes{json_post} = length($body);
  }

  # 4. GET /template
  {
    my ($st, $hdrs, $body) = _http_request($port, 'GET', '/template');
    die "[$cfg->{name}] GET /template failed: HTTP $st\n" unless $st == 200;
    my $rows = () = $body =~ /<tr><td>/g;
    die "[$cfg->{name}] GET /template row count mismatch: $rows\n" unless $rows == 25;
    die "[$cfg->{name}] GET /template missing HTML escaping\n"
      unless index($body, '&lt;script&gt;') >= 0 && index($body, '<script>') == -1;
    $bytes{template} = length($body);
  }

  # 5. GET /static/payload.txt
  {
    my ($st, $hdrs, $body) = _http_request($port, 'GET', '/static/payload.txt');
    die "[$cfg->{name}] GET /static/payload.txt failed: HTTP $st\n" unless $st == 200;
    die "[$cfg->{name}] GET /static/payload.txt size mismatch: " . length($body) . "\n" unless length($body) == 16384;
    $bytes{static} = length($body);
  }

  # 6. GET /keydb/bench-key (verify 2 consecutive calls increment count)
  {
    my ($st1, undef, $b1) = _http_request($port, 'GET', '/keydb/bench-key');
    die "[$cfg->{name}] GET /keydb/bench-key (1) failed: HTTP $st1 ($b1)\n" unless $st1 == 200;
    my $d1 = eval { decode_json($b1) };
    die "[$cfg->{name}] GET /keydb/bench-key (1) invalid JSON: $@\n" if $@ || ref $d1 ne 'HASH';
    my ($st2, undef, $b2) = _http_request($port, 'GET', '/keydb/bench-key');
    die "[$cfg->{name}] GET /keydb/bench-key (2) failed: HTTP $st2 ($b2)\n" unless $st2 == 200;
    my $d2 = eval { decode_json($b2) };
    die "[$cfg->{name}] GET /keydb/bench-key (2) invalid JSON: $@\n" if $@ || ref $d2 ne 'HASH';
    die "[$cfg->{name}] GET /keydb/bench-key value/count mismatch: $b1 -> $b2\n"
      unless ($d2->{key} // '') eq 'bench-key'
      && ($d2->{value} // '') eq 'keydb:bench-key:v1'
      && ($d2->{count} // 0) == ($d1->{count} // 0) + 1;
    $bytes{keydb} = length($b2);
  }

  # 7. GET /cache/bench-key
  {
    my ($st, $hdrs, $body) = _http_request($port, 'GET', '/cache/bench-key');
    die "[$cfg->{name}] GET /cache/bench-key failed: HTTP $st\n" unless $st == 200;
    my $d = eval { decode_json($body) };
    die "[$cfg->{name}] GET /cache/bench-key invalid JSON: $@\n" if $@ || ref $d ne 'HASH';
    die "[$cfg->{name}] GET /cache/bench-key shape mismatch: $body\n"
      unless ($d->{key} // '') eq 'bench-key' && ($d->{value} // '') eq 'cached:bench-key:v1';
    my $is_shared = $d->{shared} ? 1 : 0;
    die "[$cfg->{name}] GET /cache/bench-key shared flag mismatch: got $is_shared, expected $cfg->{expect_shared}\n"
      unless $is_shared == $cfg->{expect_shared};
    $bytes{cache} = length($body);
  }

  print STDERR sprintf(
    "        parity OK: plaintext=%dB, json_get=%dB, json_post=%dB, template=%dB, static=%dB, keydb=%dB, cache=%dB\n",
    @bytes{qw(plaintext json_get json_post template static keydb cache)}
  );
  return \%bytes;
}

sub _start_server {
  my ($cfg, $keydb_port) = @_;
  my $port = _find_free_port();
  my @cmd  = _build_server_cmd($cfg, $port, $keydb_port);

  my ($log_fh, $log_path) = tempfile('mojo_poly_srv_XXXX', TMPDIR => 1, UNLINK => 0);
  close $log_fh;

  my $t0  = clock_gettime(CLOCK_MONOTONIC);
  my $pid = fork();
  die "fork failed: $!\n" unless defined $pid;

  if ($pid == 0) {
    setpgrp(0, 0);
    $ENV{MOJO_MODE}       = 'production';
    $ENV{MOJO_LOG_LEVEL}  = 'error';
    $ENV{MOJO_KEYDB_PORT} = $keydb_port;
    $ENV{GOMAXPROCS}      = $cfg->{workers} if $cfg->{id} eq 'golang';
    open STDOUT, '>', $log_path or exit 126;
    open STDERR, '>&', \*STDOUT  or exit 126;
    exec(@cmd) or do {
      print STDERR "exec failed for @cmd: $!\n";
      exit 127;
    };
  }

  $ACTIVE_SERVER_PID = $pid;

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
    my ($st) = _http_request($port, 'GET', '/plaintext');
    if ($st == 200) {
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

  # Wait for multi-process servers (prefork / node:cluster) to finish spawning all workers
  if ($cfg->{multi_proc} && $cfg->{workers} > 1) {
    my $target          = $cfg->{workers} + 1; # master/primary + N workers
    my $settle_deadline = clock_gettime(CLOCK_MONOTONIC) + 5.0;
    while (clock_gettime(CLOCK_MONOTONIC) < $settle_deadline) {
      my (undef, $cnt) = _sample_tree_rss($pid);
      last if $cnt >= $target;
      sleep 0.05;
    }
    sleep 0.15;
  }

  return {
    pid        => $pid,
    port       => $port,
    log_path   => $log_path,
    startup_ms => $startup_ms,
    workers    => $cfg->{workers},
    name       => $cfg->{name},
  };
}

sub _stop_server {
  my ($pid) = @_;
  return unless defined $pid;
  $ACTIVE_SERVER_PID = undef if defined $ACTIVE_SERVER_PID && $ACTIVE_SERVER_PID == $pid;

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

  my @queue     = ($root_pid);
  my %seen      = ($root_pid => 1);
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
  return $val / 1000.0  if $unit eq 'us';
  return $val           if $unit eq 'ms';
  return $val * 1000.0  if $unit eq 's';
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
    rps         => 0,
    mbs         => undef,
    avg_ms      => undef,
    p50_ms      => undef,
    p99_ms      => undef,
    non_2xx     => 0,
    sock_errors => 0,
    raw         => $out,
  );
  $r{rps}    = $1 + 0               if $out =~ /Requests\/sec:\s+([\d.]+)/;
  $r{mbs}    = _to_mbs($1 + 0, $2)  if $out =~ /Transfer\/sec:\s+([\d.]+)(B|KB|MB|GB)/;
  $r{avg_ms} = _to_ms($1 + 0, $2)   if $out =~ /Latency\s+([\d.]+)(us|ms|s|m)/;
  $r{p50_ms} = _to_ms($1 + 0, $2)   if $out =~ /^\s*50%\s+([\d.]+)(us|ms|s|m)/m;
  $r{p99_ms} = _to_ms($1 + 0, $2)   if $out =~ /^\s*99%\s+([\d.]+)(us|ms|s|m)/m;
  $r{non_2xx} = $1 + 0              if $out =~ /Non-2xx or 3xx responses:\s+(\d+)/;
  if ($out =~ /Socket errors:\s+connect\s+(\d+),\s+read\s+(\d+),\s+write\s+(\d+),\s+timeout\s+(\d+)/) {
    $r{sock_errors} = $1 + $2 + $3 + $4;
  }
  return \%r;
}

sub _median {
  my @s = sort { $a <=> $b } @_;
  return 0 unless @s;
  my $mid = int(@s / 2);
  return (@s % 2) ? $s[$mid] : ($s[$mid - 1] + $s[$mid]) / 2;
}

sub _run_wrk_with_rss {
  my ($server_pid, $url, $t, $c, $d, $lua, $sample_rss) = @_;
  my @cmd = ($WRK_BIN, "-t$t", "-c$c", "-d${d}s", '--latency');
  push @cmd, '-s', $lua if defined $lua;
  push @cmd, $url;

  my ($out_fh, $out_path) = tempfile('wrk_poly_XXXX', TMPDIR => 1, UNLINK => 0);
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
    sleep 0.35;
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
  _run_wrk_with_rss(
    $srv->{pid}, $url,
    ($threads > 2 ? 2 : $threads),
    ($connections > 16 ? 16 : $connections),
    $warmup, $ep->{lua}, 0
  );

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

  @runs = sort { $a->{rps} <=> $b->{rps} } @runs;
  my $med = $runs[int(@runs / 2)];
  $med->{rss_per_worker} = ($med->{rss_mib} // 0) / ($srv->{workers} || 1);
  return $med;
}

sub _fmt_num {
  my ($n) = @_;
  return 'N/A' unless defined $n;
  my $s = sprintf('%.0f', $n);
  1 while $s =~ s/^(-?\d+)(\d{3})/$1,$2/;
  return $s;
}

sub _fmt_mbs { defined $_[0] ? sprintf('%.2f', $_[0]) : 'N/A' }
sub _fmt_ms  { defined $_[0] ? sprintf('%.2f ms', $_[0]) : 'N/A' }
sub _fmt_mib { defined $_[0] ? sprintf('%.1f MiB', $_[0]) : 'N/A' }
sub _fmt_mult {
  my ($val, $base) = @_;
  return 'N/A' unless defined $val && defined $base && $base > 0;
  return sprintf('%.2fx', $val / $base);
}

sub run_polyglot_suite {
  my $has_go   = _ensure_go_binary();
  my $has_node = (defined $NODE_BIN && -x $NODE_BIN) ? 1 : 0;

  my $keydb = _start_keydb();

  my @runtimes = (
    {
      id            => 'stock_perl',
      name          => 'Stock Perl 5.44 (prefork)',
      short         => 'Stock Perl',
      workers       => $workers,
      multi_proc    => 1,
      expect_shared => 0,
    },
    {
      id            => 'mojo_mt',
      name          => 'perl5-mt-pgo (mojolicious-mt)',
      short         => 'mojolicious-mt',
      workers       => $workers,
      multi_proc    => 0,
      expect_shared => 1,
    },
  );
  if ($has_node) {
    push @runtimes, {
      id            => 'nodejs',
      name          => 'Node.js (cluster + node:http)',
      short         => 'Node.js',
      workers       => $workers,
      multi_proc    => 1,
      expect_shared => 0,
    };
  }
  if ($has_go) {
    push @runtimes, {
      id            => 'golang',
      name          => 'Go (net/http)',
      short         => 'Go',
      workers       => $workers,
      multi_proc    => 0,
      expect_shared => 1,
    };
  }

  my %results;
  for my $rt (@runtimes) {
    print STDERR sprintf("\n[bench] === %s (workers=%d) ===\n", $rt->{name}, $rt->{workers});
    my $srv = _start_server($rt, $keydb->{port});
    print STDERR sprintf("        ready in %.1f ms (port %d)\n", $srv->{startup_ms}, $srv->{port});

    my $parity;
    my %ep_res;
    eval {
      $parity = _verify_parity($rt, $srv->{port});
      for my $ep (@ENDPOINTS) {
        my $m = _bench_endpoint($srv, $ep);
        $ep_res{$ep->{id}} = $m;
        print STDERR sprintf(
          "        %-24s %9.0f req/s | %7.2f MB/s | p50 %5.2f ms | p99 %5.2f ms | RSS %5.1f MiB (%.1f/w, %d procs)\n",
          $ep->{label}, $m->{rps}, $m->{mbs} // 0, $m->{p50_ms} // 0, $m->{p99_ms} // 0,
          $m->{rss_mib} // 0, $m->{rss_per_worker} // 0, $m->{proc_count} // 0,
        );
      }
    };
    my $err = $@;
    _stop_server($srv->{pid});
    unlink $srv->{log_path} if defined $srv->{log_path} && -f $srv->{log_path};
    die $err if $err;

    $results{$rt->{id}} = {
      cfg        => $rt,
      startup_ms => $srv->{startup_ms},
      parity     => $parity,
      endpoints  => \%ep_res,
    };
  }

  _stop_keydb();

  return if $smoke;

  # Write BENCHMARK_POLYGLOT.md
  my $cpu     = _cmd_line('sysctl', '-n', 'machdep.cpu.brand_string');
  my $ncpu    = _cmd_line('sysctl', '-n', 'hw.ncpu');
  my $macos   = _cmd_line('sw_vers', '-productVersion');
  my $stock_v = _cmd_line($STOCK_PERL, '-e', 'printf "%vd", $^V');
  my $mt_v    = _cmd_line($MT_PERL,    '-e', 'printf "%vd", $^V');
  my $node_v  = $has_node ? _cmd_line($NODE_BIN, '-v') : 'not installed';
  my $go_v    = $has_go   ? _cmd_line($GO_BIN, 'version') : 'not installed';
  my $git_sha = _cmd_line('git', '-C', $MOJO_MT_DIR, 'rev-parse', '--short', 'HEAD');

  my $stock_disp = _display_path($STOCK_PERL);

  my @md;
  push @md, "# Polyglot HTTP Benchmark Comparison (`mojolicious-mt`, Stock Perl, Node.js, and Go)\n";
  push @md, "An $workers-worker cross-runtime HTTP benchmark comparison on `$cpu` ($ncpu cores, macOS $macos, `mojolicious-mt` commit `$git_sha`) against a live local KeyDB instance.\n";

  push @md, "## Test Environment & Methodology\n";
  push @md, "- **Hardware / OS**: $cpu ($ncpu logical cores), macOS $macos (arm64)";
  push @md, "- **Concurrency budget**: **$workers server workers**";
  push @md, "- **Stock Perl**: `v$stock_v` (`$stock_disp`) + upstream Mojolicious (`prefork -w $workers`)";
  push @md, "- **`mojolicious-mt`**: `perl5-mt-pgo` (`v$mt_v`, PGO+native) + `mojolicious-mt` (`mt -w $workers`, Tier-1 XS/NEON + `Mojo::MT::KeyDB`)";
  push @md, "- **Node.js**: `$node_v` (`node:cluster` with $workers workers + raw `node:http`, zero external dependencies)";
  push @md, "- **Go**: `$go_v` (`GOMAXPROCS=$workers`, stdlib `net/http` + `encoding/json` + `html/template`, zero external dependencies)";
  push @md, "- **Live KeyDB**: `$keydb->{version}` (ephemeral local TCP instance, `--server-threads 4 --save \"\" --appendonly no`)";
  push @md, "- **Load Generator**: `wrk -t$threads -c$connections -d${duration}s --latency` (${warmup}s warmup, median of $passes measured passes, 0 non-2xx and 0 socket errors enforced)";
  push @md, "- **RSS Measurement**: Total process-tree RSS (`ps -o pid=,ppid=,rss= -ax`) sampled during active load (median MiB); `RSS/worker = Total RSS / $workers`";
  push @md, "- **Reproduce**: `perl bench/polyglot/run_polyglot.pl`\n";

  # Section 1: Headline Throughput & Ratios
  push @md, "## 1. Throughput Comparison (8 Workers, req/s)\n";
  push @md, "| Endpoint | Stock Perl (`prefork -w $workers`) | **`mojolicious-mt` (`mt -w $workers`)** | Node.js (`cluster` x$workers) | Go (`GOMAXPROCS=$workers`) | `mojo-mt` vs Stock | `mojo-mt` vs Node.js | `mojo-mt` vs Go |";
  push @md, "|---|---:|---:|---:|---:|---:|---:|---:|";
  for my $ep (@ENDPOINTS) {
    my $id = $ep->{id};
    my $sp = $results{stock_perl}{endpoints}{$id}{rps};
    my $mt = $results{mojo_mt}{endpoints}{$id}{rps};
    my $nd = $has_node ? $results{nodejs}{endpoints}{$id}{rps} : undef;
    my $go = $has_go   ? $results{golang}{endpoints}{$id}{rps} : undef;
    push @md, sprintf(
      "| %s | %s | **%s** | %s | %s | **%s** | **%s** | **%s** |",
      $ep->{label},
      _fmt_num($sp), _fmt_num($mt), _fmt_num($nd), _fmt_num($go),
      _fmt_mult($mt, $sp), _fmt_mult($mt, $nd), _fmt_mult($mt, $go),
    );
  }
  push @md, "";

  # Section 2: Latency & Bandwidth
  push @md, "## 2. Latency (p50 / p99) & Bandwidth (MB/s)\n";
  push @md, "| Endpoint | Stock Perl (p50 / p99, MB/s) | **`mojolicious-mt` (p50 / p99, MB/s)** | Node.js (p50 / p99, MB/s) | Go (p50 / p99, MB/s) |";
  push @md, "|---|---:|---:|---:|---:|";
  for my $ep (@ENDPOINTS) {
    my $id = $ep->{id};
    my @cols;
    for my $rid (qw(stock_perl mojo_mt nodejs golang)) {
      if (exists $results{$rid}) {
        my $m = $results{$rid}{endpoints}{$id};
        push @cols, sprintf('%s / %s (%s MB/s)', _fmt_ms($m->{p50_ms}), _fmt_ms($m->{p99_ms}), _fmt_mbs($m->{mbs}));
      }
      else {
        push @cols, 'N/A';
      }
    }
    push @md, sprintf('| %s | %s | **%s** | %s | %s |', $ep->{label}, @cols);
  }
  push @md, "";

  # Section 3: Memory Footprint & Cold Startup
  push @md, "## 3. Memory Footprint (Active Load RSS) & Cold Startup\n";
  push @md, "| Runtime | Process Model | Cold Startup (to 1st 200 OK) | Median Total RSS (across endpoints) | Peak Total RSS | RSS / Worker (median) | Shared In-Process Cache? |";
  push @md, "|---|---|---:|---:|---:|---:|---|";
  my %model_desc = (
    stock_perl => "Multi-process (`prefork`: 1 mgr + $workers workers)",
    mojo_mt    => "Single-process multi-thread (`mt`: 1 proc, $workers threads)",
    nodejs     => "Multi-process (`node:cluster`: 1 primary + $workers workers)",
    golang     => "Single-process goroutines (`GOMAXPROCS=$workers`)",
  );
  my %cache_desc = (
    stock_perl => 'No (per-worker `%LOCAL_CACHE`)',
    mojo_mt    => 'Yes (`MT::SharedHash`)',
    nodejs     => 'No (per-worker `Map`)',
    golang     => 'Yes (`sync.Map`)',
  );
  for my $rt (@runtimes) {
    my $id = $rt->{id};
    my $r  = $results{$id};
    my @rss_vals = map { $r->{endpoints}{$_->{id}}{rss_mib} } @ENDPOINTS;
    my $med_rss  = _median(@rss_vals);
    my ($peak_rss) = sort { $b <=> $a } @rss_vals;
    push @md, sprintf(
      "| %s | %s | %.1f ms | %s | %s | %s | %s |",
      $rt->{name}, $model_desc{$id}, $r->{startup_ms},
      _fmt_mib($med_rss), _fmt_mib($peak_rss), _fmt_mib($med_rss / $workers),
      $cache_desc{$id},
    );
  }
  push @md, "";

  # Per-endpoint RSS table
  push @md, "### Per-Endpoint Active RSS (Total MiB / per worker)\n";
  push @md, "| Endpoint | Stock Perl | `mojolicious-mt` | Node.js | Go |";
  push @md, "|---|---:|---:|---:|---:|";
  for my $ep (@ENDPOINTS) {
    my $id = $ep->{id};
    my @cols;
    for my $rid (qw(stock_perl mojo_mt nodejs golang)) {
      if (exists $results{$rid}) {
        my $m = $results{$rid}{endpoints}{$id};
        push @cols, sprintf('%.1f MiB (%.1f/w)', $m->{rss_mib}, $m->{rss_per_worker});
      }
      else {
        push @cols, 'N/A';
      }
    }
    push @md, sprintf('| %s | %s | %s | %s | %s |', $ep->{label}, @cols);
  }
  push @md, "";

  # Section 4: Parity Verification
  push @md, "## 4. Endpoint Parity Verification\n";
  push @md, "Before benchmarking each runtime, `run_polyglot.pl` asserts HTTP 200, JSON schema/checksums (`checksum == 211875`), 25 HTML-escaped table rows (`&lt;script&gt;`), exact 16,384-byte static payload, live KeyDB `INCR` monotonicity, and `/cache/:key` shared-state flags.\n";
  push @md, "| Endpoint | Stock Perl (bytes) | `mojolicious-mt` (bytes) | Node.js (bytes) | Go (bytes) |";
  push @md, "|---|---:|---:|---:|---:|";
  for my $ep (@ENDPOINTS) {
    my $id = $ep->{id};
    my @cols = map { exists $results{$_} ? $results{$_}{parity}{$id} : 'N/A' } qw(stock_perl mojo_mt nodejs golang);
    push @md, sprintf('| %s | %s | %s | %s | %s |', $ep->{label}, @cols);
  }
  push @md, "";

  # Section 5: Transparent Methodology Notes
  push @md, "## 5. Methodology Notes & Caveats\n";
  push @md, "- **Full web framework vs raw stdlib HTTP**: Both Perl entries run the full **Mojolicious** web framework (router, controller/stash lifecycle, renderer, static dispatcher, plugins/hooks). Node.js runs raw `node:http` with direct pathname dispatch (no Express/Fastify middleware stack), and Go runs stdlib `net/http` `ServeMux` with `encoding/json` and `html/template`.";
  push @md, "- **No pre-serialized JSON or HTML shortcuts**: Every runtime dynamically encodes the 50-record JSON object on every `GET /json`, decodes + sums + encodes on every `POST /json`, and dynamically escapes and renders all 25 HTML rows on every `GET /template`.";
  push @md, "- **Static asset caching parity**: All 4 runtimes `stat` `bench/public/static/payload.txt` on every request and serve cached in-memory bytes when `mtime` and `size` match (mirroring `Mojolicious::Static`).";
  push @md, "- **Live KeyDB RESP2 parity**: Every runtime uses persistent TCP sockets (`TCP_NODELAY`) to the same ephemeral KeyDB 6.3.4 instance (`--server-threads 4`) and executes two sequential RESP2 commands per request (`INCR bench:cnt:<key>` then `GET bench:val:<key>`). `mojolicious-mt` uses its Tier-1 XS/NEON `Mojo::MT::KeyDB::XS` client; Stock Perl uses the pure-Perl `Mojo::MT::KeyDB` fallback; Node.js uses a persistent queued RESP2 `net.Socket` per worker; Go uses a persistent pooled `net.Conn` RESP2 client.";
  push @md, "- **In-process shared cache (`/cache/:key`)**: `mojolicious-mt` (`MT::SharedHash`) and Go (`sync.Map`) share a single in-process cache across all 8 workers (`shared: true`). Stock Perl `prefork` and Node.js `node:cluster` run 8 isolated OS worker processes that cannot share in-process memory, so they serve from per-worker maps (`shared: false`) — their `/cache/:key` throughput reflects local-only reads without cross-worker coherence.";
  push @md, "";

  open my $fh, '>', $out_file or die "Cannot write $out_file: $!\n";
  print $fh join("\n", @md);
  close $fh;

  print STDERR "\n[bench] Wrote report to $out_file\n";
}
