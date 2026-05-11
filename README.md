# Sit

> ⚠️ This is heavily written by Ai. Probably just use git instead.

Swift library and small CLI for working with on-disk Git repositories: loose objects, pack indexes, zlib, a compatible index (v2/v3), and basic init/refs/commit flows.

Requires **Swift 6.3** or newer.

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

