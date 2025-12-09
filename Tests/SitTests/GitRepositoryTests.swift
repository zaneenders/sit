import Foundation
import NIOFileSystem
import Testing

@testable import Sit

@Suite
struct GitRepositoryTests: ~Copyable {

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

  @Test func `init`() async throws {
    let repository = try await GitRepository(at: tempDirectory)

    print("EHRE")
  }
}
