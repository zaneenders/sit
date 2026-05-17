import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Sit
import Synchronization

/// Git smart protocol over SSH using swift-nio-ssh.
///
/// Opens a single TCP connection per operation, authenticates with the user's
/// ed25519 key from ~/.ssh/id_ed25519, runs git-upload-pack / git-receive-pack
/// in a session channel, and exchanges pkt-line frames over that channel.
enum GitSSHTransport {

  struct SSHURL: Equatable {
    let host: String
    let user: String
    let path: String
  }

  /// Parse `git@github.com:user/repo.git` or `ssh://git@github.com/user/repo.git`.
  static func parseSSHURL(_ url: String) -> SSHURL? {
    if url.hasPrefix("ssh://") {
      let rest = String(url.dropFirst(6))
      let parts = rest.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
      guard parts.count >= 1 else { return nil }
      let hostUser = parts[0]
      let path = parts.count >= 2 ? String(parts[1...].joined(separator: "/")) : ""
      let huParts = hostUser.split(separator: "@", maxSplits: 1)
      if huParts.count == 2 {
        return SSHURL(host: String(huParts[1]), user: String(huParts[0]), path: path)
      } else {
        return SSHURL(host: String(huParts[0]), user: "git", path: path)
      }
    }
    if url.hasPrefix("git@") {
      let rest = String(url.dropFirst(4))
      let parts = rest.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else { return nil }
      return SSHURL(host: String(parts[0]), user: "git", path: String(parts[1]))
    }
    return nil
  }

  // MARK: - Git protocol operations

  /// Read the ref advertisement for push (git-receive-pack).
  static func advertiseRefs(ssh: SSHURL) async throws -> GitSmartHTTP.RefAdvertisement {
    let bytes = try await run(ssh: ssh, service: "git-receive-pack", input: [])
    return GitSmartHTTP.parseRefAdvertisement(bytes)
  }

  /// Read the ref advertisement for fetch (git-upload-pack).
  static func advertiseFetchRefs(ssh: SSHURL) async throws -> GitSmartHTTP.RefAdvertisement {
    let bytes = try await run(ssh: ssh, service: "git-upload-pack", input: [])
    return GitSmartHTTP.parseRefAdvertisement(bytes)
  }

  /// Fetch a packfile from the remote.
  static func fetch(
    ssh: SSHURL,
    wantHashes: [String],
    haveHashes: [String] = [],
    capabilities: Set<String> = []
  ) async throws -> [UInt8] {
    let supportedCaps = capabilities.filter {
      ["multi_ack", "multi_ack_detailed", "thin-pack", "ofs-delta"].contains($0)
    }

    var request: [UInt8] = []
    var firstWant = true
    for sha in wantHashes {
      let line: String
      if firstWant && !supportedCaps.isEmpty {
        line = "want \(sha) \(supportedCaps.joined(separator: " "))\n"
        firstWant = false
      } else {
        line = "want \(sha)\n"
      }
      request.append(contentsOf: GitPktLine.encode(Array(line.utf8)))
    }
    for sha in haveHashes {
      request.append(contentsOf: GitPktLine.encode(Array("have \(sha)\n".utf8)))
    }
    request.append(contentsOf: GitPktLine.encode("done\n"))
    request.append(contentsOf: GitPktLine.flush)

    let responseBytes = try await run(ssh: ssh, service: "git-upload-pack", input: request)
    return GitSmartHTTP.parseFetchResponse(responseBytes)
  }

  /// Push ref updates and a packfile to the remote.
  static func push(
    ssh: SSHURL,
    refUpdates: [(oldSha40: String, newSha40: String, refName: String)],
    packData: [UInt8],
    capabilities: Set<String> = []
  ) async throws -> [String] {
    // Omit side-band-64k: we parse plain pkt-line status only.
    let capStr = capabilities.filter {
      ["report-status", "delete-refs"].contains($0)
    }.joined(separator: " ")

    var request: [UInt8] = []
    for (old, new, ref) in refUpdates {
      let line =
        capStr.isEmpty
        ? "\(old) \(new) \(ref)\n"
        : "\(old) \(new) \(ref)\0\(capStr)\n"
      request.append(contentsOf: GitPktLine.encode(Array(line.utf8)))
    }
    request.append(contentsOf: GitPktLine.flush)
    request.append(contentsOf: packData)

    let responseBytes = try await run(ssh: ssh, service: "git-receive-pack", input: request)
    return parsePushStatus(responseBytes)
  }

