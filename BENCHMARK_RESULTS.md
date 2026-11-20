# mojolicious-mt Benchmark Results

Side-by-side reference measurements comparing unmodified upstream Mojolicious (`d23217479`) and `mojolicious-mt` (`9eb784cae`) on an Apple M2 Max (12 cores, macOS 27.2.1, arm64).

These numbers represent one reference point on Apple Silicon under macOS. We present them here in the hope that they are useful for understanding where multi-threaded Perl and optional XS/NEON helpers help, where cold-start or single-worker RSS overhead is higher, and how throughput and memory scale with worker count. If you have a quiet Linux, BSD, x86_64, or POWER machine, we warmly invite you to run the scripts and share your own findings.

## Test Environment & Methodology

- **CPU / OS**: Apple M2 Max (12 logical cores), macOS 27.2.1 (arm64)
- **Stock Perl**: `v5.44.0` (`STOCK_PERL`, Homebrew arm64) + `.upstream-base/lib` (unmodified upstream Mojolicious)
- **perl5-mt (PGO+native)**: `v5.40.2` (`../perl5-mt-pgo/perl`) + `mojolicious-mt` (`xs/blib` + `xs-keydb/blib` + `lib`)
- **RESP2 Server**: `KeyDB server v=6.3.4 sha=00000000:0 malloc=libc bits=64 build=489b08ad849a101e` (ephemeral local TCP instance, persistence disabled)
- **Load Generator**: `wrk -t4 -c64 -d4s --latency` (1s warmup, median of 3 measured runs, 0 non-2xx / 0 socket errors enforced)
- **RSS Measurement**: Total process-tree RSS (`ps -o pid=,ppid=,rss= -ax`) sampled during active load (median MiB); `RSS/worker = Total RSS / workers`
- **Reproduce**: `perl bench/run_side_by_side.pl` and `perl bench/microbench.pl`

### Notes & Caveats

- **Platform and socket model**: macOS uses a single shared listening file descriptor without Linux's `SO_REUSEPORT` or `io_uring`, and all traffic here runs over loopback (`127.0.0.1`) on the same 12-core machine as `wrk` and `keydb-server`. Results on Linux, BSD, x86_64, or POWER systems will differ, especially at higher worker counts.
- **Compiler flags**: The `perl5-mt` binary tested here is a PGO + `-march=native` build, while stock Perl is the standard Homebrew `v5.44.0` build. The middle column (`perl5-mt + upstream`) helps separate interpreter/build effects from `mojolicious-mt` server and XS changes.
- **Cold start & 1-worker RSS**: Single-process multi-threaded startup (`mt`) initializes its thread pool and shared runtime structures up front, so cold startup (~280 ms vs ~155–163 ms) and 1-worker RSS (~98 MiB vs ~43–62 MiB) are noticeably higher than `daemon` or `prefork -w 1`. The memory advantage of sharing one process appears at 4+ workers.

## 1. Isolated Microbenchmarks (ops/sec)

_`Mojo::MT::Accel`: **ON (Tier-1 XS/NEON)** | `Mojo::MT::KeyDB::XS`: **ON (Tier-1 XS/NEON)** (median of 3 x 1.5s passes)._

| Operation | Stock 5.44 + upstream | perl5-mt + upstream | perl5-mt + mojolicious-mt | vs Stock 5.44 | vs perl5-mt upstream |
|---|---:|---:|---:|---:|---:|
| HTTP/1.1 request + header parse | 19,843 | 21,540 | 33,484 | **1.69x** | **1.55x** |
| HTTP/1.1 response build (server_write) | 28,574 | 30,050 | 84,379 | **2.95x** | **2.81x** |
| Mojo::JSON encode (50 records) | 1,578 | 1,805 | 24,169 | **15.31x** | **13.39x** |
| Mojo::JSON decode (50 records) | 783 | 858 | 15,154 | **19.34x** | **17.66x** |
| Mojo::Util::xml_escape (~2 KiB) | 11,567 | 11,362 | 95,636 | **8.27x** | **8.42x** |
| Mojo::Util::url_escape (~280 B) | 54,736 | 62,106 | 2,159,916 | **39.46x** | **34.78x** |
| Mojo::Util::url_unescape (~390 B) | 63,671 | 71,071 | 3,233,678 | **50.79x** | **45.50x** |
| Mojo::Util::b64_encode (1 KiB) | 1,333,411 | 1,302,890 | 1,447,052 | **1.09x** | **1.11x** |
| Mojo::Util::b64_decode (1 KiB) | 738,295 | 735,452 | 790,094 | **1.07x** | **1.07x** |
| Mojo::MT::KeyDB RESP2 encode (SET EX) | 957,678 | 1,018,950 | 5,103,620 | **5.33x** | **5.01x** |
| Mojo::MT::KeyDB RESP2 decode (10-elem array) | 67,548 | 74,689 | 1,893,519 | **28.03x** | **25.35x** |

