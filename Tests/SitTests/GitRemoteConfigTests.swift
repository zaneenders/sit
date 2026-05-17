import Foundation
import Testing

@testable import Sit

@Suite(.timeLimit(.minutes(1)))
struct GitRemoteConfigTests: ~Copyable {

  // MARK: - Remote parsing

  @Test func parseSingleRemote() throws {
    let tmp = try TempDir()
    defer { try? tmp.cleanup() }

    let config = """
      [remote "origin"]
        url = https://github.com/user/repo.git
        fetch = +refs/heads/*:refs/remotes/origin/*
      """
    try writeConfig(config, at: tmp.configURL)

    let remotes = try GitRemoteConfig.readRemotes(gitDir: tmp.gitDir)
    #expect(remotes.count == 1)
    #expect(remotes[0].name == "origin")
    #expect(remotes[0].url == "https://github.com/user/repo.git")
    #expect(remotes[0].pushURL == nil)
    #expect(remotes[0].resolvedPushURL == "https://github.com/user/repo.git")
    #expect(remotes[0].fetchRefspecs == ["+refs/heads/*:refs/remotes/origin/*"])
    #expect(remotes[0].pushRefspecs.isEmpty)
  }

  @Test func parseRemoteWithPushURL() throws {
    let tmp = try TempDir()
    defer { try? tmp.cleanup() }

    let config = """
      [remote "origin"]
        url = https://github.com/user/repo.git
        pushurl = git@github.com:user/repo.git
        fetch = +refs/heads/*:refs/remotes/origin/*
      """
    try writeConfig(config, at: tmp.configURL)

    let remotes = try GitRemoteConfig.readRemotes(gitDir: tmp.gitDir)
    #expect(remotes.count == 1)
    #expect(remotes[0].url == "https://github.com/user/repo.git")
    #expect(remotes[0].pushURL == "git@github.com:user/repo.git")
    #expect(remotes[0].resolvedPushURL == "git@github.com:user/repo.git")
  }

  @Test func parseMultipleRemotes() throws {
    let tmp = try TempDir()
    defer { try? tmp.cleanup() }

    let config = """
      [remote "origin"]
        url = https://github.com/user/repo.git
        fetch = +refs/heads/*:refs/remotes/origin/*
      [remote "upstream"]
        url = https://github.com/other/repo.git
        fetch = +refs/heads/*:refs/remotes/upstream/*
      """
    try writeConfig(config, at: tmp.configURL)

    let remotes = try GitRemoteConfig.readRemotes(gitDir: tmp.gitDir)
    #expect(remotes.count == 2)
    #expect(remotes.map(\.name).sorted() == ["origin", "upstream"])
  }

  @Test func remoteRequiresURL() throws {
    let tmp = try TempDir()
    defer { try? tmp.cleanup() }

    // Remote without url should be skipped
    let config = """
      [remote "incomplete"]
        fetch = +refs/heads/*:refs/remotes/origin/*
      """
    try writeConfig(config, at: tmp.configURL)

    let remotes = try GitRemoteConfig.readRemotes(gitDir: tmp.gitDir)
    #expect(remotes.isEmpty)
  }

  @Test func parsesPushRefspecs() throws {
    let tmp = try TempDir()
    defer { try? tmp.cleanup() }

    let config = """
      [remote "origin"]
        url = https://github.com/user/repo.git
        fetch = +refs/heads/*:refs/remotes/origin/*
        push = refs/heads/main:refs/heads/main
        push = refs/heads/dev:refs/heads/dev
      """
    try writeConfig(config, at: tmp.configURL)

    let remotes = try GitRemoteConfig.readRemotes(gitDir: tmp.gitDir)
    #expect(remotes[0].pushRefspecs.count == 2)
  }

  // MARK: - Branch parsing

  @Test func parseBranchConfig() throws {
    let tmp = try TempDir()
    defer { try? tmp.cleanup() }

    let config = """
      [branch "main"]
        remote = origin
        merge = refs/heads/main
      """
    try writeConfig(config, at: tmp.configURL)

    let bc = try GitRemoteConfig.readBranchConfig(gitDir: tmp.gitDir, branch: "main")
    #expect(bc != nil)
    #expect(bc?.name == "main")
    #expect(bc?.remoteName == "origin")
    #expect(bc?.mergeRef == "refs/heads/main")
  }

