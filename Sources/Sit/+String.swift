import RegexBuilder

/// Helpers to remove white space for dirty string comparisons.
extension String {
  package mutating func removeWhiteSpaces() {
    self.replace(Regex { OneOrMore(.whitespace) }) { _ in "" }
  }

  package func removingWhiteSpaces() -> String {
    self.replacing(Regex { OneOrMore(.whitespace) }) { _ in "" }
  }
}
