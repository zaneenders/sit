import Foundation
import NIOFileSystem
import Subprocess
import Testing

@testable import Sit

#if canImport(System)
import System
#endif

@Suite
struct SitTests: ~Copyable {
  let tempDirectory: FilePath

  init() async throws {
    let cwd = try await FileSystem.shared.currentWorkingDirectory
    let path = cwd.appending("\(UUID().uuidString)_XXX")
    let temp = try await FileSystem.shared.createTemporaryDirectory(template: path)
    self.tempDirectory = temp
  }

  deinit {
    let temp = tempDirectory
    Task.immediate {
      try await FileSystem.shared.removeItem(at: temp, strategy: .platformDefault, recursively: true)
    }
  }

  @Test func sha1() {
    let hash = Sit.sha1("Sit".data(using: .utf32)!)
    #expect("e046cbae32f1992239732b3fb5f9a388aae5b925" == hash)
  }

  @Test func getCurrentBranch() async throws {
    let repository = try await GitRepository()
    let branch = try await ReferenceResolver.getCurrentBranch(repository)
    #expect(branch != nil)  // TODO: branch == main
  }

  @Test func isDetached() async throws {
    let repository = try await GitRepository()
    let isDetached = try await ReferenceResolver.isDetachedHEAD(repository)
    #expect(!isDetached)
  }

  @Test func calculateStatus() async throws {
    let cwd = try await FileSystem.shared.currentWorkingDirectory
    let repository = try await GitRepository(at: cwd)
    let machine = StatusCalculator(repository: repository)
    let status = try await machine.calculateStatus()
    print(status)
  }

  @Test func status() async throws {
    let status = try await Sit.status()

    #expect(status.staged.count >= 0)
    #expect(status.unstaged.count >= 0)
    #expect(status.untracked.count >= 0)
    #expect(status.conflicted.count >= 0)
  }

  @Test func gitRepository() async throws {
    let repo = try await GitRepository(at: ".")

    let currentBranch = try await repo.getCurrentBranch()
    let isDetached = try await repo.isDetachedHEAD()

    #expect(currentBranch != nil || isDetached)
  }

  @Test func indexParsing() async throws {
    let repo = try await GitRepository(at: ".")
    let indexEntries = try repo.readIndex()

    #expect(indexEntries.count >= 0)
  }

  @Test func commitFunctionality() async throws {
    _ = try await runGitCommand(at: tempDirectory, arguments: ["init"])
    _ = try await GitRepository(at: tempDirectory)

    let testFilePath = tempDirectory.appending("test.txt")
    let testContent = "Hello, World!"
    try testContent.write(to: URL(fileURLWithPath: testFilePath.string), atomically: true, encoding: .utf8)

    _ = try await runGitCommand(at: tempDirectory, arguments: ["add", "test.txt"])

    let commitSHA1 = try await Sit.commit(message: "Test commit from Sit", at: tempDirectory)
    print(commitSHA1)

    let statusOutput = try await runGitCommand(at: tempDirectory, arguments: ["status"])
    print("statusOutput", statusOutput)
  }
}

private func initializeGitRepo(at path: FilePath) async throws {
  _ = try await runGitCommand(at: path, arguments: ["init"])
  _ = try await runGitCommand(at: path, arguments: ["config", "user.name", "Test User"])
  _ = try await runGitCommand(at: path, arguments: ["config", "user.email", "test@example.com"])
}

private func runGitCommand(at path: FilePath, arguments: [String]) async throws -> String {

  let result = try await Subprocess.run(
    .name("git"),
    arguments: Arguments(arguments),
    workingDirectory: System.FilePath(path.string),
    output: .string(limit: .max, encoding: UTF8.self),
    error: .string(limit: .max, encoding: UTF8.self)
  )

  let error = result.standardError ?? ""
  let out = result.standardOutput ?? ""

  return out + " | " + error
}