  // MARK: - Core: run a git service over SSH

  /// Open an SSH connection, exec `<service> '<path>'`, write `input` to stdin,
  /// close stdin, and return all stdout bytes.
  private static func run(ssh: SSHURL, service: String, input: [UInt8]) async throws -> [UInt8] {
    let key = try loadSSHKey()
    let command = "\(service) '\(ssh.path)'"
    return try await executeCommand(
      host: ssh.host, port: 22, user: ssh.user,
      privateKey: key, command: command, inputBytes: input)
  }

  private static func executeCommand(
    host: String, port: Int, user: String,
    privateKey: NIOSSHPrivateKey, command: String, inputBytes: [UInt8]
  ) async throws -> [UInt8] {
    let group = MultiThreadedEventLoopGroup.singleton

    let bootstrap = ClientBootstrap(group: group)
      .channelInitializer { channel in
        channel.eventLoop.makeCompletedFuture {
          let sshConfig = SSHClientConfiguration(
            userAuthDelegate: KeyAuthDelegate(username: user, key: privateKey),
            serverAuthDelegate: AcceptAnyHostKey()
          )
          let handler = NIOSSHHandler(
            role: .client(sshConfig),
            allocator: channel.allocator,
            inboundChildChannelInitializer: nil
          )
          try channel.pipeline.syncOperations.addHandler(handler)
        }
      }
      .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
      .connectTimeout(.seconds(30))

    let channel = try await bootstrap.connect(host: host, port: port).get()

    // Submit all NIOSSHHandler work to the event loop to avoid
    // crossing async boundaries with non-Sendable NIOSSHHandler.
    let resultFuture: EventLoopFuture<[UInt8]> = try await channel.eventLoop.submit {
      let sshHandler = try channel.pipeline.syncOperations.handler(
        type: NIOSSHHandler.self)
      let childPromise = channel.eventLoop.makePromise(of: Channel.self)
      let resultPromise = channel.eventLoop.makePromise(of: [UInt8].self)

      sshHandler.createChannel(childPromise) { childChannel, channelType in
        guard channelType == .session else {
          return childChannel.eventLoop.makeFailedFuture(
            GitSSHError.invalidChannelType)
        }
        return childChannel.eventLoop.makeCompletedFuture {
          try childChannel.pipeline.syncOperations.addHandler(
            GitCommandHandler(
              command: command,
              inputBytes: inputBytes,
              resultPromise: resultPromise)
          )
        }
      }

      return childPromise.futureResult.flatMap { _ in
        resultPromise.futureResult
      }
    }.get()

    let bytes = try await resultFuture.get()
    try? await channel.close().get()
    return bytes
  }

  // MARK: - SSH key loading

  /// Load the first available unencrypted ed25519 key from ~/.ssh/.
  private static func loadSSHKey() throws -> NIOSSHPrivateKey {
    let sshDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
    for name in ["id_ed25519"] {
      let path = sshDir.appendingPathComponent(name)
      guard FileManager.default.fileExists(atPath: path.path),
        let pem = try? String(contentsOf: path, encoding: .utf8)
      else { continue }
      if let key = try? parseEd25519Key(pem) {
        return NIOSSHPrivateKey(ed25519Key: key)
      }
    }
    throw GitSSHError.noSSHKeyFound
  }

