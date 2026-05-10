import Foundation
import Testing

@testable import Sit

@Suite(.timeLimit(.minutes(1)))
struct GitErrorAndStagingEdgeTests: ~Copyable {
  @Test func missingUserIdentityLocalizedDescriptionMentionsGitConfig() {
    let err: LocalizedError = GitIndexError.missingUserIdentity
    let desc = err.errorDescription
    #expect(desc != nil)
    #expect(desc!.contains("git config"))
    #expect(desc!.contains("GIT_AUTHOR"))
  }

  @Test func commitThrowsEmptyIndexWhenIndexMissing() throws {
    let templates = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("w", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)
      let indexURL = gitDir.appendingPathComponent("index")
      if FileManager.default.fileExists(atPath: indexURL.path) {
        try FileManager.default.removeItem(at: indexURL)
      }
      let author = GitLocalConfig.UserIdentity(name: "t", email: "t@t")
      #expect(throws: GitIndexError.emptyIndex) {
        try GitStaging.commit(
          gitDir: gitDir,
          workTree: work,
          message: "x",
          author: author,
          committer: author
        )
      }
    }
  }

  @Test func commitThrowsEmptyIndexWhenIndexHasNoEntries() throws {
    let templates = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("w", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)
      let empty = GitIndex()
      try empty.write(to: gitDir.appendingPathComponent("index"))
      let author = GitLocalConfig.UserIdentity(name: "t", email: "t@t")
      #expect(throws: GitIndexError.emptyIndex) {
        try GitStaging.commit(
          gitDir: gitDir,
          workTree: work,
          message: "x",
          author: author,
          committer: author
        )
      }
    }
  }

  @Test func commitThrowsWhenHeadIsNotAValidRefOrSha() throws {
    let templates = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("w", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)
      try Self.appendUserConfig(gitDir: gitDir)
      let file = work.appendingPathComponent("a.txt")
      try Data("z\n".utf8).write(to: file)
      var index = GitIndex()
      try index.stage(gitDir: gitDir, workTree: work, files: [file])
      try index.write(to: gitDir.appendingPathComponent("index"))
      try "garbage-head\n".write(to: gitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
      let author = GitLocalConfig.UserIdentity(name: "t", email: "t@t")
      #expect(throws: GitHEADError.unrecognized("garbage-head")) {
        try GitStaging.commit(
          gitDir: gitDir,
          workTree: work,
          message: "x",
          author: author,
          committer: author
        )
      }
    }
  }

  private static func appendUserConfig(gitDir: URL) throws {
    let url = gitDir.appendingPathComponent("config")
    var s = try String(contentsOf: url, encoding: .utf8)
    s += "\n[user]\n\tname = Sit Tests\n\temail = sit-tests@example.com\n"
    try s.write(to: url, atomically: true, encoding: .utf8)
  }
}
