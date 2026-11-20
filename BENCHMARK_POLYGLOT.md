# Polyglot HTTP Benchmark Comparison (`mojolicious-mt`, Stock Perl, Node.js, and Go)

An 8-worker cross-runtime HTTP benchmark comparison on an Apple M2 Max (12 cores, macOS 27.2.1, arm64, `mojolicious-mt` commit `ac601f45e`) against a live local KeyDB instance.

This report is intended as one calm, reproducible reference point rather than a universal ranking. Both Perl entries run the full Mojolicious web framework, while Node.js runs raw `node:http` (without a web framework) and Go runs stdlib `net/http`. If you have a quiet Linux, BSD, x86_64, or POWER system, we warmly invite you to run `perl bench/polyglot/run_polyglot.pl` and share your measurements.

## Summary of Observations

- **Raw HTTP & I/O throughput**: Node.js (`node:cluster` + raw `node:http`) and Go (`net/http`) deliver substantially higher raw throughput on most endpoints—for example, `144,754` and `140,250 req/s` on `GET /plaintext` versus `38,629 req/s` for `mojolicious-mt` and `29,591 req/s` for stock Perl 5.44 `prefork`.
- **Mojolicious speedup over stock Perl**: Within the Mojolicious framework, `mojolicious-mt` (`mt -w 8`) measured `1.30x` to `4.00x` higher throughput than stock Perl 5.44 `prefork -w 8` across the 7 endpoints (`POST /json`: `29,718` vs `7,425 req/s`, `4.00x`; `GET /json`: `29,841` vs `8,528 req/s`, `3.50x`; `GET /keydb/bench-key`: `22,513` vs `15,330 req/s`, `1.47x`), reaching `47%`–`65%` of Go's stdlib `encoding/json` throughput on the JSON endpoints.
- **HTML template rendering (`GET /template`)**: On the 25-row HTML-escaped table, `mojolicious-mt` measured `29,284 req/s` (`p99` `5.16 ms`) compared with Go's stdlib `html/template` at `24,987 req/s` (`p99` `22.37 ms`) and raw Node.js string escaping at `105,736 req/s` (`p99` `1.74 ms`).
- **Memory footprint & cold startup**: Go has the smallest memory footprint (`26.7 MiB` median total RSS, `3.3 MiB/worker`) and fastest cold startup (`28.1 ms`). Among the dynamic runtimes, `mojolicious-mt` used `116.1 MiB` median total RSS (`14.5 MiB/worker`, flat across all 7 workloads), compared with `221.6 MiB` (`27.7 MiB/worker`) for stock Perl `prefork` and `791.8 MiB` (`99.0 MiB/worker`) for 8-process Node.js `cluster`. Stock Perl `prefork` started faster than `mojolicious-mt` (`163.0 ms` vs `332.7 ms`), while Node.js `cluster` took `459.2 ms`.
- **In-process shared state**: Because `mojolicious-mt` (`MT::SharedHash`) and Go (`sync.Map`) run multiple workers in a single OS process, they share an in-process cache across all 8 workers (`shared: true`). Stock Perl `prefork` and Node.js `node:cluster` run 8 separate OS processes (`shared: false`).

## Test Environment & Methodology

