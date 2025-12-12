import Logging
import Subprocess
import SystemPackage

#if canImport(System)
import System
#endif

/// A git client wrapper for Swift programs
public enum Sit {

  /// creates a new git repository in the current working directory.
  @discardableResult
  public static func create(_ logger: Logger? = nil) async throws -> String {
    try await Subprocess.run(
      .name("git"), arguments: ["init"],
      output: .string(limit: .max),
      error: .string(limit: .max)
    ).standardOutput
      ?? ""
  }

  /// Adds all files in the current working directory to the staging.
  @discardableResult
  public static func addAll(_ logger: Logger? = nil) async throws -> String {
    try await Subprocess.run(
      .name("git"), arguments: ["add", "--all"],
      output: .string(limit: .max),
      error: .string(limit: .max)
    )
    .standardOutput ?? ""
  }

  /// Commits the staged files to the git repository.
  @discardableResult
  public static func commit(_ message: String, _ logger: Logger? = nil) async throws -> String {
    return try await Subprocess.run(
      .name("git"),
      arguments: [
        "commit",
        """
        -m"\(message)"
        """,
      ],
      output: .string(limit: .max),
      error: .string(limit: .max)
    )
    .standardOutput ?? ""
  }

  #if canImport(System)
  @discardableResult
  public static func pull(cwd: System.FilePath? = nil, _ logger: Logger? = nil) async throws -> String {
    try await Subprocess.run(
      .name("git"), arguments: ["pull"],
      workingDirectory: cwd,
      output: .string(limit: .max),
      error: .string(limit: .max)
    ).standardOutput
      ?? ""
  }
  #else
  @discardableResult
  public static func pull(cwd: SystemPackage.FilePath? = nil, _ logger: Logger? = nil) async throws -> String {
    try await Subprocess.run(
      .name("git"), arguments: ["pull"],
      workingDirectory: cwd,
      output: .string(limit: .max),
      error: .string(limit: .max)
    ).standardOutput
      ?? ""
  }
  #endif

  @discardableResult
  public static func push(_ logger: Logger? = nil) async throws -> String {
    try await Subprocess.run(
      .name("git"), arguments: ["push"],
      output: .string(limit: .max),
      error: .string(limit: .max)
    ).standardOutput
      ?? ""
  }

  #if canImport(System)
  @discardableResult
  public static func checkout(_ marker: String, _ cwd: System.FilePath? = nil, _ logger: Logger? = nil)
    async throws
    -> String
  {
    try await Subprocess.run(
      .name("git"), arguments: ["checkout", marker],
      workingDirectory: cwd,
      output: .string(limit: .max),
      error: .string(limit: .max)
    ).standardOutput
      ?? ""
  }
  #else
  @discardableResult
  public static func checkout(_ marker: String, _ cwd: SystemPackage.FilePath? = nil, _ logger: Logger? = nil)
    async throws
    -> String
  {
    try await Subprocess.run(
      .name("git"), arguments: ["checkout", marker],
      workingDirectory: cwd,
      output: .string(limit: .max),
      error: .string(limit: .max)
    ).standardOutput
      ?? ""
  }
  #endif

  @discardableResult
  public static func reset(_ logger: Logger? = nil) async throws -> String {
    try await Subprocess.run(
      .name("git"), arguments: ["reset", "--hard"],
      output: .string(limit: .max),
      error: .string(limit: .max)
    )
    .standardOutput
      ?? ""
  }

  @discardableResult
  public static func clear(_ logger: Logger? = nil) async throws -> String {
    try await Subprocess.run(
      .name("git"), arguments: ["clean", "-f", "-q"],
      output: .string(limit: .max),
      error: .string(limit: .max)
    )
    .standardOutput
      ?? ""
  }

  @discardableResult
  // TODO make taret optional?
  public static func clone(_ repo: String, _ target: String, _ logger: Logger? = nil) async throws -> (String, String) {
    let out =
      try await Subprocess.run(
        .name("git"), arguments: ["clone", repo, target],
        output: .string(limit: .max),
        error: .string(limit: .max)
      )
    if let err = out.standardError, err.count > 0 {
      logger?.error("\(err)")
    }
    return (out.standardOutput ?? "", out.standardError ?? "")
  }

  /// Returns the  status of the git repo.
  @discardableResult
  public static func status(_ logger: Logger? = nil) async throws -> String {
    try await Subprocess.run(
      .name("git"), arguments: ["status"],
      output: .string(limit: .max),
      error: .string(limit: .max)
    ).standardOutput
      ?? ""
  }
}
