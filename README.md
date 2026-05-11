# Sit

⚠️ This is heavily written by Ai. Probably just use git instead.

Swift library and small CLI for working with on-disk Git repositories: loose objects, pack indexes, zlib, a compatible index (v2/v3), and basic init/refs/commit flows.

Requires **Swift 6.3** or newer.

## Library (`Sit`)

Read pack index v2, pack objects (including deltas), zlib loose objects, DEFLATE inflate, binary deltas, loose blobs. Writes: `git init`-style layout, zlib loose blobs/trees/commits, ref updates, index staging, commits from the index. Ignore rules support `.git/info/exclude` and `.gitignore` files. SHA-1 object ids via [swift-crypto](https://github.com/apple/swift-crypto).

## Tests

```bash
swift test
```

### Code coverage

**macOS**
```bash
swift test --enable-code-coverage
PROFDATA=$(find .build -name '*.profdata' -print -quit)
BIN=$(find .build -name 'sitPackageTests' -type f -not -path '*.dSYM*' -print -quit)
xcrun llvm-cov report "$BIN" \
  --instr-profile="$PROFDATA" \
  --ignore-filename-regex='(\.build/|Tests/)'
```

**Linux**
```bash
swift test --enable-code-coverage
PROFDATA=$(find .build -name '*.profdata' -print -quit)
BIN=$(find .build -name 'sitPackageTests.xctest' -type f -print -quit)
llvm-cov report "$BIN" \
  --instr-profile="$PROFDATA" \
  --ignore-filename-regex='(\.build/|Tests/)'
```

