# Performance

Sit uses [swift-collections-benchmark][scb] for micro-benchmarks. A committed
baseline lets any branch diff its performance against `main` in one command.

The `BenchRunner` executable orchestrates everything: running benchmarks,
comparing against the baseline, and detecting regressions — no shell scripting
involved.

[scb]: https://github.com/apple/swift-collections-benchmark

---

## Quick start — check for regressions

```bash
swift run -c release BenchRunner
```

This builds and runs all benchmarks, then compares the results against the
committed baseline at `Benchmarks/Baselines/main.json`.  If any task regressed
more than 10% it exits with a non-zero status and prints the culprit.

## Updating the baseline

After a deliberate change that shifts performance (or after adding new
benchmarks), update the baseline on `main`:

```bash
swift run -c release BenchRunner save
git add Benchmarks/Baselines/main.json
git commit -m "Update benchmark baseline"
```

## Listing available tasks

```bash
swift run -c release BenchRunner list
```

## Running a single task

```bash
swift run -c release SitBenchmarks run /tmp/one.json \
  --mode replace-all --cycles 10 \
  --tasks "SHA1.hash 1 KB blob" \
  --sizes 1 --sizes 2000 --sizes 10000
```

## Understanding the comparison output

```
  Task                                               Geomean  Per-size ratios
  ────────────────────────────────────────────────   ───────  ──────────────
  SHA1.hash 1 KB blob                            ✓   0.982   1:0.960 2000:0.930 10000:0.931
  Index.parse 100 entries                        ✗   1.131   1:1.352 2000:1.078 10000:1.242
```

| Column | Meaning |
|---|---|
| **Task** | Benchmark name with ✓ (ok) or ✗ (regressed) |
| **Geomean** | Geometric mean of new/baseline ratios across all sizes (1.0 = identical) |
| **Per-size ratios** | Individual `size:ratio` ratios for diagnosing which sizes shifted |

A task is flagged (✗) when the **geometric mean** across all sizes exceeds 1.10
(>10% slower than baseline overall).

---

## Code coverage

Run the test suite with LLVM profiling enabled, then summarize with
**`llvm-cov`** (ships with the Swift toolchain):

```bash
swift test --enable-code-coverage

# Linux example — adjust the `.build/<triple>/debug` prefix for your host.
PROF=.build/x86_64-unknown-linux-gnu/debug/codecov/default.profdata
BIN=.build/x86_64-unknown-linux-gnu/debug/sitPackageTests.xctest

llvm-cov report "$BIN" -instr-profile="$PROF"

# Library-only-ish view (drop tests, CLI, and generated harness noise):
llvm-cov report "$BIN" -instr-profile="$PROF" \
  --ignore-filename-regex='Tests/' \
  --ignore-filename-regex='sit-cli' \
  --ignore-filename-regex='derived'
```

HTML (optional):
```bash
llvm-cov show "$BIN" -instr-profile="$PROF" -format=html -output-dir=coverage-html
```

Then open **`coverage-html/index.html`** in a browser.

---

## Benchmarks reference

| Benchmark | What it measures |
|---|---|
| `SHA1.hash 1 KB blob` | SHA-1 over a 1 KiB payload |
| `SHA1.hash 64 KB blob` | SHA-1 over a 64 KiB payload |
| `SHA1.hash 1 MB blob` | SHA-1 over a 1 MiB payload |
| `Index.parse 100 entries` | Parse a serialized v2 index with 100 entries + checksum verify |
| `Index.serialize 100 entries` | Serialize 100 entries to v2 index bytes |
| `Deflate.inflate 1 KB stored` | Inflate a 1 KiB stored-block DEFLATE stream |
| `Deflate.inflate 64 KB stored` | Inflate a 64 KiB stored-block DEFLATE stream |
| `Deflate.compress 1 KB stored` | Compress 1 KiB to stored-block DEFLATE |
| `Deflate.compress 64 KB stored` | Compress 64 KiB to stored-block DEFLATE |
| `Zlib roundtrip 1 KB` | Full zlib compress + decompress cycle, 1 KiB |
| `Zlib roundtrip 64 KB` | Full zlib compress + decompress cycle, 64 KiB |
| `GitIgnore.match 100 patterns 50 paths` | Evaluate 50 paths against 100 ignore patterns |
| `PackDelta.apply 1 KB base + delta` | Binary delta apply to a 1 KiB base |
| `PackDelta.apply 64 KB base + delta` | Binary delta apply to a 64 KiB base |
| `LooseObject.write blob 1 KB` | Write a 1 KiB blob as a zlib-compressed loose object |
| `LooseObject.write blob 64 KB` | Write a 64 KiB blob as a zlib-compressed loose object |
| `Hex.encode 20 bytes` | Lowercase hex encode a 20-byte SHA |
| `Hex.decode 40 hex → 20 bytes` | Decode a 40-char hex string to 20 bytes |
| `Tree.build flat 200 entries` | Build a tree object from 200 flat index entries |
| `Tree.build nested 200 entries (10 dirs)` | Build a tree from 200 entries in 10 subdirectories |
| `Repository.discover 5 levels up` | Walk 5 directories up to find `.git` |
