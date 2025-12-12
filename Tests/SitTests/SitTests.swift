import Foundation
import RegexBuilder
import Sit
import SystemPackage
import Testing

@Suite(.serialized) final class SitTests {
  private let cwd = FileManager.default.currentDirectoryPath
  private let testDir: FilePath

  init() async throws {
    self.testDir = FilePath(cwd).appending("temp")
    try FileManager.default.createDirectory(
      atPath: testDir.string, withIntermediateDirectories: true)
    _ = FileManager.default.changeCurrentDirectoryPath(testDir.string)
  }

  deinit {
    _ = FileManager.default.changeCurrentDirectoryPath(cwd)
    try! FileManager.default.removeItem(atPath: testDir.string)
  }

  @Test func basic() async throws {
    // TODO: don't assume main branch as default
    #expect(
      FileManager.default.fileExists(atPath: testDir.string)
        == true)
    try await Sit.create()
    #expect(
      FileManager.default.fileExists(atPath: testDir.appending(".git").string)
        == true)
    let temp = testDir.appending("temp.txt")
    let fd = try FileDescriptor.open(
      temp, .writeOnly, options: [.create], permissions: .ownerReadWrite)
    try fd.closeAfter {
      _ = try fd.writeAll("zane was here -> .".utf8)
    }
    #expect(FileManager.default.fileExists(atPath: temp.string) == true)
    var out = try await Sit.addAll()
    #expect(out == "")
    var expected = """
      On branch main
      No commits yet
      Changes to be committed:
        (use "git rm --cached <file>..." to unstage)
              new file:   temp.txt
      """
    out = try await Sit.status()
    #expect(out.removingWhiteSpaces() == expected.removingWhiteSpaces())
    out = try await Sit.commit("idk")
    let e = """
      ] "idk"\n 1 file changed, 1 insertion(+)\n create mode 100644 temp.txt\n
      """
    let pattern = Regex {
      One("[main (root-commit) ")
      OneOrMore(.anyNonNewline, .reluctant)  // commit hash.
      e
    }
    #expect(out.prefixMatch(of: pattern) != nil)
    out = try await Sit.status()
    expected = """
      On branch main
      nothing to commit, working tree clean
      """
    #expect(out.removingWhiteSpaces() == expected.removingWhiteSpaces())
  }
}
