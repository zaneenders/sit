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
/// ed25519 key from ~/.ssh/id_ed25519, and exchanges pkt-line frames.
///
/// Push uses one session (advertisement + pack in the same channel).
/// Fetch uses one session (upload-pack).
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

  /// Push ref updates and a packfile to the remote in a single SSH session.
  ///
  /// - Parameter buildPayload: Called with the server's ref advertisement.
  ///   Return the full pkt-line-encoded push request (commands + flush + packdata),
  ///   or throw `NothingToPush` to abort cleanly.
  static func push(
    ssh: SSHURL,
    buildPayload: @Sendable @escaping (GitSmartHTTP.RefAdvertisement) throws -> [UInt8]
  ) async throws -> [String] {
    let key = try loadSSHKey()
    let command = "git-receive-pack '\(ssh.path)'"
    let statusBytes = try await executePushCommand(
      host: ssh.host, port: 22, user: ssh.user,
      privateKey: key, command: command, buildPayload: buildPayload)
    return parsePushStatus(statusBytes)
  }

  /// Build the serialized push request: pkt-line ref-update commands, a flush,
  /// and the raw packfile.  Shared between SSH and HTTP transports.
  static func encodePushRequest(
    refUpdates: [(oldSha40: String, newSha40: String, refName: String)],
    packData: [UInt8],
    capabilities: Set<String>
  ) -> [UInt8] {
    let capStr = capabilities.filter {
      ["report-status", "delete-refs"].contains($0)
    }.joined(separator: " ")

    var payload: [UInt8] = []
    for (old, new, ref) in refUpdates {
      let line =
        capStr.isEmpty
        ? "\(old) \(new) \(ref)\n"
        : "\(old) \(new) \(ref)\0\(capStr)\n"
      payload.append(contentsOf: GitPktLine.encode(Array(line.utf8)))
    }
    payload.append(contentsOf: GitPktLine.flush)
    payload.append(contentsOf: packData)
    return payload
  }

  // MARK: - Core: run a git service (fetch / upload-pack)

  private static func run(ssh: SSHURL, service: String, input: [UInt8]) async throws -> [UInt8] {
    let key = try loadSSHKey()
    let command = "\(service) '\(ssh.path)'"
    return try await executeCommand(
      host: ssh.host, port: 22, user: ssh.user,
      privateKey: key, command: command, inputBytes: input)
  }

  // MARK: - Execute: simple (write-all then read-all)

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
            serverAuthDelegate: KnownHostsDelegate(host: host)
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

    let resultFuture: EventLoopFuture<[UInt8]> = try await channel.eventLoop.submit {
      let sshHandler = try channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
      let childPromise = channel.eventLoop.makePromise(of: Channel.self)
      let resultPromise = channel.eventLoop.makePromise(of: [UInt8].self)

      sshHandler.createChannel(childPromise) { childChannel, channelType in
        guard channelType == .session else {
          return childChannel.eventLoop.makeFailedFuture(GitSSHError.invalidChannelType)
        }
        return childChannel.eventLoop.makeCompletedFuture {
          try childChannel.pipeline.syncOperations.addHandler(
            GitCommandHandler(
              command: command,
              inputBytes: inputBytes,
              resultPromise: resultPromise))
        }
      }

      return childPromise.futureResult.flatMap { _ in resultPromise.futureResult }
    }.get()

    let bytes = try await resultFuture.get()
    try? await channel.close().get()
    return bytes
  }

  // MARK: - Execute: bidirectional push (advertisement → payload → status)

  private static func executePushCommand(
    host: String, port: Int, user: String,
    privateKey: NIOSSHPrivateKey, command: String,
    buildPayload: @Sendable @escaping (GitSmartHTTP.RefAdvertisement) throws -> [UInt8]
  ) async throws -> [UInt8] {
    let group = MultiThreadedEventLoopGroup.singleton

    let bootstrap = ClientBootstrap(group: group)
      .channelInitializer { channel in
        channel.eventLoop.makeCompletedFuture {
          let sshConfig = SSHClientConfiguration(
            userAuthDelegate: KeyAuthDelegate(username: user, key: privateKey),
            serverAuthDelegate: KnownHostsDelegate(host: host)
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

    let resultFuture: EventLoopFuture<[UInt8]> = try await channel.eventLoop.submit {
      let sshHandler = try channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
      let childPromise = channel.eventLoop.makePromise(of: Channel.self)
      let resultPromise = channel.eventLoop.makePromise(of: [UInt8].self)

      sshHandler.createChannel(childPromise) { childChannel, channelType in
        guard channelType == .session else {
          return childChannel.eventLoop.makeFailedFuture(GitSSHError.invalidChannelType)
        }
        return childChannel.eventLoop.makeCompletedFuture {
          try childChannel.pipeline.syncOperations.addHandler(
            GitPushSessionHandler(
              command: command,
              buildPayload: buildPayload,
              resultPromise: resultPromise))
        }
      }

      return childPromise.futureResult.flatMap { _ in resultPromise.futureResult }
    }.get()

    let bytes = try await resultFuture.get()
    try? await channel.close().get()
    return bytes
  }

  // MARK: - SSH key loading

  private static func loadSSHKey() throws -> NIOSSHPrivateKey {
    let sshDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
    let path = sshDir.appendingPathComponent("id_ed25519")
    guard FileManager.default.fileExists(atPath: path.path),
      let pem = try? String(contentsOf: path, encoding: .utf8)
    else { throw GitSSHError.noSSHKeyFound }
    let key = try parseEd25519Key(pem)
    return NIOSSHPrivateKey(ed25519Key: key)
  }

  /// Parse an unencrypted OpenSSH ed25519 private key file.
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

    // Magic: "openssh-key-v1\0" (15 bytes including null terminator)
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

  /// Parse the server's push status response (after the ref advertisement flush).
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

  // MARK: - pkt-line helpers

  /// Return the byte offset right after the first flush packet in `bytes`,
  /// or `nil` if a complete flush hasn't arrived yet.
  static func findFlushEnd(in bytes: [UInt8]) -> Int? {
    var pos = 0
    while pos < bytes.count {
      guard let (packet, consumed) = GitPktLine.decodeOne(from: bytes, at: pos) else {
        return nil
      }
      pos += consumed
      if case .flush = packet { return pos }
    }
    return nil
  }
}

// MARK: - Simple command handler (fetch / upload-pack)

/// Executes a remote command over an SSH session channel.
/// Writes `inputBytes` to stdin, closes write half, collects all stdout.
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

// MARK: - Bidirectional push handler

/// Runs git-receive-pack in a single SSH channel.
///
/// Phase 1 — advertisement: accumulates bytes until the first flush packet.
/// Phase 2 — push: calls `buildPayload` with the parsed advertisement,
///   writes the result to stdin, closes the write half, then accumulates
///   the status response.
///
/// All shared mutable state is guarded by `Mutex` for Sendable conformance.
final class GitPushSessionHandler: ChannelDuplexHandler, Sendable {
  typealias InboundIn = SSHChannelData
  typealias InboundOut = Never
  typealias OutboundIn = Never
  typealias OutboundOut = SSHChannelData

  private let command: String
  private let buildPayload: @Sendable (GitSmartHTTP.RefAdvertisement) throws -> [UInt8]
  private let resultPromise: EventLoopPromise<[UInt8]>

  private struct State: Sendable {
    var advertBytes: [UInt8] = []
    var statusBytes: [UInt8] = []
    var sentPush: Bool = false
    var exitCode: Int? = nil
    var promiseFulfilled: Bool = false
  }
  private let state: Mutex<State>

  init(
    command: String,
    buildPayload: @Sendable @escaping (GitSmartHTTP.RefAdvertisement) throws -> [UInt8],
    resultPromise: EventLoopPromise<[UInt8]>
  ) {
    self.command = command
    self.buildPayload = buildPayload
    self.resultPromise = resultPromise
    self.state = Mutex(State())
  }

  func channelActive(context: ChannelHandlerContext) {
    let channel = context.channel
    channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
      .flatMap { [command] _ in
        channel.triggerUserOutboundEvent(
          SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true))
      }
      .whenFailure { [weak self] error in
        self?.fulfill(.failure(error))
      }
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let sshData = unwrapInboundIn(data)
    guard case .channel = sshData.type, case .byteBuffer(let buf) = sshData.data else { return }
    let newBytes = Array(buf.readableBytesView)

    // Determine whether this chunk crosses the advertisement/status boundary.
    enum Transition { case none, send([UInt8]) }

    let transition = state.withLock { s -> Transition in
      if s.sentPush {
        s.statusBytes.append(contentsOf: newBytes)
        return .none
      }
      s.advertBytes.append(contentsOf: newBytes)
      guard let flushEnd = GitSSHTransport.findFlushEnd(in: s.advertBytes) else {
        return .none
      }
      // Bytes after the flush belong to the status response (rare but possible).
      let advert = Array(s.advertBytes[0..<flushEnd])
      s.statusBytes.append(contentsOf: s.advertBytes[flushEnd...])
      s.advertBytes = []
      s.sentPush = true
      return .send(advert)
    }

    if case .send(let advertBytes) = transition {
      let channel = context.channel
      let advert = GitSmartHTTP.parseRefAdvertisement(advertBytes)
      do {
        let payload = try buildPayload(advert)
        let outBuf = channel.allocator.buffer(bytes: payload)
        let outData = SSHChannelData(type: .channel, data: .byteBuffer(outBuf))
        channel.writeAndFlush(outData)
          .flatMap { _ in channel.close(mode: .output) }
          .whenFailure { [weak self] error in self?.fulfill(.failure(error)) }
      } catch {
        fulfill(.failure(error))
        channel.close(mode: .output, promise: nil)
      }
    }
  }

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    if let exit = event as? SSHChannelRequestEvent.ExitStatus {
      state.withLock { $0.exitCode = exit.exitStatus }
    }
    context.fireUserInboundEventTriggered(event)
  }

  func channelInactive(context: ChannelHandlerContext) {
    let s = state.withLock { $0 }
    if let code = s.exitCode, code != 0 {
      fulfill(.failure(GitSSHError.commandFailed(exitCode: Int32(code))))
    } else {
      fulfill(.success(s.statusBytes))
    }
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    fulfill(.failure(error))
    context.close(promise: nil)
  }

  private func fulfill(_ result: Result<[UInt8], Error>) {
    let shouldFulfill = state.withLock { s -> Bool in
      guard !s.promiseFulfilled else { return false }
      s.promiseFulfilled = true
      return true
    }
    guard shouldFulfill else { return }
    switch result {
    case .success(let bytes): resultPromise.succeed(bytes)
    case .failure(let error): resultPromise.fail(error)
    }
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

// MARK: - Known-hosts host key verification

/// Validates SSH server host keys against `~/.ssh/known_hosts`.
///
/// - If a matching key is found: accept.
/// - If entries exist for the host but none match: reject (potential MITM).
/// - If no entries exist for the host: TOFU — print a warning, accept, and
///   append the key to `~/.ssh/known_hosts`.
final class KnownHostsDelegate: NIOSSHClientServerAuthenticationDelegate, Sendable {
  private let host: String

  init(host: String) {
    self.host = host
  }

  func validateHostKey(
    hostKey: NIOSSHPublicKey,
    validationCompletePromise: EventLoopPromise<Void>
  ) {
    let knownHostsURL = URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent(".ssh/known_hosts")
    let text = (try? String(contentsOf: knownHostsURL, encoding: .utf8)) ?? ""
    let knownKeys = parseKnownHosts(text: text, host: host)

    if knownKeys.isEmpty {
      let keyType = serializedKeyType(hostKey)
      let msg =
        "Warning: permanently added '\(host)' (\(keyType)) to the list of known hosts.\n"
      try? FileHandle.standardError.write(contentsOf: Data(msg.utf8))
      appendToKnownHosts(url: knownHostsURL, host: host, key: hostKey)
      validationCompletePromise.succeed(())
    } else if knownKeys.contains(hostKey) {
      validationCompletePromise.succeed(())
    } else {
      let fp = fingerprint(of: hostKey)
      let msg = """
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!
        Host key for '\(host)' has changed.
        Offending key fingerprint: \(fp)
        Remove the old entry from ~/.ssh/known_hosts and retry.

        """
      try? FileHandle.standardError.write(contentsOf: Data(msg.utf8))
      validationCompletePromise.fail(GitSSHError.hostKeyMismatch(host: host))
    }
  }

  /// Parse known_hosts lines that match `host` and return their public keys.
  /// Skips hashed entries (`|1|…`) and comment lines.
  private func parseKnownHosts(text: String, host: String) -> [NIOSSHPublicKey] {
    var keys: [NIOSSHPublicKey] = []
    for raw in text.split(separator: "\n") {
      let line = String(raw).trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("|") else { continue }
      // Format: "patterns keytype base64key [comment]"
      let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
      guard parts.count >= 3 else { continue }
      let patterns = String(parts[0])
      let keyEntry = "\(parts[1]) \(parts[2])"
      for pattern in patterns.split(separator: ",") {
        if String(pattern) == host {
          if let key = try? NIOSSHPublicKey(openSSHPublicKey: keyEntry) {
            keys.append(key)
          }
          break
        }
      }
    }
    return keys
  }

  private func appendToKnownHosts(url: URL, host: String, key: NIOSSHPublicKey) {
    let line = "\(host) \(String(openSSHPublicKey: key))\n"
    guard let data = line.data(using: .utf8) else { return }
    if FileManager.default.fileExists(atPath: url.path),
      let fh = FileHandle(forWritingAtPath: url.path)
    {
      defer { fh.closeFile() }
      fh.seekToEndOfFile()
      fh.write(data)
    } else {
      try? data.write(to: url, options: .atomic)
    }
  }

  private func fingerprint(of key: NIOSSHPublicKey) -> String {
    let s = String(openSSHPublicKey: key)
    let parts = s.split(separator: " ")
    guard parts.count >= 2, let raw = Data(base64Encoded: String(parts[1])) else {
      return "<unknown>"
    }
    let digest = SHA256.hash(data: raw)
    // Standard SSH fingerprint: SHA256:<base64-without-padding>
    let b64 = Data(digest).base64EncodedString().trimmingCharacters(
      in: CharacterSet(charactersIn: "="))
    return "SHA256:\(b64)"
  }

  private func serializedKeyType(_ key: NIOSSHPublicKey) -> String {
    String(openSSHPublicKey: key).split(separator: " ").first.map(String.init) ?? "unknown"
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
  case hostKeyMismatch(host: String)
}
