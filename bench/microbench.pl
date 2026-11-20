#!/usr/bin/env perl
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;
use Getopt::Long qw(GetOptions);
use JSON::PP qw(encode_json decode_json);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

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
my $STOCK_PERL  = $ENV{STOCK_PERL}   // (-x '/opt/homebrew/bin/perl' ? '/opt/homebrew/bin/perl' : (_find_bin('perl') // 'perl'));
my $MT_PERL     = $ENV{PERL5_MT}     // File::Spec->catfile($PERL5_MT_DIR, 'perl');
my $MT_PERL_LIB = $ENV{PERL5_MT_LIB} // File::Spec->catdir($PERL5_MT_DIR, 'lib');

my $worker_mode = 0;
my $duration    = 1.5;
my $passes      = 3;
my $stock_only  = 0;
my $emit_json   = 0;

GetOptions(
  'worker'     => \$worker_mode,
  'duration=f' => \$duration,
  'passes=i'   => \$passes,
  'stock-only' => \$stock_only,
  'json'       => \$emit_json,
) or die "Usage: $0 [--duration 1.5] [--passes 3] [--stock-only] [--json]\n";

if ($worker_mode) {
  run_worker($duration, $passes);
  exit 0;
}

run_driver();
exit 0;

sub _median {
  my @s = sort { $a <=> $b } @_;
  return 0 unless @s;
  my $mid = int(@s / 2);
  return (@s % 2) ? $s[$mid] : ($s[$mid - 1] + $s[$mid]) / 2;
}