  /// Parse an unencrypted OpenSSH ed25519 private key file and return the raw key.
  private static func parseEd25519Key(_ pem: String) throws -> Curve25519.Signing.PrivateKey {
    let b64 = pem.components(separatedBy: .newlines)
      .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
      .joined()
    guard let data = Data(base64Encoded: b64) else {
      throw GitSSHError.keyParseError("invalid base64")
    }

    let bytes = Array(data)
    var pos = 0

    func readExact(_ n: Int) throws -> [UInt8] {
      guard pos + n <= bytes.count else {
        throw GitSSHError.keyParseError("unexpected end of data at pos \(pos)")
      }
      defer { pos += n }
      return Array(bytes[pos..<(pos + n)])
    }

    func readUInt32() throws -> Int {
      let b = try readExact(4)
      return Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
    }

    func readString() throws -> [UInt8] {
      let len = try readUInt32()
      return try readExact(len)
    }

    // Magic: "openssh-key-v1\0" (15 bytes)
    let magic = try readExact(15)
    guard String(bytes: magic, encoding: .ascii) == "openssh-key-v1\0" else {
      throw GitSSHError.keyParseError("not an OpenSSH private key")
    }

    let cipherBytes = try readString()
    guard String(bytes: cipherBytes, encoding: .utf8) == "none" else {
      throw GitSSHError.keyEncrypted
    }
    _ = try readString()  // kdf name
    _ = try readString()  // kdf options

    let numKeys = try readUInt32()
    guard numKeys == 1 else {
      throw GitSSHError.keyParseError("expected 1 key, got \(numKeys)")
    }

    _ = try readString()  // public key blob

    let privateBlock = try readString()
    let pb = privateBlock
    var pbPos = 0

    func readPBExact(_ n: Int) throws -> [UInt8] {
      guard pbPos + n <= pb.count else {
        throw GitSSHError.keyParseError("private block truncated")
      }
      defer { pbPos += n }
      return Array(pb[pbPos..<(pbPos + n)])
    }

    func readPBUInt32() throws -> Int {
      let b = try readPBExact(4)
      return Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
    }

    func readPBString() throws -> [UInt8] {
      let len = try readPBUInt32()
      return try readPBExact(len)
    }

    let check1 = try readPBUInt32()
    let check2 = try readPBUInt32()
    guard check1 == check2 else {
      throw GitSSHError.keyParseError("checksum mismatch — key may be passphrase-protected")
    }

    let keyTypeBytes = try readPBString()
    guard String(bytes: keyTypeBytes, encoding: .utf8) == "ssh-ed25519" else {
      throw GitSSHError.keyParseError("expected ssh-ed25519 key type")
    }

    _ = try readPBString()  // public key (repeated)
    let privateAndPublic = try readPBString()  // 64 bytes: seed(32) + pubkey(32)
    guard privateAndPublic.count >= 32 else {
      throw GitSSHError.keyParseError("private key data too short")
    }

    return try Curve25519.Signing.PrivateKey(rawRepresentation: Data(privateAndPublic[0..<32]))
  }

  // MARK: - Push status parsing

  /// Parse the server's push status, skipping the ref advertisement that git-receive-pack
  /// sends before reading our commands (second SSH session re-runs the command).
  static func parsePushStatus(_ data: [UInt8]) -> [String] {
    var lines: [String] = []
    var pos = 0
    var pastFirstFlush = false
    while pos < data.count {
      guard let (packet, consumed) = GitPktLine.decodeOne(from: data, at: pos) else { break }
      pos += consumed
      switch packet {
      case .flush:
        pastFirstFlush = true
      case .data(let payload) where pastFirstFlush:
        if let str = String(bytes: payload, encoding: .utf8) {
          let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
          if !trimmed.isEmpty { lines.append(trimmed) }
        }
      default:
        break
      }
    }
    return lines
  }
}

// MARK: - NIO channel handler

/// Executes a remote command over an SSH session channel.
/// Writes `inputBytes` to stdin, closes write half, collects all stdout.
///
/// All mutable state is guarded by `Mutex` so the handler is
/// concurrency-safe without `@unchecked Sendable`.
final class GitCommandHandler: ChannelDuplexHandler, Sendable {
  typealias InboundIn = SSHChannelData
  typealias InboundOut = Never
  typealias OutboundIn = Never
  typealias OutboundOut = SSHChannelData

