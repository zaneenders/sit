# Sit

Swift library and small CLI for working with **on-disk Git** repositories: loose objects, pack indexes, zlib, a compatible index (v2/v3), and basic init/refs/commit flows.

Requires **Swift 6.3** or newer (see `Package.swift`).

## Library (`Sit`)

Rough split:

- **Read:** pack index v2, pack objects (including deltas), zlib loose objects, DEFLATE inflate, binary deltas, loose blobs.
- **Write:** `git init`-style layout (templates + `HEAD`/`config`), zlib loose blobs/trees/commits, ref updates, index staging, commits from the index.
- **Crypto:** SHA-1 object ids via [swift-crypto](https://github.com/apple/swift-crypto).

Not a full Git replacement: no pack *writer*, no index v4, no SHA-256 repos, no signing/merges/tags, and the index path story is “regular files, Git-compatible v2/v3” rather than every `git status` edge case.

## CLI (`sit`)

Build from the package root, then run inside a normal clone or `git init` work tree:

```bash
swift build
.build/debug/sit add <paths…>      # files or directories (skips `.git`)
.build/debug/sit commit -m "msg"   # tree from index → commit → update HEAD
.build/debug/sit status            # simplified git status
.build/debug/sit push [args…]      # runs git push (same flags, e.g. -u origin main)
.build/debug/sit pull [args…]      # runs git pull
```

`push` and `pull` are thin wrappers around **`git`**: they run `git push` / `git pull` from the current directory (via `/usr/bin/env git`), inherit stdin/stdout/stderr, and pass through arguments so behavior matches stock Git. They still require a normal `.git` directory discoverable upward from the cwd, like the other `sit` commands. Use them in a **`git clone`** (or any work tree with remotes) when you want a single entry point; **`git`** must be on `PATH`.

Author/committer identity (in order): optional **`--author-name`** + **`--author-email`** on `sit commit`, then `GIT_AUTHOR_*` / `GIT_COMMITTER_*`, then Git’s usual config files merged like **`git`**: `$XDG_CONFIG_HOME/git/config` (or `~/.config/git/config`), **`~/.gitconfig`**, then **`.git/config`** in the repo (later keys override earlier ones). `HOME` and `XDG_CONFIG_HOME` follow the process environment (via `getenv`), consistent with shell `git`. If nothing supplies both name and email, you’ll get a message explaining how to fix it.

Example without touching global Git config:

```bash
sit commit --author-name 'Your Name' --author-email 'you@example.com' -m 'msg'
```

The binary is named **`sit`**, not `git`. It writes objects and an index Git can read; use `git add` / `git commit` if you want Git’s own implementation. Network sync stays in **`git`**: `sit push` / `sit pull` only forward to it.

## Tests

```bash
swift test
```

Some integration tests call **`git`** and **`python3`** on `PATH` and skip if they are missing.

### Code coverage

Run the suite with LLVM profiling enabled, then summarize with **`llvm-cov`** (ships with the Swift toolchain):

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

HTML (optional): `llvm-cov show "$BIN" -instr-profile="$PROF" -format=html -output-dir=coverage-html` then open **`coverage-html/index.html`** in a browser.
