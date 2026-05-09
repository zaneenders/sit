import Foundation
import Testing

@testable import Sit

@Suite(.timeLimit(.minutes(1)))
struct GitWorkdirStatusTextTests: ~Copyable {
  @Test func hasUnstagedWorktreeChangesFalseWhenCleanAfterCommit() throws {
    let templates = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("w", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)
      try Self.appendUserConfig(gitDir: gitDir)
      let file = work.appendingPathComponent("note.txt")
      try Data("v1\n".utf8).write(to: file)
      var index = GitIndex()
      try index.stage(gitDir: gitDir, workTree: work, files: [file])
      try index.write(to: gitDir.appendingPathComponent("index"))
      let author = GitLocalConfig.UserIdentity(name: "sit", email: "sit@test")
      _ = try GitStaging.commit(
        gitDir: gitDir,
        workTree: work,
        message: "first",
        author: author,
        committer: author
      )
      let dirty = try GitWorkdirStatusText.hasUnstagedWorktreeChanges(gitDir: gitDir, workTree: work)
      #expect(!dirty)
      let text = try GitWorkdirStatusText.format(gitDir: gitDir, workTree: work)
      #expect(text.contains("working tree clean"))
    }
  }

  @Test func hasUnstagedWorktreeChangesTrueWhenUntrackedDotfile() throws {
    let templates = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("w", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)
      try Self.appendUserConfig(gitDir: gitDir)
      let tracked = work.appendingPathComponent("tracked.txt")
      try Data("x\n".utf8).write(to: tracked)
      var index = GitIndex()
      try index.stage(gitDir: gitDir, workTree: work, files: [tracked])
      try index.write(to: gitDir.appendingPathComponent("index"))
      let author = GitLocalConfig.UserIdentity(name: "sit", email: "sit@test")
      _ = try GitStaging.commit(
        gitDir: gitDir,
        workTree: work,
        message: "first",
        author: author,
        committer: author
      )
      try Data("#\n".utf8).write(to: work.appendingPathComponent(".gitignore"))
      let dirty = try GitWorkdirStatusText.hasUnstagedWorktreeChanges(gitDir: gitDir, workTree: work)
      #expect(dirty)
      let text = try GitWorkdirStatusText.format(gitDir: gitDir, workTree: work)
      #expect(text.contains(".gitignore"))
    }
  }

  @Test func hasUnstagedWorktreeChangesTrueWhenUntrackedFile() throws {
    let templates = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("w", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)
      try Self.appendUserConfig(gitDir: gitDir)
      let tracked = work.appendingPathComponent("tracked.txt")
      try Data("x\n".utf8).write(to: tracked)
      var index = GitIndex()
      try index.stage(gitDir: gitDir, workTree: work, files: [tracked])
      try index.write(to: gitDir.appendingPathComponent("index"))
      let author = GitLocalConfig.UserIdentity(name: "sit", email: "sit@test")
      _ = try GitStaging.commit(
        gitDir: gitDir,
        workTree: work,
        message: "first",
        author: author,
        committer: author
      )
      try Data("orphan\n".utf8).write(to: work.appendingPathComponent("untracked.txt"))
      let dirty = try GitWorkdirStatusText.hasUnstagedWorktreeChanges(gitDir: gitDir, workTree: work)
      #expect(dirty)
      let text = try GitWorkdirStatusText.format(gitDir: gitDir, workTree: work)
      #expect(text.contains("Untracked files:"))
    }
  }

  @Test func hasUnstagedWorktreeChangesFalseWhenStagedOnlyNewFile() throws {
    let templates = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("w", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)
      try Self.appendUserConfig(gitDir: gitDir)
      let file = work.appendingPathComponent("new.txt")
      try Data("staged only\n".utf8).write(to: file)
      var index = GitIndex()
      try index.stage(gitDir: gitDir, workTree: work, files: [file])
      try index.write(to: gitDir.appendingPathComponent("index"))
      let dirty = try GitWorkdirStatusText.hasUnstagedWorktreeChanges(gitDir: gitDir, workTree: work)
      #expect(!dirty)
      let text = try GitWorkdirStatusText.format(gitDir: gitDir, workTree: work)
      #expect(text.contains("Changes to be committed:"))
      #expect(!text.contains("Changes not staged for commit:"))
    }
  }

  @Test func hasUnstagedWorktreeChangesTrueWhenDiskDiffersFromIndex() throws {
    let templates = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("w", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)
      try Self.appendUserConfig(gitDir: gitDir)
      let file = work.appendingPathComponent("mut.txt")
      try Data("original\n".utf8).write(to: file)
      var index = GitIndex()
      try index.stage(gitDir: gitDir, workTree: work, files: [file])
      try index.write(to: gitDir.appendingPathComponent("index"))
      let author = GitLocalConfig.UserIdentity(name: "sit", email: "sit@test")
      _ = try GitStaging.commit(
        gitDir: gitDir,
        workTree: work,
        message: "first",
        author: author,
        committer: author
      )
      try Data("modified on disk\n".utf8).write(to: file)
      let dirty = try GitWorkdirStatusText.hasUnstagedWorktreeChanges(gitDir: gitDir, workTree: work)
      #expect(dirty)
      let text = try GitWorkdirStatusText.format(gitDir: gitDir, workTree: work)
      #expect(text.contains("Changes not staged for commit:"))
    }
  }

  @Test func hasUnstagedWorktreeChangesTrueWhenTrackedFileDeletedOnDisk() throws {
    let templates = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("w", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)
      try Self.appendUserConfig(gitDir: gitDir)
      let file = work.appendingPathComponent("gone.txt")
      try Data("bye\n".utf8).write(to: file)
      var index = GitIndex()
      try index.stage(gitDir: gitDir, workTree: work, files: [file])
      try index.write(to: gitDir.appendingPathComponent("index"))
      let author = GitLocalConfig.UserIdentity(name: "sit", email: "sit@test")
      _ = try GitStaging.commit(
        gitDir: gitDir,
        workTree: work,
        message: "first",
        author: author,
        committer: author
      )
      try FileManager.default.removeItem(at: file)
      let dirty = try GitWorkdirStatusText.hasUnstagedWorktreeChanges(gitDir: gitDir, workTree: work)
      #expect(dirty)
    }
  }

  private static func appendUserConfig(gitDir: URL) throws {
    let url = gitDir.appendingPathComponent("config")
    var s = try String(contentsOf: url, encoding: .utf8)
    s += "\n[user]\n\tname = Sit Tests\n\temail = sit-tests@example.com\n"
    try s.write(to: url, atomically: true, encoding: .utf8)
  }
}