- **Hardware / OS**: Apple M2 Max (12 logical cores), macOS 27.2.1 (arm64)
- **Concurrency budget**: **8 server workers** (leaving 4 cores for `wrk` load generation + `keydb-server`)
- **Stock Perl**: `v5.44.0` (`STOCK_PERL`, Homebrew arm64) + upstream Mojolicious (`prefork -w 8`)
- **`mojolicious-mt`**: `perl5-mt-pgo` (`v5.40.2`, PGO+native) + `mojolicious-mt` (`mt -w 8`, Tier-1 XS/NEON + `Mojo::MT::KeyDB`)
- **Node.js**: `v26.13.1` (`node:cluster` with 8 workers + raw `node:http`, zero external dependencies)
- **Go**: `go version go1.27.4 darwin/arm64` (`GOMAXPROCS=8`, stdlib `net/http` + `encoding/json` + `html/template`, zero external dependencies)
- **Live KeyDB**: `KeyDB server v=6.3.4 sha=00000000:0 malloc=libc bits=64 build=489b08ad849a101e` (ephemeral local TCP instance, `--server-threads 4 --save "" --appendonly no`)
- **Load Generator**: `wrk -t4 -c64 -d4s --latency` (1s warmup, median of 3 measured passes, 0 non-2xx and 0 socket errors enforced)
- **RSS Measurement**: Total process-tree RSS (`ps -o pid=,ppid=,rss= -ax`) sampled during active load (median MiB); `RSS/worker = Total RSS / 8`
- **Reproduce**: `perl bench/polyglot/run_polyglot.pl`

## 1. Throughput Comparison (8 Workers, req/s)

| Endpoint | Stock Perl (`prefork -w 8`) | **`mojolicious-mt` (`mt -w 8`)** | Node.js (`cluster` x8) | Go (`GOMAXPROCS=8`) | `mojo-mt` vs Stock | `mojo-mt` vs Node.js | `mojo-mt` vs Go |
|---|---:|---:|---:|---:|---:|---:|---:|
| GET /plaintext | 29,591 | **38,629** | 144,754 | 140,250 | **1.31x** | **0.27x** | **0.28x** |
| GET /json (50 records) | 8,528 | **29,841** | 133,714 | 63,709 | **3.50x** | **0.22x** | **0.47x** |
| POST /json (50 records) | 7,425 | **29,718** | 140,072 | 45,573 | **4.00x** | **0.21x** | **0.65x** |
| GET /template (25 rows) | 16,166 | **29,284** | 105,736 | 24,987 | **1.81x** | **0.28x** | **1.17x** |
| GET /static/payload.txt | 24,181 | **43,888** | 120,103 | 106,921 | **1.81x** | **0.37x** | **0.41x** |
| GET /keydb/bench-key | 15,330 | **22,513** | 55,822 | 45,915 | **1.47x** | **0.40x** | **0.49x** |
| GET /cache/bench-key | 28,171 | **36,570** | 144,392 | 138,817 | **1.30x** | **0.25x** | **0.26x** |

## 2. Latency (p50 / p99) & Bandwidth (MB/s)

| Endpoint | Stock Perl (p50 / p99, MB/s) | **`mojolicious-mt` (p50 / p99, MB/s)** | Node.js (p50 / p99, MB/s) | Go (p50 / p99, MB/s) |
|---|---:|---:|---:|---:|
| GET /plaintext | 1.66 ms / 8.51 ms (4.43 MB/s) | **1.49 ms / 3.84 ms (5.78 MB/s)** | 0.42 ms / 0.55 ms (24.43 MB/s) | 0.40 ms / 1.14 ms (17.25 MB/s) |
| GET /json (50 records) | 6.24 ms / 25.00 ms (73.85 MB/s) | **1.96 ms / 4.95 ms (258.41 MB/s)** | 0.34 ms / 2.11 ms (1157.12 MB/s) | 0.77 ms / 4.67 ms (548.58 MB/s) |
| POST /json (50 records) | 8.65 ms / 34.20 ms (1.37 MB/s) | **1.96 ms / 5.16 ms (5.50 MB/s)** | 0.36 ms / 1.25 ms (28.59 MB/s) | 0.78 ms / 10.18 ms (7.21 MB/s) |
| GET /template (25 rows) | 4.06 ms / 9.88 ms (114.92 MB/s) | **2.03 ms / 5.16 ms (208.17 MB/s)** | 0.51 ms / 1.74 ms (751.34 MB/s) | 1.45 ms / 22.37 ms (172.74 MB/s) |
| GET /static/payload.txt | 2.16 ms / 10.46 ms (383.76 MB/s) | **1.27 ms / 3.62 ms (696.51 MB/s)** | 0.49 ms / 0.71 ms (1904.64 MB/s) | 0.51 ms / 1.51 ms (1689.60 MB/s) |
| GET /keydb/bench-key | 4.58 ms / 9.99 ms (3.27 MB/s) | **2.56 ms / 5.73 ms (4.79 MB/s)** | 1.13 ms / 1.43 ms (12.99 MB/s) | 1.36 ms / 2.33 ms (8.63 MB/s) |
| GET /cache/bench-key | 2.22 ms / 5.38 ms (5.75 MB/s) | **1.60 ms / 4.24 ms (7.43 MB/s)** | 0.42 ms / 0.57 ms (32.22 MB/s) | 0.39 ms / 1.32 ms (24.49 MB/s) |

