import Foundation
import Testing

@testable import sit_cli

@Suite(.timeLimit(.minutes(1)))
struct GitSSHTransportTests: ~Copyable {

  // MARK: - parseSSHURL

  @Test func parseGitAtStyleURL() {
    let url = "git@github.com:zaneenders/sit.git"
    let parsed = GitSSHTransport.parseSSHURL(url)
    #expect(parsed != nil)
    #expect(parsed?.host == "github.com")
    #expect(parsed?.user == "git")
    #expect(parsed?.path == "zaneenders/sit.git")
  }

  @Test func parseGitAtStyleURLWithDeepPath() {
    let url = "git@gitlab.example.com:org/team/repo.git"
    let parsed = GitSSHTransport.parseSSHURL(url)
    #expect(parsed?.host == "gitlab.example.com")
    #expect(parsed?.user == "git")
    #expect(parsed?.path == "org/team/repo.git")
  }

  @Test func parseSshSchemeWithUser() {
    let url = "ssh://git@github.com/zaneenders/sit.git"
    let parsed = GitSSHTransport.parseSSHURL(url)
    #expect(parsed?.host == "github.com")
    #expect(parsed?.user == "git")
    #expect(parsed?.path == "zaneenders/sit.git")
  }

  @Test func parseSshSchemeWithoutUser() {
    let url = "ssh://github.com/user/repo.git"
    let parsed = GitSSHTransport.parseSSHURL(url)
    #expect(parsed?.host == "github.com")
    #expect(parsed?.user == "git")
    #expect(parsed?.path == "user/repo.git")
  }

  @Test func parseSSHURLRejectsHTTPS() {
    #expect(GitSSHTransport.parseSSHURL("https://github.com/user/repo.git") == nil)
  }

  @Test func parseSSHURLRejectsHTTP() {
    #expect(GitSSHTransport.parseSSHURL("http://github.com/user/repo.git") == nil)
  }

  @Test func parseSSHURLRejectsPlainPath() {
    #expect(GitSSHTransport.parseSSHURL("/some/local/path") == nil)
  }

  @Test func parseSSHURLEquality() {
    let a = GitSSHTransport.parseSSHURL("git@github.com:user/repo.git")
    let b = GitSSHTransport.parseSSHURL("git@github.com:user/repo.git")
    #expect(a == b)
    let c = GitSSHTransport.parseSSHURL("git@github.com:user/other.git")
    #expect(a != c)
  }

  // MARK: - parsePushStatus

  /// Server sends ref advertisement + 0000 + status lines.
  /// parsePushStatus should skip everything up to the first flush and
  /// return only the status lines that follow it.
  @Test func parsePushStatusSkipsRefAdvertisement() {
    var body: [UInt8] = []
    // Fake ref advertisement
    body.append(contentsOf: GitPktLine.encode(
      "3b18e512dba79e4c8300dd08aeb37f8e728b8dad refs/heads/main\0report-status\n"))
    body.append(contentsOf: GitPktLine.encode(
      "dd7e1c6f0fefe118f0b63d9f10908c460aa317a6 refs/heads/dev\n"))
    body.append(contentsOf: GitPktLine.flush)  // end of ref advert
    // Status report
    body.append(contentsOf: GitPktLine.encode("unpack ok\n"))
    body.append(contentsOf: GitPktLine.encode("ok refs/heads/main\n"))
    body.append(contentsOf: GitPktLine.flush)

    let lines = GitSSHTransport.parsePushStatus(body)
    #expect(lines == ["unpack ok", "ok refs/heads/main"])
  }

  @Test func parsePushStatusRejectsNgRef() {
    var body: [UInt8] = []
    body.append(contentsOf: GitPktLine.encode(
      "3b18e512dba79e4c8300dd08aeb37f8e728b8dad refs/heads/main\0report-status\n"))
    body.append(contentsOf: GitPktLine.flush)
    body.append(contentsOf: GitPktLine.encode("unpack ok\n"))
    body.append(contentsOf: GitPktLine.encode("ng refs/heads/main non-fast-forward\n"))
    body.append(contentsOf: GitPktLine.flush)

    let lines = GitSSHTransport.parsePushStatus(body)
    #expect(lines.count == 2)
    #expect(lines[1].hasPrefix("ng "))
  }

  @Test func parsePushStatusHandlesNoStatusAfterFlush() {
    var body: [UInt8] = []
    body.append(contentsOf: GitPktLine.encode("sha refs/heads/main\n"))
    body.append(contentsOf: GitPktLine.flush)
    // No status lines follow

    let lines = GitSSHTransport.parsePushStatus(body)
    #expect(lines.isEmpty)
  }

  @Test func parsePushStatusEmptyInput() {
    #expect(GitSSHTransport.parsePushStatus([]).isEmpty)
  }

  @Test func parsePushStatusOnlyFlush() {
    let lines = GitSSHTransport.parsePushStatus(GitPktLine.flush)
    #expect(lines.isEmpty)
  }
}
