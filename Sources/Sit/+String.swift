import RegexBuilder

/// Helpers to remove white space for dirty string comparisons.
extension String {
  public mutating func removeWhiteSpaces() {
    self.replace(Regex { OneOrMore(.whitespace) }) { _ in "" }
  }

  public func removingWhiteSpaces() -> String {
    self.replacing(Regex { OneOrMore(.whitespace) }) { _ in "" }
  }
}
