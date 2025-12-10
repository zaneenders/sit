# Sit

A Swift implementation of Git core functionality.

#### Phase 1: Reading State

**Status (git status)**
- Read the index file
- Compare the index to the working directory (to find unstaged changes)
- Compare the index to the HEAD commit (to find staged changes)

**Log (git log)**
- Read the HEAD file to find the current commit SHA-1
- Read the corresponding commit object in objects/
- Recursively follow the parent SHA-1s to walk the history

#### Phase 2: Writing State

**Add (git add)**
- Take the content of a file from the working directory
- Use a plumbing command like `git hash-object -w` (or internal code) to create a new blob object in objects/
- Update the index file to record the new file's path, mode, and the new blob SHA-1

**Commit (git commit)**
- Read the index file
- Use a plumbing command like `git write-tree` (or internal code) to convert the staged files (from the index) into a tree object in objects/
- Create a new commit object in objects/, referencing:
  - The new tree SHA-1
  - The current HEAD SHA-1 as the parent
  - Author/committer data and the commit message
- Update the branch reference (e.g., refs/heads/main) and the HEAD file to point to the new commit SHA-1


