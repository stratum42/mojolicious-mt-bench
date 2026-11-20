# mojolicious-mt-bench

Reproducible benchmark harnesses and reference measurements for [`mojolicious-mt`](../mojolicious-mt) running on [`perl5-mt`](../perl5-mt).

This repository exists to measure what actually changes—and what does not—when running a Mojolicious application on a multi-threaded Perl 5 build with optional XS acceleration, compared against stock Perl 5 with unmodified upstream Mojolicious and against minimal Node.js and Go HTTP servers.

## Acknowledgments

This work builds directly on the shoulders of others:

- **Perl 5** and the Perl 5 Porters, for decades of careful stewardship of the language and runtime.
- **Mojolicious** (Sebastian Riedel and the Mojolicious contributors), for designing a remarkably clean, self-contained, and pleasant web framework.
- **KeyDB** (and the Redis / RESP2 ecosystem), **Node.js**, **Go**, and **`wrk`** (Will Glozer), which make honest cross-runtime and real-I/O comparisons possible.

## What Is Included

1. **Mojolicious side-by-side suite** (`bench/run_side_by_side.pl` and `bench/microbench.pl`): compares stock Perl + upstream Mojolicious (`daemon` and `prefork`), `perl5-mt` + upstream Mojolicious, and `perl5-mt` + `mojolicious-mt` (`mt` server, optional XS/SIMD helpers, and `Mojo::MT::KeyDB`).
2. **Polyglot HTTP comparison** (`bench/polyglot/run_polyglot.pl`): an 8-worker comparison across stock Perl (`prefork`), `mojolicious-mt` (`mt`), Node.js (`node:cluster` + raw `node:http`), and Go (stdlib `net/http`), with automated endpoint parity verification against a live local KeyDB/RESP2 instance.

## Reference Reports

- [BENCHMARK_RESULTS.md](BENCHMARK_RESULTS.md) — Isolated microbenchmarks, 1-worker and 8-worker endpoint comparisons, and a 1–12 worker scaling sweep on Apple Silicon (macOS arm64).
- [BENCHMARK_POLYGLOT.md](BENCHMARK_POLYGLOT.md) — 8-worker cross-runtime HTTP comparison (stock Perl, `mojolicious-mt`, Node.js, and Go) on Apple Silicon (macOS arm64).

The published numbers are a single reference point collected on an Apple M2 Max running macOS (arm64). Different operating systems, kernel socket models (such as macOS single-fd accept behavior versus Linux `SO_REUSEPORT` or `io_uring`), and CPU architectures will behave differently. If you have access to a quiet Linux, BSD, x86_64, or POWER system and would like to run these scripts, we would genuinely welcome your measurements and observations.

## Prerequisites

- Sibling checkouts of `mojolicious-mt` (with `xs/` and `xs-keydb/` built if testing XS acceleration) and `perl5-mt` (or `perl5-mt-pgo`), or explicit paths via the environment variables below.
- `wrk` HTTP load generator.
- `keydb-server` (or `redis-server`) for the `/keydb/:key` endpoint.
- Optional, for the polyglot suite: `node` (Node.js) and `go` (Go toolchain).

## Quick Start

Run from the root of `mojolicious-mt-bench`:

```sh
# 1. Side-by-side Mojolicious benchmark suite (writes BENCHMARK_RESULTS.md)
perl bench/run_side_by_side.pl

# Quick smoke check (stock Perl + upstream Mojolicious baseline)
perl bench/run_side_by_side.pl --smoke

# Isolated Perl / XS microbenchmarks only
perl bench/microbench.pl

# 2. Polyglot HTTP comparison (writes BENCHMARK_POLYGLOT.md)
perl bench/polyglot/run_polyglot.pl

# Quick polyglot smoke run + endpoint parity verification
perl bench/polyglot/run_polyglot.pl --smoke
```

## Environment Variables

The harnesses default to sibling checkouts (`../mojolicious-mt`, `../perl5-mt-pgo` or `../perl5-mt`) and accept overrides for any local layout:

| Variable | Default | Description |
|---|---|---|
| `MOJO_MT_DIR` | `../mojolicious-mt` | Path to the `mojolicious-mt` repository (with `xs/blib` and `xs-keydb/blib` built for XS acceleration). |
| `MOJO_UPSTREAM_DIR` | `$MOJO_MT_DIR/.upstream-base` | Path to an unmodified upstream Mojolicious checkout used for baseline runs. |
| `PERL5_MT_DIR` | `../perl5-mt-pgo` (if present), else `../perl5-mt` | Path to the built `perl5-mt` directory containing `perl` and `lib/`. |
| `PERL5_MT` / `PERL5_MT_LIB` | `$PERL5_MT_DIR/perl` / `$PERL5_MT_DIR/lib` | Explicit overrides for the `perl5-mt` binary and library directory. |
| `STOCK_PERL` | `/opt/homebrew/bin/perl` (if executable), else `perl` in `PATH` | Stock Perl interpreter used for baseline runs. |
| `WRK_BIN` | `wrk` in `PATH` (or `/opt/homebrew/bin/wrk`) | Path to the `wrk` binary. |
| `NODE_BIN` / `GO_BIN` | `node` / `go` in `PATH` | Node.js and Go binaries for `bench/polyglot/run_polyglot.pl`. |

## Suite Layout

- `bench/app.pl` — Mojolicious benchmark application implementing all 7 endpoints (`/plaintext`, `GET /json`, `POST /json`, `/template`, `/static/payload.txt`, `/cache/:key`, `/keydb/:key`).
- `bench/post_json.lua` — `wrk` Lua script for `POST /json` (50-record payload).
- `bench/microbench.pl` — Isolated ops/sec microbenchmarks (HTTP parse/build, JSON encode/decode, HTML/URL/Base64 utilities, RESP2 encode/decode).
- `bench/run_side_by_side.pl` — Side-by-side Mojolicious runner and `BENCHMARK_RESULTS.md` generator.
- `bench/polyglot/server.mjs` — Zero-dependency Node.js (`node:cluster` + `node:http`) parity server.
- `bench/polyglot/server.go` — Zero-dependency Go (`net/http`) parity server.
- `bench/polyglot/run_polyglot.pl` — Polyglot parity verifier, runner, and `BENCHMARK_POLYGLOT.md` generator.
