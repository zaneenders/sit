import Foundation
import Testing

@testable import Sit

@Suite
struct GitRepositoryTests: ~Copyable {
  @Test func discoverThrowsNotFoundWhenNoGitDirectory() throws {
    try TempDirectory.withRemoval { root in
      let empty = root.appendingPathComponent("nowhere", isDirectory: true)
      try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
      #expect(throws: GitRepositoryError.notFound(searchRoot: empty.path)) {
        try GitRepository.discover(from: empty)
      }
    }
  }

  @Test func discoverThrowsWhenDotGitIsAFile() throws {
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("wt", isDirectory: true)
      try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
      let dotGit = work.appendingPathComponent(".git", isDirectory: false)
      try Data("gitdir: /tmp/other\n".utf8).write(to: dotGit)
      #expect(throws: GitRepositoryError.gitDirFileNotSupported) {
        try GitRepository.discover(from: work)
      }
    }
  }

  @Test func discoverFindsRepoFromNestedFileURL() throws {
    let templates = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("repo", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let nestedDir = work.appendingPathComponent("deep/nested", isDirectory: true)
      try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
      let file = nestedDir.appendingPathComponent("file.txt", isDirectory: false)
      try Data("x".utf8).write(to: file)
      let (gitDir, workTree) = try GitRepository.discover(from: file)
      #expect(gitDir.lastPathComponent == ".git")
      #expect(workTree.standardizedFileURL == work.standardizedFileURL)
    }
  }
}
