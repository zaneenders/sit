/// Git URL conversion utilities shared across push/fetch/transport implementations.
enum GitURL {

  /// Detect SSH Git URLs and return the parsed SSH URL, or `nil` for HTTP(S) URLs.
  static func detectSSH(_ url: String) -> GitSSHTransport.SSHURL? {
    GitSSHTransport.parseSSHURL(url)
  }

  /// Convert SSH-style Git URLs to HTTPS so `async-http-client` can handle them.
  /// - `git@github.com:user/repo.git` → `https://github.com/user/repo.git`
  /// - `ssh://git@github.com/user/repo.git` → `https://github.com/user/repo.git`
  /// - `https://…` / `http://…` → returned unchanged
  static func convertToHTTPURL(_ url: String) -> String {
    // Already HTTP(S)
    if url.hasPrefix("https://") || url.hasPrefix("http://") {
      return url
    }
    // ssh://git@host/path → https://host/path
    if url.hasPrefix("ssh://") {
      let rest = String(url.dropFirst(6))
      let noUser = rest.replacingOccurrences(of: "git@", with: "")
      return "https://\(noUser)"
    }
    // git@host:path → https://host/path
    if url.hasPrefix("git@") {
      let rest = String(url.dropFirst(4))
      let parts = rest.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
      if parts.count == 2 {
        return "https://\(parts[0])/\(parts[1])"
      }
    }
    // Fallback: assume it needs https://
    if !url.contains("://") {
      return "https://\(url)"
    }
    return url
  }
}