sub run_worker {
  my ($dur, $npasses) = @_;

  require Mojo::Message::Request;
  require Mojo::Transaction::HTTP;
  require Mojo::JSON;
  require Mojo::Util;

  my $has_mt       = 0;
  my $has_mt_accel = 0;
  my $has_keydb_xs = 0;
  if (eval { require Mojo::MT; 1 }) {
    $has_mt       = Mojo::MT::HAS_MT()       ? 1 : 0;
    $has_mt_accel = Mojo::MT::HAS_MT_ACCEL() ? 1 : 0;
  }
  my $has_keydb = eval { require Mojo::MT::KeyDB; 1 } ? 1 : 0;
  $has_keydb_xs = ($has_keydb && Mojo::MT::KeyDB::HAS_KEYDB_XS()) ? 1 : 0;

  # 1. Realistic HTTP/1.1 request with 10 headers
  my $raw_http = join("\r\n",
    'GET /api/v1/items?limit=50&offset=0&sort=score_desc HTTP/1.1',
    'Host: bench.example.com:8080',
    'User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/537.36',
    'Accept: application/json, text/plain, */*',
    'Accept-Encoding: gzip, deflate, br',
    'Accept-Language: en-US,en;q=0.9',
    'Connection: keep-alive',
    'Cache-Control: no-cache',
    'X-Request-Id: 8f3e2d1c-9b4a-4f0e-8c1a-7d6e5f4a3b2c',
    'X-Forwarded-For: 192.168.1.42, 10.0.0.1',
    'Cookie: session=abc123def456; theme=dark; tz=UTC',
    '', ''
  );

  # 2. 50-record JSON payload (matches bench/app.pl GET /json)
  my @items;
  for my $i (1 .. 50) {
    push @items, {
      id     => $i,
      name   => "Benchmark User $i",
      email  => "user$i\@example.com",
      role   => ($i % 5 == 0 ? 'admin' : 'member'),
      active => ($i % 3 != 0 ? Mojo::JSON::true() : Mojo::JSON::false()),
      score  => 10.5 + ($i * 1.25),
      tags   => ['perf', 'mojo', 'tier-' . ($i % 4)],
      meta   => {region => ($i % 2 ? 'us-east' : 'eu-west'), rev => $i},
    };
  }
  my $payload50 = {status => 'ok', count => 50, items => \@items};
  my $json50    = Mojo::JSON::encode_json($payload50);

  # 3. HTML string (~2 KiB with special chars)
  my $html_str = (qq{<tr><td>Item #1 &amp; <script>alert("xss")</script> 'test' > 0</td></tr>\n}) x 28;

  # 4. URL strings
  my $url_raw = 'search=hello world & filter=price>100&tag=c++/perl5-mt/mojo?foo=bar#frag ' x 4;
  my $url_esc = Mojo::Util::url_escape($url_raw);

  # 5. Base64 1 KiB payload
  my $bin_1k = join('', map { chr($_ % 256) } 0 .. 1023);
  my $b64_1k = Mojo::Util::b64_encode($bin_1k, '');

  # 6. HTTP/1.1 response build payload
  my $http_body = '{"status":"ok","key":"bench-key","value":"cached:bench-key:v1","shared":true}';

  # 7. KeyDB RESP2 command encode & 10-element array reply decode
  my @resp_cmd = ('SET', 'session:user:12345', $http_body, 'EX', '3600');
  my $resp_reply = "*10\r\n" . join('', map { my $v = "value-record-$_-payload-0123456789"; '$' . length($v) . "\r\n$v\r\n" } 1 .. 10);

  my @cases = (
    [
      'http_parse',
      'HTTP/1.1 request + header parse',
      sub {
        my $req = Mojo::Message::Request->new;
        $req->parse($raw_http);
        return $req->is_finished;
      },
    ],
    [
      'http_build',
      'HTTP/1.1 response build (server_write)',
      sub {
        my $tx = Mojo::Transaction::HTTP->new;
        $tx->req->version('1.1');
        my $res = $tx->res;
        $res->code(200);
        $res->headers->content_type('application/json;charset=UTF-8');
        $res->headers->server('Mojolicious (Perl)');
        $res->headers->header('X-Bench' => '1');
        $res->body($http_body);
        $tx->resume;
        return $tx->server_write;
      },
    ],
    [
      'json_encode',
      'Mojo::JSON encode (50 records)',
      sub { Mojo::JSON::encode_json($payload50) },
    ],
    [
      'json_decode',
      'Mojo::JSON decode (50 records)',
      sub { Mojo::JSON::decode_json($json50) },
    ],
    [
      'xml_escape',
      'Mojo::Util::xml_escape (~2 KiB)',
      sub { Mojo::Util::xml_escape($html_str) },
    ],
    [
      'url_escape',
      'Mojo::Util::url_escape (~280 B)',
      sub { Mojo::Util::url_escape($url_raw) },
    ],
    [
      'url_unescape',
      'Mojo::Util::url_unescape (~390 B)',
      sub { Mojo::Util::url_unescape($url_esc) },
    ],
    [
      'b64_encode',
      'Mojo::Util::b64_encode (1 KiB)',
      sub { Mojo::Util::b64_encode($bin_1k, '') },
    ],
    [
      'b64_decode',
      'Mojo::Util::b64_decode (1 KiB)',
      sub { Mojo::Util::b64_decode($b64_1k) },
    ],
  );

  if ($has_keydb) {
    push @cases, (
      [
        'resp_encode',
        'Mojo::MT::KeyDB RESP2 encode (SET EX)',
        $has_keydb_xs
          ? sub { Mojo::MT::KeyDB::XS::encode_cmd(@resp_cmd) }
          : sub { Mojo::MT::KeyDB::_pp_encode_cmd(@resp_cmd) },
      ],
      [
        'resp_decode',
        'Mojo::MT::KeyDB RESP2 decode (10-elem array)',
        $has_keydb_xs
          ? sub { Mojo::MT::KeyDB::XS::decode_reply($resp_reply) }
          : sub { my $pos = 0; Mojo::MT::KeyDB::_pp_parse_reply(\$resp_reply, \$pos, 0, 0) },
      ],
    );
  }

  my %results;
  my @order;

  for my $case (@cases) {
    my ($key, $label, $code) = @$case;
    push @order, {key => $key, label => $label};

    # Warmup & calibrate batch size (~50ms per batch)
    my $batch = 10;
    my $wt0   = clock_gettime(CLOCK_MONOTONIC);
    for (1 .. $batch) { $code->() }
    my $wel = clock_gettime(CLOCK_MONOTONIC) - $wt0;
    while ($wel < 0.02 && $batch < 100_000) {
      $batch *= 4;
      $wt0 = clock_gettime(CLOCK_MONOTONIC);
      for (1 .. $batch) { $code->() }
      $wel = clock_gettime(CLOCK_MONOTONIC) - $wt0;
    }

    my @rates;
    for my $p (1 .. $npasses) {
      my $count = 0;
      my $t0    = clock_gettime(CLOCK_MONOTONIC);
      my $end   = $t0 + $dur;
      while (1) {
        for (1 .. $batch) { $code->() }
        $count += $batch;
        my $now = clock_gettime(CLOCK_MONOTONIC);
        if ($now >= $end) {
          push @rates, $count / ($now - $t0);
          last;
        }
      }
    }

    $results{$key} = {
      label   => $label,
      ops_sec => _median(@rates),
      passes  => \@rates,
    };
  }

  print encode_json({
    perl_version => sprintf('%vd', $^V),
    has_mt       => $has_mt,
    has_mt_accel => $has_mt_accel,
    has_keydb_xs => $has_keydb_xs,
    order        => \@order,
    results      => \%results,
  }), "\n";
}

sub _run_runtime {
  my ($rt) = @_;
  my @cmd = (
    $rt->{perl},
    (map { "-I$_" } @{$rt->{inc}}),
    $0, '--worker', '--duration', $duration, '--passes', $passes
  );

  open my $fh, '-|', @cmd or die "Failed to spawn $rt->{name}: $!\n";
  local $/;
  my $out = <$fh>;
  close $fh;
  my $rc = $?;
  die "Runtime '$rt->{name}' failed (exit $rc): $out\n" if $rc != 0;

  return decode_json($out);
}

sub _fmt_ops {
  my ($n) = @_;
  return 'N/A' unless defined $n;
  my $s = sprintf('%.0f', $n);
  1 while $s =~ s/^(-?\d+)(\d{3})/$1,$2/;
  return $s;
}

sub _fmt_mult {
  my ($val, $base) = @_;
  return 'N/A' unless defined $val && defined $base && $base > 0;
  return sprintf('%.2fx', $val / $base);
}

sub run_driver {
  my $REPO_LIB = File::Spec->catdir($MOJO_MT_DIR, 'lib');
  my @runtimes = (
    {
      id   => 'stock_upstream',
      name => 'Stock Perl 5.44 + upstream',
      perl => $STOCK_PERL,
      inc  => [$UPSTREAM_LIB, $REPO_LIB],
    },
  );

  if (!$stock_only) {
    if (-x $MT_PERL) {
      push @runtimes, {
        id   => 'mt_upstream',
        name => 'perl5-mt-pgo + upstream',
        perl => $MT_PERL,
        inc  => [$MT_PERL_LIB, $UPSTREAM_LIB, $REPO_LIB],
      };

      my @mt_inc = ($MT_PERL_LIB);
      for my $xs_dir (qw(xs xs-keydb)) {
        my $xs_lib  = File::Spec->catdir($MOJO_MT_DIR, $xs_dir, 'blib', 'lib');
        my $xs_arch = File::Spec->catdir($MOJO_MT_DIR, $xs_dir, 'blib', 'arch');
        push @mt_inc, $xs_lib, $xs_arch if -d $xs_lib && -d $xs_arch;
      }
      push @mt_inc, $REPO_LIB;

      push @runtimes, {
        id   => 'mt_accel',
        name => 'perl5-mt-pgo + mojolicious-mt',
        perl => $MT_PERL,
        inc  => \@mt_inc,
      };
    }
  }

  my %data;
  my @order;
  for my $rt (@runtimes) {
    print STDERR "[microbench] Running $rt->{name}...\n" unless $emit_json;
    my $res = _run_runtime($rt);
    $data{$rt->{id}} = {meta => $rt, data => $res};
    @order = @{$res->{order}} unless @order;
  }

  if ($emit_json) {
    print encode_json({
      duration => $duration,
      passes   => $passes,
      runtimes => [map { $_->{id} } @runtimes],
      order    => \@order,
      data     => \%data,
    }), "\n";
    return;
  }

  # Emit Markdown table
  if (@runtimes == 1) {
    print "| Benchmark | Stock Perl 5.44 + upstream (ops/s) |\n";
    print "|---|---:|\n";
    for my $item (@order) {
      my $k = $item->{key};
      my $s = $data{stock_upstream}{data}{results}{$k}{ops_sec};
      print "| $item->{label} | " . _fmt_ops($s) . " |\n";
    }
  }
  else {
    my $accel_flag = $data{mt_accel}{data}{has_mt_accel} ? 'XS/NEON ON' : 'pure-Perl fallback';
    print "_`perl5-mt + mojolicious-mt` accelerator status: **${accel_flag}** (median of $passes x ${duration}s passes)_\n\n";
    print "| Benchmark | Stock 5.44 + upstream (ops/s) | perl5-mt + upstream (ops/s) | perl5-mt + mojolicious-mt (ops/s) | vs Stock 5.44 | vs perl5-mt upstream |\n";
    print "|---|---:|---:|---:|---:|---:|\n";
    for my $item (@order) {
      my $k  = $item->{key};
      my $s  = $data{stock_upstream}{data}{results}{$k}{ops_sec};
      my $mu = $data{mt_upstream}{data}{results}{$k}{ops_sec};
      my $ma = $data{mt_accel}{data}{results}{$k}{ops_sec};
      printf "| %s | %s | %s | %s | **%s** | **%s** |\n",
        $item->{label}, _fmt_ops($s), _fmt_ops($mu), _fmt_ops($ma),
        _fmt_mult($ma, $s), _fmt_mult($ma, $mu);
    }
  }
}