## 2. Single-Worker All-Endpoints Comparison

- **Cold startup to first 200 OK**: Stock 5.44 `daemon` = **155.4 ms** | `perl5-mt` upstream `daemon` = **161.8 ms** | `perl5-mt` `mt -w 1` = **280.1 ms**

| Endpoint | Stock 5.44 daemon (req/s) | perl5-mt upstream daemon (req/s) | perl5-mt `mt -w 1` (req/s) | Speedup vs Stock | `mt -w 1` MB/s | `mt -w 1` Avg / p50 / p99 | Stock RSS | `mt -w 1` RSS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| GET /plaintext | 4,150 | 4,243 | 6,123 | **1.48x** | 0.92 | 10.43 ms / 10.40 ms / 11.35 ms | 42.7 MiB | 98.2 MiB |
| GET /json (50 records) | 1,062 | 1,173 | 4,617 | **4.35x** | 39.98 | 13.83 ms / 13.77 ms / 14.83 ms | 44.2 MiB | 98.4 MiB |
| POST /json (50 records) | 890 | 961 | 4,508 | **5.07x** | 0.83 | 14.08 ms / 14.13 ms / 15.28 ms | 47.9 MiB | 98.4 MiB |
| GET /template (25 rows) | 2,050 | 2,306 | 4,429 | **2.16x** | 31.49 | 14.33 ms / 14.24 ms / 18.47 ms | 49.1 MiB | 98.7 MiB |
| GET /static/payload.txt | 3,594 | 3,746 | 6,796 | **1.89x** | 107.85 | 9.24 ms / 9.37 ms / 10.26 ms | 50.6 MiB | 98.7 MiB |
| GET /keydb/bench-key | 2,565 | 2,732 | 3,766 | **1.47x** | 0.80 | 16.85 ms / 16.62 ms / 20.54 ms | 50.6 MiB | 98.7 MiB |
| GET /cache/bench-key | 3,820 | 3,887 | 6,133 | **1.61x** | 1.25 | 10.30 ms / 10.38 ms / 11.20 ms | 50.6 MiB | 98.8 MiB |

## 3. 8-Worker All-Endpoints Comparison (`prefork -w 8` vs `mt -w 8`)

- **Cold startup to first 200 OK**: Stock 5.44 `prefork -w 8` = **162.6 ms** | `perl5-mt` `mt -w 8` = **280.2 ms**

| Endpoint | Stock 5.44 `prefork -w 8` (req/s) | perl5-mt `mt -w 8` (req/s) | Speedup | Stock / `mt` MB/s | Stock p50 / p99 | `mt -w 8` p50 / p99 | Stock RSS (total / per-w) | `mt -w 8` RSS (total / per-w) | RSS Savings |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| GET /plaintext | 29,683 | 39,206 | **1.32x** | 4.44 / 5.87 | 2.08 ms / 5.56 ms | 1.46 ms / 3.81 ms | 176.8 MiB (22.1 MiB) | 110.9 MiB (13.9 MiB) | **37.3%** |
| GET /json (50 records) | 8,713 | 30,093 | **3.45x** | 75.45 / 260.59 | 7.67 ms / 26.91 ms | 1.92 ms / 4.93 ms | 183.3 MiB (22.9 MiB) | 112.2 MiB (14.0 MiB) | **38.8%** |
| POST /json (50 records) | 7,773 | 29,290 | **3.77x** | 1.44 / 5.42 | 9.59 ms / 28.16 ms | 2.02 ms / 4.85 ms | 189.9 MiB (23.7 MiB) | 113.1 MiB (14.1 MiB) | **40.4%** |
| GET /template (25 rows) | 16,482 | 29,282 | **1.78x** | 117.17 / 208.16 | 3.62 ms / 12.17 ms | 1.98 ms / 4.89 ms | 213.0 MiB (26.6 MiB) | 115.7 MiB (14.5 MiB) | **45.7%** |
| GET /static/payload.txt | 24,803 | 43,828 | **1.77x** | 393.62 / 695.55 | 2.04 ms / 7.84 ms | 1.27 ms / 3.57 ms | 221.5 MiB (27.7 MiB) | 116.3 MiB (14.5 MiB) | **47.5%** |
| GET /keydb/bench-key | 15,273 | 22,878 | **1.50x** | 3.26 / 4.87 | 4.11 ms / 12.71 ms | 2.56 ms / 5.66 ms | 229.5 MiB (28.7 MiB) | 116.5 MiB (14.6 MiB) | **49.3%** |
| GET /cache/bench-key | 28,536 | 35,919 | **1.26x** | 5.82 / 7.30 | 2.28 ms / 5.71 ms | 1.62 ms / 4.63 ms | 229.6 MiB (28.7 MiB) | 116.5 MiB (14.6 MiB) | **49.3%** |

