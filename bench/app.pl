#!/usr/bin/env perl
package BenchApp;
use Mojo::Base 'Mojolicious', -signatures;

use Mojo::File qw(curfile);

our $BENCH_DIR;
our $JSON_PAYLOAD;
our $TEMPLATE_ROWS;
our $SHARED_CACHE_ID;
our $SHARED_CACHE;
our %LOCAL_CACHE;
our $HAS_SHARED_CACHE;
our $KEYDB_CLIENT;

BEGIN {
  $BENCH_DIR = curfile->dirname->to_string;
  if (eval { require Mojo::MT; require Mojo::MT::SharedCache; 1 } && Mojo::MT::HAS_MT_SHARED_HASH()) {
    $HAS_SHARED_CACHE = 1;
    $SHARED_CACHE_ID //= Mojo::MT::SharedCache->new->id;
  }
  else {
    $HAS_SHARED_CACHE = 0;
  }
  if ($ENV{MOJO_KEYDB_PORT} && eval { require Mojo::MT::KeyDB; 1 }) {
    $KEYDB_CLIENT = Mojo::MT::KeyDB->new(host => '127.0.0.1', port => int($ENV{MOJO_KEYDB_PORT}));
  }
}

sub _build_json_payload {
  my @items;
  for my $i (1 .. 50) {
    push @items, {
      id     => $i,
      name   => "Benchmark User $i",
      email  => "user$i\@example.com",
      role   => ($i % 5 == 0 ? 'admin' : 'member'),
      active => ($i % 3 != 0 ? \1 : \0),
      score  => 10.5 + ($i * 1.25),
      tags   => ['perf', 'mojo', 'tier-' . ($i % 4)],
      meta   => {region => ($i % 2 ? 'us-east' : 'eu-west'), rev => $i},
    };
  }
  return {status => 'ok', count => scalar(@items), items => \@items};
}

sub _build_template_rows {
  my @rows;
  for my $i (1 .. 25) {
    push @rows, {
      id    => $i,
      title => qq{Item #$i <script>alert("xss&$i")</script> & 'quotes'},
      owner => qq{User <u$i\@example.com> & "Team $i"},
      note  => qq{Value > 0 && Value < 100 ("ok" / 'checked')},
      score => sprintf('%.2f', 50 + $i * 1.75),
    };
  }
  return \@rows;
}

sub _ensure_static_asset ($dir) {
  my $pub   = Mojo::File->new($dir)->child('public');
  my $asset = $pub->child('static', 'payload.txt');
  if (!-f $asset || (-s $asset // 0) != 16384) {
    $asset->dirname->make_path;
    my $line = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde\n"; # 64 bytes
    $asset->spew($line x 256);                                                     # 16,384 bytes
  }
  return $pub->to_string;
}

sub startup ($self) {
  $self->log->level($ENV{MOJO_LOG_LEVEL} // 'error');
  $self->secrets(['mojolicious-mt-bench-secret']);

  my $pub_dir = _ensure_static_asset($BENCH_DIR);
  unshift @{$self->static->paths}, $pub_dir unless grep { $_ eq $pub_dir } @{$self->static->paths};
  push @{$self->renderer->classes}, __PACKAGE__ unless grep { $_ eq __PACKAGE__ } @{$self->renderer->classes};

  my $r = $self->routes;

  # 1. Plaintext
  $r->get('/plaintext' => sub ($c) {
    $c->render(text => 'Hello, World!', format => 'txt');
  });

  # 2. JSON encode (50-record payload)
  $r->get('/json' => sub ($c) {
    $JSON_PAYLOAD //= _build_json_payload();
    $c->render(json => $JSON_PAYLOAD);
  });

  # 3. JSON decode + compute + encode
  $r->post('/json' => sub ($c) {
    my $data = $c->req->json;
    return $c->render(status => 400, json => {error => 'invalid json'}) unless ref $data eq 'HASH';
    my $items = $data->{items};
    my $count = ref $items eq 'ARRAY' ? scalar(@$items) : 0;
    my $sum   = 0;
    if ($count) {
      $sum += ($_->{score} // 0) for @$items;
    }
    $c->render(json => {status => 'ok', count => $count, checksum => int($sum * 100 + 0.5)});
  });

  # 4. Dynamic EP template (25-row HTML table exercising xml_escape)
  $r->get('/template' => sub ($c) {
    $TEMPLATE_ROWS //= _build_template_rows();
    $c->render(template => 'table', rows => $TEMPLATE_ROWS, title => 'Benchmark <Report> & "Stats"');
  });

  # 5. Static asset: GET /static/payload.txt (served from bench/public/static/payload.txt)

  # 6. Shared cache (MT::SharedHash via Mojo::MT::SharedCache when available, else per-worker hash)
  $r->get('/cache/:key' => sub ($c) {
    my $key = $c->param('key');
    my ($val, $shared);
    if ($HAS_SHARED_CACHE && defined $SHARED_CACHE_ID) {
      $SHARED_CACHE //= Mojo::MT::SharedCache->attach($SHARED_CACHE_ID);
      $val    = $SHARED_CACHE->get_or_set($key, sub { "cached:$key:v1" });
      $shared = \1;
    }
    else {
      $val    = ($LOCAL_CACHE{$key} //= "cached:$key:v1");
      $shared = \0;
    }
    $c->render(json => {key => $key, value => $val, shared => $shared});
  });

  # 7. KeyDB / RESP2 shared state (Tier-1 XS/NEON MY_CXT persistent sockets on perl5-mt, pure-Perl fallback on Stock Perl)
  $r->get('/keydb/:key' => sub ($c) {
    return $c->render(status => 503, json => {error => 'MOJO_KEYDB_PORT not configured'})
      unless defined $KEYDB_CLIENT;
    my $key   = $c->param('key');
    my $count = $KEYDB_CLIENT->incr("bench:cnt:$key");
    my $val   = $KEYDB_CLIENT->get("bench:val:$key");
    if (!defined $val) {
      $val = "keydb:$key:v1";
      $KEYDB_CLIENT->set("bench:val:$key", $val);
    }
    $c->render(json => {
      key   => $key,
      value => $val,
      count => $count,
      xs    => ($KEYDB_CLIENT->_xs_enabled ? \1 : \0),
    });
  });
}

unless (caller) {
  require Mojolicious::Commands;
  Mojolicious::Commands->start_app('BenchApp');
}

1;
__DATA__

@@ table.html.ep
<!DOCTYPE html>
<html>
<head><title><%= $title %></title></head>
<body>
<h1><%= $title %></h1>
<table>
<thead><tr><th>ID</th><th>Title</th><th>Owner</th><th>Note</th><th>Score</th></tr></thead>
<tbody>
% for my $row (@$rows) {
<tr><td><%= $row->{id} %></td><td><%= $row->{title} %></td><td><%= $row->{owner} %></td><td><%= $row->{note} %></td><td><%= $row->{score} %></td></tr>
% }
</tbody>
</table>
</body>
</html>