## 3. Memory Footprint (Active Load RSS) & Cold Startup

| Runtime | Process Model | Cold Startup (to 1st 200 OK) | Median Total RSS (across endpoints) | Peak Total RSS | RSS / Worker (median) | Shared In-Process Cache? |
|---|---|---:|---:|---:|---:|---|
| Stock Perl 5.44 (prefork) | Multi-process (`prefork`: 1 mgr + 8 workers) | 163.0 ms | 221.6 MiB | 237.1 MiB | 27.7 MiB | No (per-worker `%LOCAL_CACHE`) |
| perl5-mt-pgo (mojolicious-mt) | Single-process multi-thread (`mt`: 1 proc, 8 threads) | 332.7 ms | 116.1 MiB | 116.7 MiB | 14.5 MiB | Yes (`MT::SharedHash`) |
| Node.js (cluster + node:http) | Multi-process (`node:cluster`: 1 primary + 8 workers) | 459.2 ms | 791.8 MiB | 809.2 MiB | 99.0 MiB | No (per-worker `Map`) |
| Go (net/http) | Single-process goroutines (`GOMAXPROCS=8`) | 28.1 ms | 26.7 MiB | 27.1 MiB | 3.3 MiB | Yes (`sync.Map`) |

### Per-Endpoint Active RSS (Total MiB / per worker)

| Endpoint | Stock Perl | `mojolicious-mt` | Node.js | Go |
|---|---:|---:|---:|---:|
| GET /plaintext | 185.9 MiB (23.2/w) | 111.9 MiB (14.0/w) | 646.9 MiB (80.9/w) | 22.8 MiB (2.9/w) |
| GET /json (50 records) | 191.5 MiB (23.9/w) | 112.7 MiB (14.1/w) | 717.0 MiB (89.6/w) | 23.6 MiB (2.9/w) |
| POST /json (50 records) | 203.7 MiB (25.5/w) | 113.3 MiB (14.2/w) | 734.6 MiB (91.8/w) | 25.1 MiB (3.1/w) |
| GET /template (25 rows) | 221.6 MiB (27.7/w) | 116.1 MiB (14.5/w) | 791.8 MiB (99.0/w) | 26.7 MiB (3.3/w) |
| GET /static/payload.txt | 230.9 MiB (28.9/w) | 116.6 MiB (14.6/w) | 800.3 MiB (100.0/w) | 27.0 MiB (3.4/w) |
| GET /keydb/bench-key | 237.0 MiB (29.6/w) | 116.7 MiB (14.6/w) | 806.6 MiB (100.8/w) | 27.1 MiB (3.4/w) |
| GET /cache/bench-key | 237.1 MiB (29.6/w) | 116.7 MiB (14.6/w) | 809.2 MiB (101.1/w) | 27.1 MiB (3.4/w) |

## 4. Endpoint Parity Verification

Before benchmarking each runtime, `run_polyglot.pl` asserts HTTP 200, JSON schema/checksums (`checksum == 211875`), 25 HTML-escaped table rows (`&lt;script&gt;`), exact 16,384-byte static payload, live KeyDB `INCR` monotonicity, and `/cache/:key` shared-state flags.

