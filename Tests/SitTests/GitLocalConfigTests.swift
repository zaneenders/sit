import Foundation
import Testing

@testable import Sit

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Mutates process environment; keep serialized so parallel tests do not clobber each other.
@Suite(.timeLimit(.minutes(1)), .serialized)
struct GitLocalConfigTests: ~Copyable {

  @Test func readUserIdentityUsesRepoConfigOverXdgWhenHomeIsolated() throws {
    try TempDirectory.withRemoval { root in
      let fakeHome = root.appendingPathComponent("HOME", isDirectory: true)
      try FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)
      let xdgGit = fakeHome.appendingPathComponent(".config/git", isDirectory: true)
      try FileManager.default.createDirectory(at: xdgGit, withIntermediateDirectories: true)
      try """
      [user]
      \tname = From XDG
      \temail = xdg@example.com
      """.write(to: xdgGit.appendingPathComponent("config"), atomically: true, encoding: .utf8)

      let templates = try GitInit.discoverTemplateDirectory()
      let work = fakeHome.appendingPathComponent("myrepo", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)
      var cfg = try String(contentsOf: gitDir.appendingPathComponent("config"), encoding: .utf8)
      cfg += """
        [user]
        \tname = From Repo
        \temail = repo@example.com
        """
      try cfg.write(to: gitDir.appendingPathComponent("config"), atomically: true, encoding: .utf8)

      try Self.withIsolatedHome(fakeHome.path) {
        let id = try GitLocalConfig.readUserIdentity(gitDir: gitDir)
        #expect(id.name == "From Repo")
        #expect(id.email == "repo@example.com")
      }
    }
  }

  @Test func readUserIdentityParsesQuotedName() throws {
    try TempDirectory.withRemoval { root in
      let fakeHome = root.appendingPathComponent("HOME", isDirectory: true)
      try FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)
      let templates = try GitInit.discoverTemplateDirectory()
      let work = fakeHome.appendingPathComponent("repo", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)
      var cfg = try String(contentsOf: gitDir.appendingPathComponent("config"), encoding: .utf8)
      cfg += """
        [user]
        \tname = "Quoted Name"
        \temail = quoted@example.com
        """
      try cfg.write(to: gitDir.appendingPathComponent("config"), atomically: true, encoding: .utf8)

      try Self.withIsolatedHome(fakeHome.path) {
        let id = try GitLocalConfig.readUserIdentity(gitDir: gitDir)
        #expect(id.name == "Quoted Name")
        #expect(id.email == "quoted@example.com")
      }
    }
  }

  @Test func readUserIdentityThrowsWhenMissing() throws {
    try TempDirectory.withRemoval { root in
      let fakeHome = root.appendingPathComponent("HOME", isDirectory: true)
      try FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)
      let templates = try GitInit.discoverTemplateDirectory()
      let work = fakeHome.appendingPathComponent("repo", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)

      Self.withIsolatedHome(fakeHome.path) {
        #expect(throws: GitIndexError.missingUserIdentity) {
          try GitLocalConfig.readUserIdentity(gitDir: gitDir)
        }
      }
    }
  }

  @Test func resolveAuthorIdentityPrefersGitAuthorEnv() throws {
    try TempDirectory.withRemoval { root in
      let fakeHome = root.appendingPathComponent("HOME", isDirectory: true)
      try FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)
      let templates = try GitInit.discoverTemplateDirectory()
      let work = fakeHome.appendingPathComponent("repo", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)

      try Self.withIsolatedHome(fakeHome.path) {
        try Self.withEnvOverrides(
          [
            "GIT_AUTHOR_NAME": "Env Author",
            "GIT_AUTHOR_EMAIL": "env-author@example.com",
          ]
        ) {
          let id = try GitLocalConfig.resolveAuthorIdentity(gitDir: gitDir)
          #expect(id.name == "Env Author")
          #expect(id.email == "env-author@example.com")
        }
      }
    }
  }

  @Test func resolveCommitterIdentityPrefersGitCommitterEnv() throws {
    try TempDirectory.withRemoval { root in
      let fakeHome = root.appendingPathComponent("HOME", isDirectory: true)
      try FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)
      let templates = try GitInit.discoverTemplateDirectory()
      let work = fakeHome.appendingPathComponent("repo", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)

      try Self.withIsolatedHome(fakeHome.path) {
        try Self.withEnvOverrides(
          [
            "GIT_COMMITTER_NAME": "Env Committer",
            "GIT_COMMITTER_EMAIL": "env-committer@example.com",
          ]
        ) {
          let id = try GitLocalConfig.resolveCommitterIdentity(gitDir: gitDir)
          #expect(id.name == "Env Committer")
          #expect(id.email == "env-committer@example.com")
        }
      }
    }
  }

  private static func withIsolatedHome(_ homePath: String, body: () throws -> Void) rethrows {
    try withEnvOverrides(["HOME": homePath, "XDG_CONFIG_HOME": ""], body: body)
  }

  /// Empty string clears the variable (`unsetenv`); `nil` values are skipped (leave unchanged).
  private static func withEnvOverrides(_ pairs: [String: String], body: () throws -> Void) rethrows {
    var saved: [String: String?] = [:]
    for key in pairs.keys {
      saved[key] = getenv(key).map { String(cString: $0) }
    }
    defer {
      for (key, old) in saved {
        if let old {
          _ = setenv(key, old, 1)
        } else {
          unsetenv(key)
        }
      }
    }
    for (key, value) in pairs {
      if value.isEmpty {
        unsetenv(key)
      } else {
        _ = setenv(key, value, 1)
      }
    }
    try body()
  }
}
