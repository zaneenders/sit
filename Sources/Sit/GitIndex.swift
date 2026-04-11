public import Foundation

/// Git index (`.git/index`) version 2 read/write with regular-file entries only.
public struct GitIndex: Sendable {
  struct RawEntry: Equatable, Sendable {
    var path: String
    var ctimeSec: UInt32
    var ctimeNSec: UInt32
    var mtimeSec: UInt32
    var mtimeNSec: UInt32
    var dev: UInt32
    var ino: UInt32
    var mode: UInt32
    var uid: UInt32
    var gid: UInt32
    var size: UInt32
    var sha: [UInt8]
  }

  private var entries: [RawEntry]

  public init() {
    entries = []
  }

  public init(bytes: [UInt8]) throws {
    entries = try Self.parse(bytes: bytes)
  }

  public static func load(from indexURL: URL) throws -> GitIndex {
    guard FileManager.default.fileExists(atPath: indexURL.path) else {
      throw GitIndexError.indexNotFound
    }
    let data = try Data(contentsOf: indexURL)
    return try GitIndex(bytes: Array(data))
  }

  public var isEmpty: Bool { entries.isEmpty }

  public var trackedPaths: [String] {
    entries.map(\.path).sorted()
  }

  public var pathToBlobSha: [String: [UInt8]] {
    Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0.sha) })
  }

  public mutating func removeEntry(path: String) {
    entries.removeAll { $0.path == path }
  }

  /// Stage regular files (not directories). Paths must sit under `workTree`.
  public mutating func stage(gitDir: URL, workTree: URL, files: [URL]) throws {
    let wt = workTree.standardizedFileURL
    let fm = FileManager.default
    for file in files {
      let abs = file.standardizedFileURL
      let rel = try Self.relativePath(file: abs, workTree: wt)
      var isDir: ObjCBool = false
      guard fm.fileExists(atPath: abs.path, isDirectory: &isDir) else {
        throw GitIndexError.cannotReadFile(abs.path)
      }
      if isDir.boolValue { throw GitIndexError.notARegularFile(abs.path) }
      let data = try Data(contentsOf: abs)
      let blobSha = try GitLooseObjectWriter.writeBlob(gitDir: gitDir, content: Array(data))
      let meta = try Self.metadataForIndex(path: abs.path, size: UInt32(truncatingIfNeeded: data.count))
      let entry = RawEntry(
        path: rel,
        ctimeSec: meta.ctimeSec,
        ctimeNSec: meta.ctimeNSec,
        mtimeSec: meta.mtimeSec,
        mtimeNSec: meta.mtimeNSec,
        dev: meta.dev,
        ino: meta.ino,
        mode: meta.mode,
        uid: meta.uid,
        gid: meta.gid,
        size: UInt32(truncatingIfNeeded: data.count),
        sha: blobSha
      )
      entries.removeAll { $0.path == rel }
      entries.append(entry)
    }
    entries.sort { $0.path < $1.path }
  }

  public func write(to indexURL: URL) throws {
    try serialized().write(to: indexURL, options: .atomic)
  }

  public func serialized() throws -> Data {
    let sorted = entries.sorted { $0.path < $1.path }
    var out: [UInt8] = []
    out.reserveCapacity(12 + sorted.count * 128)
    out.append(contentsOf: [UInt8(ascii: "D"), UInt8(ascii: "I"), UInt8(ascii: "R"), UInt8(ascii: "C")])
    out.append(contentsOf: Self.u32be(2))
    out.append(contentsOf: Self.u32be(UInt32(sorted.count)))
    for e in sorted {
      try Self.appendEntry(e, to: &out)
    }
    let checksumInput = out
    let hash = GitSHA1.digest(of: checksumInput)
    out.append(contentsOf: hash)
    return Data(out)
  }

  /// Writes the tree object for the current index and returns its 20-byte SHA-1.
  public func writeRootTree(gitDir: URL) throws -> [UInt8] {
    guard !entries.isEmpty else { throw GitIndexError.emptyIndex }
    let sorted = entries.sorted { $0.path < $1.path }
    let flat: [(String, UInt32, [UInt8])] = sorted.map { ($0.path, $0.mode, $0.sha) }
    return try Self.buildTreeLevel(gitDir: gitDir, entries: flat)
  }

  // MARK: - Private

  private static func relativePath(file: URL, workTree: URL) throws -> String {
    let f = file.standardizedFileURL.path
    let w = workTree.standardizedFileURL.path
    let prefix = w.hasSuffix("/") ? w : w + "/"
    guard f.hasPrefix(prefix) || f == w else {
      throw GitIndexError.fileNotInWorkTree(file.path)
    }
    let rel: Substring
    if f == w {
      rel = ""
    } else {
      rel = f.dropFirst(prefix.count)
    }
    guard !rel.isEmpty else {
      throw GitIndexError.fileNotInWorkTree(file.path)
    }
    return String(rel).replacingOccurrences(of: "\\", with: "/")
  }

  private struct Meta {
    var ctimeSec: UInt32
    var ctimeNSec: UInt32
    var mtimeSec: UInt32
    var mtimeNSec: UInt32
    var dev: UInt32
    var ino: UInt32
    var mode: UInt32
    var uid: UInt32
    var gid: UInt32
  }

  private static func metadataForIndex(path: String, size: UInt32) throws -> Meta {
    let attrs = try FileManager.default.attributesOfItem(atPath: path)
    let mtime = (attrs[.modificationDate] as? Date) ?? Date()
    let ctime = (attrs[.creationDate] as? Date) ?? mtime
    let posix = UInt32(truncatingIfNeeded: (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o644)
    let perm = posix & 0o777
    let hasExec = (perm & 0o111) != 0
    let mode = hasExec ? UInt32(0o100755) : UInt32(0o100644)
    let uid = UInt32(truncatingIfNeeded: (attrs[.ownerAccountID] as? NSNumber)?.intValue ?? 0)
    let gid = UInt32(truncatingIfNeeded: (attrs[.groupOwnerAccountID] as? NSNumber)?.intValue ?? 0)
    func splitTime(_ d: Date) -> (UInt32, UInt32) {
      let t = d.timeIntervalSince1970
      let sec = UInt32(truncatingIfNeeded: Int64(t))
      let frac = t - floor(t)
      let nsec = UInt32(truncatingIfNeeded: Int64((frac * 1_000_000_000.0).rounded()))
      return (sec, nsec)
    }
    let (cts, ctn) = splitTime(ctime)
    let (mts, mtn) = splitTime(mtime)
    return Meta(
      ctimeSec: cts,
      ctimeNSec: ctn,
      mtimeSec: mts,
      mtimeNSec: mtn,
      dev: 0,
      ino: 0,
      mode: mode,
      uid: uid,
      gid: gid
    )
  }

  private static func u32be(_ v: UInt32) -> [UInt8] {
    var be = v.bigEndian
    return withUnsafeBytes(of: &be) { Array($0) }
  }

  private static func u16be(_ v: UInt16) -> [UInt8] {
    var be = v.bigEndian
    return withUnsafeBytes(of: &be) { Array($0) }
  }

  private static func readU32be(_ b: [UInt8], _ i: inout Int) throws -> UInt32 {
    guard i + 4 <= b.count else { throw GitIndexError.indexCorrupt("truncated u32") }
    let v =
      (UInt32(b[i]) << 24) | (UInt32(b[i + 1]) << 16) | (UInt32(b[i + 2]) << 8) | UInt32(b[i + 3])
    i += 4
    return v
  }

  private static func readU16be(_ b: [UInt8], _ i: inout Int) throws -> UInt16 {
    guard i + 2 <= b.count else { throw GitIndexError.indexCorrupt("truncated u16") }
    let v = (UInt16(b[i]) << 8) | UInt16(b[i + 1])
    i += 2
    return v
  }

  private static func parse(bytes: [UInt8]) throws -> [RawEntry] {
    guard bytes.count >= 12 + 20 else { throw GitIndexError.indexCorrupt("too small") }
    var i = 0
    guard bytes[i] == UInt8(ascii: "D"), bytes[i + 1] == UInt8(ascii: "I"),
      bytes[i + 2] == UInt8(ascii: "R"), bytes[i + 3] == UInt8(ascii: "C")
    else {
      throw GitIndexError.indexCorrupt("bad signature")
    }
    i += 4
    let version = try readU32be(bytes, &i)
    guard version == 2 || version == 3 || version == 4 else {
      throw GitIndexError.unsupportedIndexVersion(version)
    }
    let count = try readU32be(bytes, &i)
    var list: [RawEntry] = []
    list.reserveCapacity(Int(count))
    for _ in 0..<count {
      let entryStart = i
      guard i + 62 <= bytes.count else { throw GitIndexError.indexCorrupt("truncated entry") }
      let ctimeSec = try readU32be(bytes, &i)
      let ctimeNsec = try readU32be(bytes, &i)
      let mtimeSec = try readU32be(bytes, &i)
      let mtimeNsec = try readU32be(bytes, &i)
      let dev = try readU32be(bytes, &i)
      let ino = try readU32be(bytes, &i)
      let mode = try readU32be(bytes, &i)
      let uid = try readU32be(bytes, &i)
      let gid = try readU32be(bytes, &i)
      let size = try readU32be(bytes, &i)
      let sha = Array(bytes[i..<(i + 20)])
      i += 20
      let flags = try readU16be(bytes, &i)
      let assumeValid = (flags >> 15) & 1
      let extended = (flags >> 14) & 1
      _ = assumeValid
      if extended != 0 {
        _ = try readU16be(bytes, &i)
      }
      let nameLen = Int(flags & 0x0fff)
      if nameLen == 0x0fff {
        throw GitIndexError.pathTooLongForIndex("(>=4095)")
      }
      guard i + nameLen <= bytes.count else { throw GitIndexError.indexCorrupt("truncated name") }
      let nameBytes = Array(bytes[i..<(i + nameLen)])
      i += nameLen
      guard i < bytes.count, bytes[i] == 0 else {
        throw GitIndexError.indexCorrupt("missing path nul")
      }
      i += 1
      guard let path = String(bytes: nameBytes, encoding: .utf8) else {
        throw GitIndexError.indexCorrupt("bad utf-8 path")
      }
      let pad = Self.nulPadding(entryStart: entryStart, offsetAfterNul: i)
      guard i + pad <= bytes.count else { throw GitIndexError.indexCorrupt("truncated pad") }
      i += pad
      list.append(
        RawEntry(
          path: path,
          ctimeSec: ctimeSec,
          ctimeNSec: ctimeNsec,
          mtimeSec: mtimeSec,
          mtimeNSec: mtimeNsec,
          dev: dev,
          ino: ino,
          mode: mode,
          uid: uid,
          gid: gid,
          size: size,
          sha: sha
        ))
    }
    let checksumStart = bytes.count - 20
    guard checksumStart >= 12, i <= checksumStart else {
      throw GitIndexError.indexCorrupt("bad layout")
    }
    let prefix = Array(bytes[0..<checksumStart])
    let expected = Array(bytes[checksumStart..<bytes.count])
    let computed = GitSHA1.digest(of: prefix)
    guard computed == expected else { throw GitIndexError.indexChecksumMismatch }
    return list
  }

  private static func appendEntry(_ e: RawEntry, to out: inout [UInt8]) throws {
    let nameData = Array(e.path.utf8)
    guard nameData.count < 0x0fff else {
      throw GitIndexError.pathTooLongForIndex(e.path)
    }
    let entryStartOffset = out.count
    out.append(contentsOf: Self.u32be(e.ctimeSec))
    out.append(contentsOf: Self.u32be(e.ctimeNSec))
    out.append(contentsOf: Self.u32be(e.mtimeSec))
    out.append(contentsOf: Self.u32be(e.mtimeNSec))
    out.append(contentsOf: Self.u32be(e.dev))
    out.append(contentsOf: Self.u32be(e.ino))
    out.append(contentsOf: Self.u32be(e.mode))
    out.append(contentsOf: Self.u32be(e.uid))
    out.append(contentsOf: Self.u32be(e.gid))
    out.append(contentsOf: Self.u32be(e.size))
    guard e.sha.count == 20 else { throw GitIndexError.indexCorrupt("bad sha length") }
    out.append(contentsOf: e.sha)
    let flags = UInt16(nameData.count)
    out.append(contentsOf: Self.u16be(flags))
    out.append(contentsOf: nameData)
    out.append(0)
    let pad = Self.nulPadding(entryStart: entryStartOffset, offsetAfterNul: out.count)
    out.append(contentsOf: repeatElement(0, count: pad))
  }

  /// Pad with NULs so the total on-disk entry length is a multiple of 8 (Git index v2/v3).
  private static func nulPadding(entryStart: Int, offsetAfterNul: Int) -> Int {
    let consumed = offsetAfterNul - entryStart
    return (8 - (consumed % 8)) % 8
  }

  private static func treeModeString(statMode: UInt32) -> String {
    let ifmt = statMode & 0o170000
    if ifmt == 0o040000 { return "040000" }
    if ifmt == 0o100000 || ifmt == 0 {
      let exec = (statMode & 0o111) != 0
      return exec ? "100755" : "100644"
    }
    if ifmt == 0o120000 { return "120000" }
    return "100644"
  }

  private static func buildTreeLevel(gitDir: URL, entries: [(String, UInt32, [UInt8])]) throws
    -> [UInt8]
  {
    var blobAtRoot: [String: (UInt32, [UInt8])] = [:]
    var dirChildren: [String: [(String, UInt32, [UInt8])]] = [:]
    for (path, mode, sha) in entries {
      if let slash = path.firstIndex(of: "/") {
        let dir = String(path[..<slash])
        let rest = String(path[path.index(after: slash)...])
        dirChildren[dir, default: []].append((rest, mode, sha))
      } else {
        if blobAtRoot[path] != nil { throw GitIndexError.duplicatePathInIndex(path) }
        blobAtRoot[path] = (mode, sha)
      }
    }
    let names = Set(blobAtRoot.keys).union(dirChildren.keys)
    for n in names {
      let b = blobAtRoot[n] != nil
      let d = dirChildren[n] != nil
      if b && d { throw GitIndexError.fileAndDirectoryConflict(n) }
    }
    var treeRows: [(mode: String, name: String, sha20: [UInt8])] = []
    for name in names.sorted() {
      if let (mode, sha) = blobAtRoot[name] {
        treeRows.append((mode: treeModeString(statMode: mode), name: name, sha20: sha))
      } else if let kids = dirChildren[name] {
        let subSha = try buildTreeLevel(gitDir: gitDir, entries: kids)
        treeRows.append((mode: "040000", name: name, sha20: subSha))
      }
    }
    return try GitLooseObjectWriter.writeTree(gitDir: gitDir, entries: treeRows)
  }
}
