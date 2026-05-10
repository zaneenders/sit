import Foundation

// MARK: - CLI entry point

@main
enum BenchRunner {
  static func main() async {
    let args = CommandLine.arguments.dropFirst()

    do {
      switch args.first {
      case "--save", "save":
        try await Save.run()
      case "--list", "list":
        try List.run()
      case "--help", "-h", "help":
        printHelp()
      default:
        try await Check.run()
      }
    } catch is ExitCode {
      Foundation.exit(1)
    } catch {
      print("\(ANSI.red)✗\(ANSI.reset) \(error)")
      Foundation.exit(1)
    }
  }

  private static func printHelp() {
    print("""
      \(ANSI.bold)Sit Benchmark Regression Checker\(ANSI.reset)

      Usage:
        swift run -c release BenchRunner           Run benchmarks and check for regressions
        swift run -c release BenchRunner save      Run benchmarks and save as new baseline
        swift run -c release BenchRunner list      List tasks in the committed baseline

      The baseline is stored at \(C.baselinePath) and should be
      committed to the repository from the main branch.
      """)
  }
}

// MARK: - Shared constants

private enum C {
  static let baselinePath = "Benchmarks/Baselines/main.json"
  static let benchmarkTarget = "SitBenchmarks"
  static let sizes = [1, 2000, 10000]
  static let cycles = 15
  static let regressionThreshold = 1.10  // >10% slower = regression
}

// MARK: - ANSI

private enum ANSI {
  static let red = "\u{001b}[0;31m"
  static let green = "\u{001b}[0;32m"
  static let bold = "\u{001b}[1m"
  static let reset = "\u{001b}[0m"
}

// MARK: - JSON model types

private struct BenchmarkFile: Decodable {
  let version: Int
  let tasks: [TaskResults]
}

private struct TaskResults: Decodable {
  let title: String
  let results: [String: [[Int]]]  // size -> [[type, value], ...]
}

// MARK: - Running benchmarks

/// Runs SitBenchmarks via `swift run` and returns the path to the results JSON.
private func runBenchmarks(outputPath: String) async throws {
  let swiftPath = try findSwift()

  var args = [
    "run", "-c", "release", C.benchmarkTarget, "run", outputPath,
    "--mode", "replace-all",
    "--cycles", "\(C.cycles)",
  ]
  for size in C.sizes {
    args.append(contentsOf: ["--sizes", "\(size)"])
  }

  let process = Process()
  process.executableURL = URL(fileURLWithPath: swiftPath)
  process.arguments = args
  process.standardError = FileHandle.nullDevice

  let outputPipe = Pipe()
  process.standardOutput = outputPipe

  try process.run()
  process.waitUntilExit()

  let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
  let output = String(decoding: outputData, as: UTF8.self)

  guard process.terminationStatus == 0 else {
    for line in output.split(separator: "\n") where line.contains("error:") {
      print(line)
    }
    throw ExitCode.failure
  }

  var finishedLine: String?
  for line in output.split(separator: "\n") {
    let s = String(line)
    if s.hasPrefix("Build") || s.hasPrefix("[") { continue }
    if s.contains(".. --") { continue }
    if s.hasPrefix("Output file:") || s.hasPrefix("Discarding") || s.hasPrefix("Collecting data:") {
      continue
    }
    if s.hasPrefix("Finished in") {
      finishedLine = s
      continue
    }
    print(s)
  }
  if let finished = finishedLine {
    print("  \(finished)")
  }

  guard FileManager.default.fileExists(atPath: outputPath) else {
    print("\(ANSI.red)✗\(ANSI.reset) Benchmark output was not written to \(outputPath)")
    throw ExitCode.failure
  }
}

private func findSwift() throws -> String {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = ["which", "swift"]

  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = FileHandle.nullDevice

  try process.run()
  process.waitUntilExit()

  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

  guard !path.isEmpty else {
    print("\(ANSI.red)✗\(ANSI.reset) Could not find swift in PATH")
    throw ExitCode.failure
  }

  return path
}

// MARK: - Baseline operations

private func readBenchmarkFile(at path: String) throws -> [String: TaskResults] {
  let url = URL(fileURLWithPath: path)
  let data = try Data(contentsOf: url)
  let file = try JSONDecoder().decode(BenchmarkFile.self, from: data)
  var dict: [String: TaskResults] = [:]
  for task in file.tasks {
    dict[task.title] = task
  }
  return dict
}

private func averageTime(task: TaskResults, size: String) -> Double? {
  guard let samples = task.results[size], !samples.isEmpty else { return nil }
  let values = samples.map { Double($0[1]) }
  return values.reduce(0, +) / Double(values.count)
}

// MARK: - Comparison

private struct TaskComparison {
  let title: String
  let ratios: [String: Double]
}

private func compare(new: [String: TaskResults], baseline: [String: TaskResults]) -> [TaskComparison] {
  var comparisons: [TaskComparison] = []

  for (title, newTask) in new {
    guard let baselineTask = baseline[title] else { continue }
    var ratios: [String: Double] = [:]

    for size in newTask.results.keys {
      guard let newAvg = averageTime(task: newTask, size: size),
            let baselineAvg = averageTime(task: baselineTask, size: size),
            baselineAvg > 0
      else { continue }
      ratios[size] = newAvg / baselineAvg
    }

    if !ratios.isEmpty {
      comparisons.append(TaskComparison(title: title, ratios: ratios))
    }
  }

  return comparisons.sorted { $0.title < $1.title }
}

private func geometricMean(_ c: TaskComparison) -> Double {
  let logs = c.ratios.values.map { log($0) }
  return exp(logs.reduce(0, +) / Double(logs.count))
}

private func hasRegression(_ c: TaskComparison) -> Bool {
  geometricMean(c) > C.regressionThreshold
}