  @Test func missingBranchReturnsNil() throws {
    let tmp = try TempDir()
    defer { try? tmp.cleanup() }

    let config = """
      [branch "main"]
        remote = origin
      """
    try writeConfig(config, at: tmp.configURL)

    let bc = try GitRemoteConfig.readBranchConfig(gitDir: tmp.gitDir, branch: "nonexistent")
    #expect(bc == nil)
  }

  @Test func readAllBranchConfigs() throws {
    let tmp = try TempDir()
    defer { try? tmp.cleanup() }

    let config = """
      [branch "main"]
        remote = origin
        merge = refs/heads/main
      [branch "feature"]
        remote = origin
        merge = refs/heads/feature
      """
    try writeConfig(config, at: tmp.configURL)

    let branches = try GitRemoteConfig.readAllBranchConfigs(gitDir: tmp.gitDir)
    #expect(branches.count == 2)
  }

  // MARK: - Push destination resolution

  @Test func resolvePushDestinationFromBranchConfig() throws {
    let tmp = try TempDir()
    defer { try? tmp.cleanup() }

    let config = """
      [remote "origin"]
        url = https://github.com/user/repo.git
        fetch = +refs/heads/*:refs/remotes/origin/*
      [branch "main"]
        remote = origin
        merge = refs/heads/main
      """
    try writeConfig(config, at: tmp.configURL)

    let result = try GitRemoteConfig.resolvePushDestination(
      gitDir: tmp.gitDir, branch: "main")
    #expect(result != nil)
    #expect(result?.remote.name == "origin")
    #expect(result?.refspecs == ["refs/heads/main:refs/heads/main"])
  }

  @Test func resolvePushDestinationExplicitRemote() throws {
    let tmp = try TempDir()
    defer { try? tmp.cleanup() }

    let config = """
      [remote "origin"]
        url = https://github.com/user/repo.git
        fetch = +refs/heads/*:refs/remotes/origin/*
      [remote "fork"]
        url = https://github.com/other/repo.git
        fetch = +refs/heads/*:refs/remotes/fork/*
      """
    try writeConfig(config, at: tmp.configURL)

    // Explicitly push to fork
    let result = try GitRemoteConfig.resolvePushDestination(
      gitDir: tmp.gitDir, branch: "main", remoteName: "fork")
    #expect(result?.remote.name == "fork")
  }

  @Test func resolvePushDestinationUsesPushRefspecs() throws {
    let tmp = try TempDir()
    defer { try? tmp.cleanup() }

    let config = """
      [remote "origin"]
        url = https://github.com/user/repo.git
        fetch = +refs/heads/*:refs/remotes/origin/*
        push = refs/heads/main:refs/heads/production
      [branch "main"]
        remote = origin
      """
    try writeConfig(config, at: tmp.configURL)

    let result = try GitRemoteConfig.resolvePushDestination(
      gitDir: tmp.gitDir, branch: "main")
    #expect(result?.refspecs == ["refs/heads/main:refs/heads/production"])
  }

  @Test func resolvePushDestinationNoUpstreamReturnsNil() throws {
    let tmp = try TempDir()
    defer { try? tmp.cleanup() }

    let config = """
      [remote "origin"]
        url = https://github.com/user/repo.git
      """
    try writeConfig(config, at: tmp.configURL)

    let result = try GitRemoteConfig.resolvePushDestination(
      gitDir: tmp.gitDir, branch: "main")
    #expect(result == nil)
  }

  @Test func noConfigFileReturnsEmpty() throws {
    let tmp = try TempDir()
    defer { try? tmp.cleanup() }
    // No config file written

    let remotes = try GitRemoteConfig.readRemotes(gitDir: tmp.gitDir)
    #expect(remotes.isEmpty)

    let bc = try GitRemoteConfig.readBranchConfig(gitDir: tmp.gitDir, branch: "main")
    #expect(bc == nil)
  }

  // MARK: - Helpers

  private struct TempDir {
    let url: URL
    var gitDir: URL { url.appendingPathComponent(".git", isDirectory: true) }
    var configURL: URL {
      gitDir.appendingPathComponent("config")
    }

    init() throws {
      url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sit-tests-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
    }

    func cleanup() throws {
      try FileManager.default.removeItem(at: url)
    }
  }

  private func writeConfig(_ text: String, at url: URL) throws {
    try text.write(to: url, atomically: true, encoding: .utf8)
  }
}