> **Shared State Architecture Note (8 workers)**: Over loopback KeyDB/RESP2 (`/keydb/bench-key`), `perl5-mt mt -w 8` (`Mojo::MT::KeyDB::XS` `MY_CXT` persistent sockets) measured **22,878 req/s** versus Stock 5.44 `prefork -w 8` at **15,273 req/s** (**1.50x**). For workloads that fit in single-node in-process shared state (`MT::SharedHash` on `/cache/bench-key`, **35,919 req/s**), avoiding the external network round-trip yielded **2.35x** the throughput of Stock `prefork` + KeyDB, at the tradeoff of being scoped to one server process rather than distributed across hosts.

## 4. Multi-Worker Scaling Sweep (`1, 2, 4, 8, 12` workers)

### GET /plaintext

| Workers | Stock `prefork` (req/s) | `perl5-mt mt` (req/s) | Speedup | Stock Avg / p50 / p99 | `mt` Avg / p50 / p99 | Stock RSS (Total / per-w) | `mt` RSS (Total / per-w) |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 4,082 | 6,028 | **1.48x** | 15.39 ms / 15.60 ms / 17.21 ms | 10.60 ms / 10.51 ms / 14.24 ms | 60.1 MiB (60.1 MiB) | 97.7 MiB (97.7 MiB) |
| 2 | 8,774 | 11,798 | **1.34x** | 7.20 ms / 7.19 ms / 8.57 ms | 5.54 ms / 5.37 ms / 8.97 ms | 77.3 MiB (38.7 MiB) | 100.2 MiB (50.1 MiB) |
| 4 | 17,379 | 22,591 | **1.30x** | 3.68 ms / 3.92 ms / 7.47 ms | 2.84 ms / 2.76 ms / 5.41 ms | 112.0 MiB (28.0 MiB) | 103.7 MiB (25.9 MiB) |
| 8 | 29,683 | 39,206 | **1.32x** | 2.19 ms / 2.08 ms / 5.56 ms | 1.62 ms / 1.46 ms / 3.81 ms | 176.8 MiB (22.1 MiB) | 110.9 MiB (13.9 MiB) |
| 12 | 34,326 | 45,125 | **1.31x** | 2.09 ms / 1.57 ms / 8.61 ms | 1.54 ms / 1.23 ms / 5.08 ms | 245.8 MiB (20.5 MiB) | 118.5 MiB (9.9 MiB) |

### GET /json (50 records)

| Workers | Stock `prefork` (req/s) | `perl5-mt mt` (req/s) | Speedup | Stock Avg / p50 / p99 | `mt` Avg / p50 / p99 | Stock RSS (Total / per-w) | `mt` RSS (Total / per-w) |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 1,060 | 4,512 | **4.26x** | 59.90 ms / 59.77 ms / 88.04 ms | 14.15 ms / 14.05 ms / 16.06 ms | 62.1 MiB (62.1 MiB) | 97.9 MiB (97.9 MiB) |
| 2 | 2,224 | 9,068 | **4.08x** | 28.62 ms / 28.55 ms / 48.50 ms | 7.23 ms / 6.99 ms / 12.92 ms | 80.3 MiB (40.1 MiB) | 100.5 MiB (50.2 MiB) |
| 4 | 4,528 | 17,545 | **3.88x** | 14.00 ms / 14.30 ms / 31.18 ms | 3.66 ms / 3.55 ms / 7.08 ms | 115.9 MiB (29.0 MiB) | 104.5 MiB (26.1 MiB) |
| 8 | 8,713 | 30,093 | **3.45x** | 8.87 ms / 7.67 ms / 26.91 ms | 2.14 ms / 1.92 ms / 4.93 ms | 183.3 MiB (22.9 MiB) | 112.2 MiB (14.0 MiB) |
| 12 | 9,693 | 34,852 | **3.60x** | 7.59 ms / 6.12 ms / 25.86 ms | 1.94 ms / 1.59 ms / 5.89 ms | 255.4 MiB (21.3 MiB) | 120.3 MiB (10.0 MiB) |

## Acknowledgments

Thank you to the Perl 5 Porters, Sebastian Riedel and the Mojolicious contributors, the KeyDB community, and Will Glozer (`wrk`). Community measurements from Linux, BSD, x86_64, and POWER systems are very welcome.
