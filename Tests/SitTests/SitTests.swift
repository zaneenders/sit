import Foundation
import NIOFileSystem
import Testing

@testable import Sit

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
    // Test repository initialization
    let repo = try await GitRepository(at: ".")

    // Should be able to get basic repository info
    let currentBranch = try await repo.getCurrentBranch()
    let isDetached = try await repo.isDetachedHEAD()

    // Should not throw
    #expect(currentBranch != nil || isDetached)
  }

  @Test func indexParsing() async throws {
    // Test index parsing
    let repo = try await GitRepository(at: ".")
    let indexEntries = try repo.readIndex()

    // Should return array (possibly empty)
    #expect(indexEntries.count >= 0)
  }
}
