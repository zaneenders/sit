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
```

Author/committer identity (in order): optional **`--author-name`** + **`--author-email`** on `sit commit`, then `GIT_AUTHOR_*` / `GIT_COMMITTER_*`, then Git’s usual config files merged like **`git`**: `$XDG_CONFIG_HOME/git/config` (or `~/.config/git/config`), **`~/.gitconfig`**, then **`.git/config`** in the repo (later keys override earlier ones). If nothing supplies both name and email, you’ll get a message explaining how to fix it.

Example without touching global Git config:

```bash
sit commit --author-name 'Your Name' --author-email 'you@example.com' -m 'msg'
```

The binary is named **`sit`**, not `git`. It writes objects and an index Git can read; use `git add` / `git commit` if you want Git’s own implementation.

## Tests

```bash
swift test
```

Some integration tests call **`git`** and **`python3`** on `PATH` and skip if they are missing.
