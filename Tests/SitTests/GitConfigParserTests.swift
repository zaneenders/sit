import Foundation
import Testing

@testable import Sit

@Suite(.timeLimit(.minutes(1)))
struct GitConfigParserTests: ~Copyable {

  // MARK: - Simple sections

  @Test func parseSingleSection() {
    let text = """
      [core]
        bare = false
        filemode = true
      """
    let entries = GitConfigParser.parse(text)
    #expect(entries.count == 2)
    #expect(entries[0].section == "core")
    #expect(entries[0].subsection == nil)
    #expect(entries[0].key == "bare")
    #expect(entries[0].value == "false")
    #expect(entries[1].key == "filemode")
    #expect(entries[1].value == "true")
  }

  @Test func parseSubsection() {
    let text = """
      [remote "origin"]
        url = https://example.com/repo.git
        fetch = +refs/heads/*:refs/remotes/origin/*
      """
    let entries = GitConfigParser.parse(text)
    #expect(entries.count == 2)
    #expect(entries[0].section == "remote")
    #expect(entries[0].subsection == "origin")
    #expect(entries[0].key == "url")
    #expect(entries[1].key == "fetch")
  }

  @Test func parseMultipleSections() {
    let text = """
      [user]
        name = Test
      [core]
        bare = false
      [remote "origin"]
        url = https://example.com
      [branch "main"]
        remote = origin
        merge = refs/heads/main
      """
    let entries = GitConfigParser.parse(text)

    let userEntries = entries.filter { $0.section == "user" }
    #expect(userEntries.count == 1)
    #expect(userEntries[0].key == "name")

    let coreEntries = entries.filter { $0.section == "core" }
    #expect(coreEntries.count == 1)

    let remoteEntries = entries.filter { $0.section == "remote" }
    #expect(remoteEntries.count == 1)
    #expect(remoteEntries[0].subsection == "origin")

    let branchEntries = entries.filter { $0.section == "branch" }
    #expect(branchEntries.count == 2)
    #expect(branchEntries[0].subsection == "main")
  }

  // MARK: - Edge cases

  @Test func parseEmptyText() {
    let entries = GitConfigParser.parse("")
    #expect(entries.isEmpty)
  }

  @Test func parseCommentedLines() {
    let text = """
      # This is a comment
      ; Also a comment
      [core]
        # comment inside section
        bare = false
      """
    let entries = GitConfigParser.parse(text)
    #expect(entries.count == 1)
    #expect(entries[0].key == "bare")
  }

  @Test func parseBlankLines() {
    let text = """

      [core]

        bare = false

      """
    let entries = GitConfigParser.parse(text)
    #expect(entries.count == 1)
  }

  @Test func parseQuotedValues() {
    let text = """
      [user]
        name = "John Doe"
        email = "john@example.com"
      """
    let entries = GitConfigParser.parse(text)
    #expect(entries.count == 2)
    #expect(entries[0].value == "John Doe")
    #expect(entries[1].value == "john@example.com")
  }

  @Test func parseValueWithEquals() {
    let text = """
      [remote "origin"]
        url = https://example.com/repo.git
      """
    let entries = GitConfigParser.parse(text)
    #expect(entries[0].value == "https://example.com/repo.git")
  }

  @Test func ignoresLinesWithoutEquals() {
    let text = """
      [core]
        bare
        filemode = true
      """
    let entries = GitConfigParser.parse(text)
    #expect(entries.count == 1)
    #expect(entries[0].key == "filemode")
  }

  @Test func preservesSectionOrder() {
    let text = """
      [a]
        x = 1
      [b]
        y = 2
      """
    let entries = GitConfigParser.parse(text)
    #expect(entries[0].section == "a")
    #expect(entries[1].section == "b")
  }
}
