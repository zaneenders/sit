# Handoff for the next agent — Sit / git compatibility

This document summarizes what exists in the repo today and what is a natural next step.

## Dependencies

- **swift-crypto** (`Crypto` product): used for **SHA-1** on canonical loose-object bytes (`GitSHA1`). Git object names are SHA-1 of `type SP size NUL` + body **before** zlib.

## Read path (already in place)

- **DEFLATE inflate** (`DeflateInflate`), **zlib** (`ZlibLooseObject`), **RFC 1950** header checks (`LZ77.Header`).
- **Pack index v2** (`PackIndexV2`), **pack decode** (`GitPack`): blobs, trees, commits, OFS/REF deltas; pack header `size` for deltas is **zlib plaintext length**, not final object size.
- **Binary delta apply** (`PackDelta`).
- **Loose blob parse** (`ParsedGitBlob`).

## Write path (new)

- **`GitInit`**: `discoverTemplateDirectory()` (env `GIT_TEMPLATE_DIR`, then `/usr/share/git-core/templates`, `/usr/local/share/git-core/templates`). `createEmptyRepository(workTree:initialBranch:templateDirectory:)` copies the **same template tree** `git init` uses, creates `objects/` + `refs/` skeleton, writes `HEAD` and `config` with bytes aligned to `git` 2.43 Linux `config`.
- **`GitLooseObjectWriter`**: `writeBlob`, `writeTree`, `writeCommit` → zlib loose objects under `.git/objects/`.
- **`GitRefs`**: `updateRef` writes `refs/...` as `40-hex + LF`.
- **`GitHex`**: lowercase hex for SHAs.

## Tests

- **`TempDirectory.withRemoval`**: temp dir + guaranteed cleanup (`Tests/SitTests/TempDirectory.swift`).
- **`GitWriterIntegrationTests`**: (1) `diff -qr` between `git init -b main` and `Sit` init using the same templates; (2) single-file loose commit then `git fsck --strict` + `git rev-parse HEAD`.
- Existing zlib / pack / dogfood tests still require **python3** and **git** where noted (`GitDogfoodHelpers.requirePython3ForDogfood()` fails the test if Python is missing).

## Known gaps / follow-ups

1. **Index (`.git/index`)** — not implemented. `git status` in a Sit-written repo will not match a normal `git commit` workflow until the index format is written (or you shell out to `git add`).
2. **Packfiles** — writer only does **loose** objects.
3. **SHA-256 / reftable / commit-graph** — not supported.
4. **`GitInit` portability** — template path is Unix-oriented; macOS may use a different `share/git-core` path (add if needed).
5. **Commit signing, merges, tags** — not implemented.
6. **Byte-identical commits vs `git commit`** — timestamps and `user.name` / `user.email` make that non-deterministic; current tests validate **`git fsck`** and **`rev-parse`**, not `diff` of commit objects to CLI `git commit`.

## Suggested next tasks

- Minimal **index writer** for a single staged file so `git status` / `git diff --cached` behave after a Sit “commit” flow.
- **Ref log** (`logs/refs/heads/main`) if you need `git reflog` compatibility.
- **Pack writer** (optional) for `git gc`-style layout.

## Files to read first

| Area | Files |
|------|--------|
| Init | `Sources/Sit/GitInit.swift`, `GitInitError.swift` |
| Objects + SHA-1 | `Sources/Sit/GitLooseObjectWriter.swift`, `GitSHA1.swift`, `GitHex.swift` |
| Refs | `Sources/Sit/GitRefs.swift` |
| Zlib/deflate | `Sources/Sit/ZlibLooseObject.swift`, `DeflateCompress.swift`, `DeflateInflate.swift` |
| Pack read | `Sources/Sit/GitPack.swift`, `PackIndex.swift`, `PackDelta.swift` |
| Integration tests | `Tests/SitTests/GitWriterIntegrationTests.swift`, `TempDirectory.swift` |
