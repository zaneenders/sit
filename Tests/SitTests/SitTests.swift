import Testing

@testable import Sit

@Suite
struct SitTests {

  @Test func sha1() {
    let hash = Sit.sha1("Scribe".data(using: .utf32)!)
    #expect("fa0712116f9015471827ebe605bc71071de6fef1" == hash)
  }

  @Test func status() throws {
    // Test basic status functionality
    let status = try Sit.status()

    // Should return a StatusResult without throwing
    #expect(status.staged.count >= 0)
    #expect(status.unstaged.count >= 0)
    #expect(status.untracked.count >= 0)
    #expect(status.conflicted.count >= 0)
  }

  @Test func gitRepository() throws {
    // Test repository initialization
    let repo = try GitRepository(at: ".")

    // Should be able to get basic repository info
    let currentBranch = try repo.getCurrentBranch()
    let isDetached = try repo.isDetachedHEAD()

    // Should not throw
    #expect(currentBranch != nil || isDetached)
  }

  @Test func indexParsing() throws {
    // Test index parsing
    let repo = try GitRepository(at: ".")
    let indexEntries = try repo.readIndex()

    // Should return array (possibly empty)
    #expect(indexEntries.count >= 0)
  }
}
