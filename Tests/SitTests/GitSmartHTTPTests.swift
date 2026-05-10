import Foundation
import Testing

@testable import sit_cli

@Suite(.timeLimit(.minutes(1)))
struct GitSmartHTTPTests: ~Copyable {

  // MARK: - Ref advertisement parsing

  @Test func parseSimpleRefAdvertisement() {
    // Simulate the body of GET /info/refs?service=git-receive-pack
    var body: [UInt8] = []
    // First ref line with capabilities
    body.append(
      contentsOf: GitPktLine.encode(
        "0000000000000000000000000000000000000000 HEAD\0report-status side-band-64k delete-refs\n"
      ))
    body.append(
      contentsOf: GitPktLine.encode(
        "3b18e512dba79e4c8300dd08aeb37f8e728b8dad refs/heads/main\n"))
    body.append(
      contentsOf: GitPktLine.encode(
        "dd7e1c6f0fefe118f0b63d9f10908c460aa317a6 refs/heads/dev\n"))
    body.append(contentsOf: GitPktLine.flush)

    let advert = GitSmartHTTP.parseRefAdvertisement(body)

    #expect(advert.refs.count == 3)

    // HEAD line (all-zeros SHA for capabilities-only)
    #expect(advert.refs[0].sha20 == [UInt8](repeating: 0, count: 20))
    #expect(advert.refs[0].name == "HEAD")
    #expect(advert.refs[0].capabilities.contains("report-status"))
    #expect(advert.refs[0].capabilities.contains("side-band-64k"))

    // Main branch
    #expect(advert.refs[1].name == "refs/heads/main")
    #expect(advert.refs[2].name == "refs/heads/dev")

    // Capabilities set
    #expect(advert.capabilities.contains("report-status"))
    #expect(advert.capabilities.contains("side-band-64k"))
    #expect(advert.capabilities.contains("delete-refs"))
  }

  @Test func parseRefAdvertisementWithOnlyRefs() {
    var body: [UInt8] = []
    body.append(
      contentsOf: GitPktLine.encode(
        "abc123def456abc123def456abc123def456abc1 refs/heads/main\n"))
    body.append(contentsOf: GitPktLine.flush)

    let advert = GitSmartHTTP.parseRefAdvertisement(body)

    #expect(advert.refs.count == 1)
    #expect(advert.refs[0].name == "refs/heads/main")
    #expect(advert.refs[0].capabilities.isEmpty)
    #expect(advert.capabilities.isEmpty)
  }

  @Test func parseEmptyAdvertisement() {
    let body: [UInt8] = Array("0000".utf8)
    let advert = GitSmartHTTP.parseRefAdvertisement(body)
    #expect(advert.refs.isEmpty)
    #expect(advert.capabilities.isEmpty)
  }

  // MARK: - Push response parsing

  @Test func parsePushSuccessResponse() {
    var body: [UInt8] = []
    body.append(contentsOf: GitPktLine.encode("unpack ok\n"))
    body.append(contentsOf: GitPktLine.encode("ok refs/heads/main\n"))
    body.append(contentsOf: GitPktLine.flush)

    let lines = GitSmartHTTP.parsePushResponse(body)
    #expect(lines.count == 2)
    #expect(lines[0] == "unpack ok")
    #expect(lines[1] == "ok refs/heads/main")
  }

  @Test func parsePushMixedResponse() {
    var body: [UInt8] = []
    body.append(contentsOf: GitPktLine.encode("unpack ok\n"))
    body.append(contentsOf: GitPktLine.encode("ok refs/heads/main\n"))
    body.append(contentsOf: GitPktLine.encode("ng refs/heads/other non-fast-forward\n"))
    body.append(contentsOf: GitPktLine.flush)

    let lines = GitSmartHTTP.parsePushResponse(body)
    #expect(lines.count == 3)
    #expect(lines[2] == "ng refs/heads/other non-fast-forward")
  }
}