// MARK: - Exit code

private enum ExitCode: Error {
  case failure
}

// MARK: - Subcommands

private enum Check {
  static func run() async throws {
    let baselinePath = C.baselinePath

    guard FileManager.default.fileExists(atPath: baselinePath) else {
      print("\(ANSI.red)✗\(ANSI.reset) No baseline at \(baselinePath)")
      print("")
      print("  Generate one first:")
      print("    swift run -c release BenchRunner save")
      throw ExitCode.failure
    }

    let tempPath = "/tmp/sit-bench-\(UUID().uuidString.prefix(8)).json"

    print("\(ANSI.bold)=== Sit Benchmarks — Regression Check ===\(ANSI.reset)")
    print("")
    print("→ Running benchmarks …")
    try await runBenchmarks(outputPath: tempPath)

    print("")
    print("→ Comparing against baseline …")
    print("")

    let baseline = try readBenchmarkFile(at: baselinePath)
    let new = try readBenchmarkFile(at: tempPath)
    try? FileManager.default.removeItem(atPath: tempPath)

    let comparisons = compare(new: new, baseline: baseline)

    guard !comparisons.isEmpty else {
      print("  No matching tasks found between baseline and current run.")
      throw ExitCode.failure
    }

    let titleWidth = max(38, comparisons.map(\.title.count).max() ?? 0)
    let hdrTitle = "Task".padding(toLength: titleWidth, withPad: " ", startingAt: 0)
    print("  \(hdrTitle)   1        2000      10000    Δ")
    print("  \(String(repeating: "─", count: titleWidth))  ──────  ──────  ──────  ────")

    for c in comparisons {
      let geo = geometricMean(c)
      let sizes = c.ratios.sorted { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }

      let color: String
      let marker: String
      if geo > C.regressionThreshold {
        color = ANSI.red; marker = " ⬆"
      } else if geo < 1.0 / C.regressionThreshold {
        color = ANSI.green; marker = " ⬇"
      } else if geo > 1.05 {
        color = ANSI.bold; marker = " ⚡"
      } else {
        color = ""; marker = ""
      }

      let cols = sizes.map { String(format: "%.3f", $0.value) }
      let c1 = cols.count > 0 ? cols[0] : "  -"
      let c2 = cols.count > 1 ? cols[1] : "  -"
      let c3 = cols.count > 2 ? cols[2] : "  -"

      let delta = (geo - 1.0) * 100
      let deltaStr: String
      if abs(delta) < 0.5 {
        deltaStr = " ·"
      } else if delta > 0 {
        deltaStr = String(format: "+%.0f%%", delta)
      } else {
        deltaStr = String(format: "−%.0f%%", -delta)
      }

      let paddedTitle = c.title.padding(toLength: titleWidth, withPad: " ", startingAt: 0)
      print("  \(color)\(paddedTitle)\(ANSI.reset)\(marker)  \(c1)   \(c2)   \(c3)   \(deltaStr)")
    }

    print("")

    let improvementThreshold = 1.0 / C.regressionThreshold
    var improved: [TaskComparison] = []
    var regressed: [TaskComparison] = []
    for c in comparisons {
      let geo = geometricMean(c)
      if geo > C.regressionThreshold { regressed.append(c) }
      else if geo < improvementThreshold { improved.append(c) }
    }

    if !improved.isEmpty {
      for c in improved {
        let geo = geometricMean(c)
        let pct = Int(((1.0 - geo) * 100).rounded())
        print("  \(ANSI.green)⬇ −\(pct)%\(ANSI.reset)  \(c.title)")
      }
      print("")
    }

    if !regressed.isEmpty {
      for r in regressed {
        let geo = geometricMean(r)
        let pct = Int(((geo - 1) * 100).rounded())
        print("  \(ANSI.red)⬆ +\(pct)%\(ANSI.reset)  \(r.title)")
      }
      print("")
      print("\(ANSI.red)\(ANSI.bold)⚠  \(regressed.count) task\(regressed.count == 1 ? "" : "s") regressed\(ANSI.reset)")
      throw ExitCode.failure
    }

    print("\(ANSI.green)✓\(ANSI.reset) No regressions detected")
  }
}

private enum Save {
  static func run() async throws {
    let baselinePath = C.baselinePath
    let tempPath = "/tmp/sit-bench-\(UUID().uuidString.prefix(8)).json"

    print("\(ANSI.bold)=== Sit Benchmarks — Save Baseline ===\(ANSI.reset)")
    print("")
    print("→ Running benchmarks …")
    try await runBenchmarks(outputPath: tempPath)

    try? FileManager.default.removeItem(atPath: baselinePath)
    try FileManager.default.copyItem(atPath: tempPath, toPath: baselinePath)
    try? FileManager.default.removeItem(atPath: tempPath)

    print("")
    print("\(ANSI.green)✓\(ANSI.reset) Baseline saved to \(baselinePath)")
    print("")
    print("  To commit:")
    print("    git add \(baselinePath)")
    print("    git commit -m \"Update benchmark baseline\"")
  }
}

private enum List {
  static func run() throws {
    let baselinePath = C.baselinePath

    guard FileManager.default.fileExists(atPath: baselinePath) else {
      print("\(ANSI.red)✗\(ANSI.reset) No baseline at \(baselinePath)")
      print("")
      print("  Generate one first:")
      print("    swift run -c release BenchRunner save")
      throw ExitCode.failure
    }

    let baseline = try readBenchmarkFile(at: baselinePath)
    let titles = baseline.keys.sorted()
    print("\(ANSI.bold)\(titles.count) tasks in baseline:\(ANSI.reset)")
    for title in titles {
      print("  \(title)")
    }
  }
}
