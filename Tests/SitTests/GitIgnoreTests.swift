import Foundation
import Testing

@testable import Sit

@Suite(.timeLimit(.minutes(1)))
struct GitIgnoreTests: ~Copyable {
  @Test func starLogIgnoresDeepPaths() throws {
    let templates = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("w", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)
      try "*.log\n".write(to: work.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
      let m = try GitIgnoreMatcher(workTree: work, gitDir: gitDir)
      #expect(m.isIgnored(relativePath: "a.log", isDirectory: false))
      #expect(m.isIgnored(relativePath: "deep/nested/b.log", isDirectory: false))
      #expect(!m.isIgnored(relativePath: "readme.txt", isDirectory: false))
    }
  }

  @Test func negationOverridesPriorRule() throws {
    let templates = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("w", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)
      try """
      *.log
      !keep.log
      """.write(to: work.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
      let m = try GitIgnoreMatcher(workTree: work, gitDir: gitDir)
      #expect(m.isIgnored(relativePath: "drop.log", isDirectory: false))
      #expect(!m.isIgnored(relativePath: "keep.log", isDirectory: false))
    }
  }

  @Test func anchoredSlashMatchesOnlyImmediateUnderBase() throws {
    let templates = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("w", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)
      try "/out.txt\n".write(to: work.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
      let m = try GitIgnoreMatcher(workTree: work, gitDir: gitDir)
      #expect(m.isIgnored(relativePath: "out.txt", isDirectory: false))
      #expect(!m.isIgnored(relativePath: "sub/out.txt", isDirectory: false))
    }
  }

  @Test func anchoredDirectoryNameIgnoresAllPathsUnderIt() throws {
    let templates = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("w", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)
      try "/.build\n".write(to: work.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
      let m = try GitIgnoreMatcher(workTree: work, gitDir: gitDir)
      #expect(m.isIgnored(relativePath: ".build", isDirectory: true))
      #expect(m.isIgnored(relativePath: ".build/debug/index/foo", isDirectory: false))
      #expect(!m.isIgnored(relativePath: "src/.build/foo", isDirectory: false))
    }
  }

  @Test func nestedGitignoreUsesBaseDirectory() throws {
    let templates = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("w", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)
      let pkg = work.appendingPathComponent("pkg", isDirectory: true)
      try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
      try "local.bin\n".write(to: pkg.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
      let m = try GitIgnoreMatcher(workTree: work, gitDir: gitDir)
      #expect(m.isIgnored(relativePath: "pkg/local.bin", isDirectory: false))
      #expect(!m.isIgnored(relativePath: "other/local.bin", isDirectory: false))
    }
  }

  @Test func infoExcludeIsHonored() throws {
    let templates = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("w", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)
      let info = gitDir.appendingPathComponent("info", isDirectory: true)
      try FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
      try "scratch.txt\n".write(to: info.appendingPathComponent("exclude"), atomically: true, encoding: .utf8)
      let m = try GitIgnoreMatcher(workTree: work, gitDir: gitDir)
      #expect(m.isIgnored(relativePath: "scratch.txt", isDirectory: false))
    }
  }

  @Test func workTreeScanSkipsIgnoredFiles() throws {
    let templates = try GitInit.discoverTemplateDirectory()
    try TempDirectory.withRemoval { root in
      let work = root.appendingPathComponent("w", isDirectory: true)
      try GitInit.createEmptyRepository(workTree: work, initialBranch: "main", templateDirectory: templates)
      let gitDir = work.appendingPathComponent(".git", isDirectory: true)
      try "*.tmp\n".write(to: work.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
      try Data("x".utf8).write(to: work.appendingPathComponent("keep.c"))
      try Data("y".utf8).write(to: work.appendingPathComponent("drop.tmp"))
      let paths = try GitWorkTreeScan.allRelativeFilePaths(workTree: work, gitDir: gitDir)
      #expect(paths.contains("keep.c"))
      #expect(!paths.contains("drop.tmp"))
    }
  }
}
