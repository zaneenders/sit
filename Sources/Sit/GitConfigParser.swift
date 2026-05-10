/// Low-level Git config file parser (INI-style with `[section]` and
/// `[section "subsection"]` headers and `key = value` pairs).
///
/// Does not perform the multi-file layering that Git does — that is left to
/// higher-level code (see `GitLocalConfig`, `GitRemoteConfig`).
package enum GitConfigParser: Sendable {

  /// A single config entry: `section.subsection.key = value`.
  /// If the section has no subsection, `subsection` is `nil`.
  package struct Entry: Equatable, Sendable {
    package let section: String
    package let subsection: String?
    package let key: String
    package let value: String
  }

  /// Parse `text` (the contents of a single git config file) into entries.
  package static func parse(_ text: String) -> [Entry] {
    var entries: [Entry] = []
    var currentSection = ""
    var currentSubsection: String? = nil

    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let t = line.trimmingCharacters(in: .whitespaces)

      // Skip comments and blank lines
      if t.isEmpty || t.hasPrefix("#") || t.hasPrefix(";") { continue }

      // Section header: [section] or [section "subsection"]
      if t.hasPrefix("[") && t.hasSuffix("]") {
        let inner = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        // Split on first space or tab that is followed by a quote
        if let spaceIdx = inner.firstIndex(where: { $0 == " " || $0 == "\t" }) {
          currentSection = String(inner[..<spaceIdx]).lowercased()
          let rest = inner[inner.index(after: spaceIdx)...]
            .trimmingCharacters(in: .whitespaces)
          currentSubsection = unquote(String(rest))
        } else {
          currentSection = inner.lowercased()
          currentSubsection = nil
        }
        continue
      }

      // Key-value pair
      let parts = t.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else { continue }
      let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
      let value = unquote(parts[1].trimmingCharacters(in: .whitespaces))
      guard !key.isEmpty else { continue }

      entries.append(
        Entry(
          section: currentSection,
          subsection: currentSubsection,
          key: key,
          value: value))
    }

    return entries
  }

  /// Strip surrounding double-quotes if present.
  private static func unquote(_ s: String) -> String {
    if s.count >= 2, s.first == "\"", s.last == "\"" {
      return String(s.dropFirst().dropLast())
    }
    return s
  }
}