| Endpoint | Stock Perl (bytes) | `mojolicious-mt` (bytes) | Node.js (bytes) | Go (bytes) |
|---|---:|---:|---:|---:|
| GET /plaintext | 13 | 13 | 13 | 13 |
| GET /json (50 records) | 8905 | 8905 | 8905 | 8905 |
| POST /json (50 records) | 44 | 44 | 44 | 44 |
| GET /template (25 rows) | 7286 | 7286 | 7286 | 7132 |
| GET /static/payload.txt | 16384 | 16384 | 16384 | 16384 |
| GET /keydb/bench-key | 69 | 73 | 74 | 75 |
| GET /cache/bench-key | 64 | 63 | 64 | 63 |

_Notes on minor byte-count differences: Go's `html/template` escapes `"` as `&#34;` (5 bytes) instead of `&quot;` (6 bytes), accounting for `7,132` vs `7,286` bytes on `/template`. On `/keydb/bench-key`, the shared KeyDB `INCR` counter grows in digit width across sequential runtime runs (`69` → `75` bytes), and `"shared":true` vs `"shared":false` accounts for `63` vs `64` bytes on `/cache/bench-key`._

## 5. Methodology Notes & Caveats

- **Full web framework vs raw stdlib HTTP**: Both Perl entries run the full **Mojolicious** web framework (router, controller/stash lifecycle, renderer, static dispatcher, plugins/hooks). Node.js runs raw `node:http` with direct pathname dispatch (no Express/Fastify middleware stack), and Go runs stdlib `net/http` `ServeMux` with `encoding/json` and `html/template`.
- **Operating system and socket behavior**: These measurements were taken on macOS (arm64) over loopback, where workers share a single listening socket without Linux's `SO_REUSEPORT` or `io_uring`. Behavior on Linux, BSD, x86_64, or POWER systems may differ significantly—especially for multi-process and multi-threaded accept scaling.
- **No pre-serialized JSON or HTML shortcuts**: Every runtime dynamically encodes the 50-record JSON object on every `GET /json`, decodes + sums + encodes on every `POST /json`, and dynamically escapes and renders all 25 HTML rows on every `GET /template`.
- **Static asset caching parity**: All 4 runtimes `stat` `bench/public/static/payload.txt` on every request and serve cached in-memory bytes when `mtime` and `size` match (mirroring `Mojolicious::Static`).
- **Live KeyDB RESP2 parity**: Every runtime uses persistent TCP sockets (`TCP_NODELAY`) to the same ephemeral KeyDB 6.3.4 instance (`--server-threads 4`) and executes two sequential RESP2 commands per request (`INCR bench:cnt:<key>` then `GET bench:val:<key>`). `mojolicious-mt` uses its Tier-1 XS/NEON `Mojo::MT::KeyDB::XS` client; Stock Perl uses the pure-Perl `Mojo::MT::KeyDB` fallback; Node.js uses a persistent queued RESP2 `net.Socket` per worker; Go uses a persistent pooled `net.Conn` RESP2 client.
- **In-process shared cache (`/cache/:key`)**: `mojolicious-mt` (`MT::SharedHash`) and Go (`sync.Map`) share a single in-process cache across all 8 workers (`shared: true`). Stock Perl `prefork` and Node.js `node:cluster` run 8 isolated OS worker processes that cannot share in-process memory, so they serve from per-worker maps (`shared: false`) — their `/cache/:key` throughput reflects local-only reads without cross-worker coherence.

## Acknowledgments

Thank you to the Perl 5 Porters, Sebastian Riedel and the Mojolicious contributors, the Node.js and Go teams, the KeyDB community, and Will Glozer (`wrk`). If you run this suite on Linux, BSD, x86_64, or POWER hardware, we would be grateful to see your results.