  private let command: String
  private let inputBytes: [UInt8]
  private let resultPromise: EventLoopPromise<[UInt8]>
  private let accumulator: Mutex<[UInt8]>
  private let exitCode: Mutex<Int?>

  init(command: String, inputBytes: [UInt8], resultPromise: EventLoopPromise<[UInt8]>) {
    self.command = command
    self.inputBytes = inputBytes
    self.resultPromise = resultPromise
    self.accumulator = Mutex([])
    self.exitCode = Mutex(nil)
  }

  func channelActive(context: ChannelHandlerContext) {
    let channel = context.channel
    let eventLoop = context.eventLoop

    channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
      .flatMap { [command] _ in
        channel.triggerUserOutboundEvent(
          SSHChannelRequestEvent.ExecRequest(command: command, wantReply: false))
      }
      .flatMap { [inputBytes] _ -> EventLoopFuture<Void> in
        guard !inputBytes.isEmpty else {
          return eventLoop.makeSucceededVoidFuture()
        }
        let buf = channel.allocator.buffer(bytes: inputBytes)
        let data = SSHChannelData(type: .channel, data: .byteBuffer(buf))
        return channel.writeAndFlush(data)
      }
      .flatMap { _ in
        channel.close(mode: .output)
      }
      .whenFailure { [resultPromise] error in
        resultPromise.fail(error)
      }
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let sshData = unwrapInboundIn(data)
    guard case .channel = sshData.type, case .byteBuffer(let buf) = sshData.data else { return }
    accumulator.withLock { $0.append(contentsOf: buf.readableBytesView) }
  }

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    if let exit = event as? SSHChannelRequestEvent.ExitStatus {
      exitCode.withLock { $0 = exit.exitStatus }
    }
    context.fireUserInboundEventTriggered(event)
  }

  func channelInactive(context: ChannelHandlerContext) {
    let code = exitCode.withLock { $0 }
    let acc = accumulator.withLock { $0 }
    if let code, code != 0 {
      resultPromise.fail(GitSSHError.commandFailed(exitCode: Int32(code)))
    } else {
      resultPromise.succeed(acc)
    }
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    resultPromise.fail(error)
    context.close(promise: nil)
  }
}

// MARK: - Auth delegates

final class KeyAuthDelegate: NIOSSHClientUserAuthenticationDelegate, Sendable {
  private let username: String
  private let key: NIOSSHPrivateKey
  private let offered: Mutex<Bool>

  init(username: String, key: NIOSSHPrivateKey) {
    self.username = username
    self.key = key
    self.offered = Mutex(false)
  }

  func nextAuthenticationType(
    availableMethods: NIOSSHAvailableUserAuthenticationMethods,
    nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
  ) {
    let alreadyOffered = offered.withLock { o -> Bool in
      if o { return true }
      o = true
      return false
    }
    guard !alreadyOffered, availableMethods.contains(.publicKey) else {
      nextChallengePromise.succeed(nil)
      return
    }
    nextChallengePromise.succeed(
      NIOSSHUserAuthenticationOffer(
        username: username,
        serviceName: "ssh-connection",
        offer: .privateKey(.init(privateKey: key))
      )
    )
  }
}

final class AcceptAnyHostKey: NIOSSHClientServerAuthenticationDelegate, Sendable {
  func validateHostKey(
    hostKey: NIOSSHPublicKey,
    validationCompletePromise: EventLoopPromise<Void>
  ) {
    let msg = "warning: SSH host key verification is not implemented — accepting all keys\n"
    try? FileHandle.standardError.write(contentsOf: Data(msg.utf8))
    validationCompletePromise.succeed(())
  }
}

// MARK: - Errors

enum GitSSHError: Error, Equatable {
  case noSSHKeyFound
  case keyEncrypted
  case keyParseError(String)
  case invalidChannelType
  case commandFailed(exitCode: Int32)
  case badSSHURL(String)
}
