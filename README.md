# Sit

A Swift package for `git`.

## CLI (`sit`)

Build the executable, then run from a Git work tree (after `git init` or any clone):

```bash
swift build
.build/debug/sit add <paths…>      # stage files or directories
.build/debug/sit commit -m "msg"   # commit the index (needs user identity)
```

Identity is resolved like Git: `GIT_AUTHOR_*` / `GIT_COMMITTER_*`, then `[user]` in `.git/config` (`git config user.name` / `user.email`).

This is **`sit`**, not the `git` binary. To use Git’s own parser for add/commit, keep using `git add` / `git commit`; `sit` writes a compatible index and objects so Git tools can read the result.
