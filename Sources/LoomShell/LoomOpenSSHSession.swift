//
//  LoomOpenSSHSession.swift
//  LoomShell
//
//  Created by Codex on 3/9/26.
//

import Foundation
import CryptoKit
@preconcurrency import NIOConcurrencyHelpers
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOSSH

/// Interactive OpenSSH-backed shell session used as a fallback when Loom-native transport is unavailable.
public actor LoomOpenSSHSession: LoomShellInteractiveSession {
    public nonisolated let events: AsyncStream<LoomShellEvent>

    private let emitter: LoomShellEventEmitter
    private let eventLoopGroup: EventLoopGroup
    private let rootChannel: Channel
    private let childChannel: Channel
    private var didClose = false

    private init(
        emitter: LoomShellEventEmitter,
        eventLoopGroup: EventLoopGroup,
        rootChannel: Channel,
        childChannel: Channel
    ) {
        self.emitter = emitter
        events = emitter.stream
        self.eventLoopGroup = eventLoopGroup
        self.rootChannel = rootChannel
        self.childChannel = childChannel
    }

    public static func connect(
        endpoint: LoomBootstrapEndpoint,
        authentication: LoomShellSSHAuthentication,
        request: LoomShellSessionRequest,
        expectedHostKeyFingerprint: String?,
        timeout: Duration = .seconds(10)
    ) async throws -> LoomOpenSSHSession {
        let host = endpoint.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, endpoint.port > 0 else {
            throw LoomSSHBootstrapError.invalidEndpoint
        }

        let authDelegate = UncheckedSendableBox(
            try Self.makeUserAuthDelegate(authentication: authentication)
        )
        let serverAuthDelegate = UncheckedSendableBox(
            try LoomShellHostKeyValidationDelegate(
                expectedFingerprint: expectedHostKeyFingerprint
            )
        )
        let emitter = LoomShellEventEmitter()
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let connectTimeout = Self.timeAmount(from: timeout)

        do {
            let bootstrap = ClientBootstrap(group: eventLoopGroup)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let sshHandler = NIOSSHHandler(
                            role: .client(
                                .init(
                                    userAuthDelegate: authDelegate.value,
                                    serverAuthDelegate: serverAuthDelegate.value
                                )
                            ),
                            allocator: channel.allocator,
                            inboundChildChannelInitializer: nil
                        )
                        try channel.pipeline.syncOperations.addHandler(sshHandler)
                    }
                }
                .channelOption(ChannelOptions.connectTimeout, value: connectTimeout)
                .channelOption(ChannelOptions.socket(
                    SocketOptionLevel(SOL_SOCKET),
                    SO_REUSEADDR
                ), value: 1)
                .channelOption(ChannelOptions.socket(
                    SocketOptionLevel(IPPROTO_TCP),
                    TCP_NODELAY
                ), value: 1)

            let rootChannel = try await bootstrap.connect(host: host, port: Int(endpoint.port)).get()

            let readyPromise = rootChannel.eventLoop.makePromise(of: Void.self)
            let sessionHandler = LoomOpenSSHShellHandler(
                request: request,
                emitter: emitter,
                readyPromise: readyPromise
            )
            let childChannel = try await rootChannel.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler in
                let childPromise = rootChannel.eventLoop.makePromise(of: Channel.self)
                sshHandler.createChannel(childPromise, channelType: .session) { channel, channelType in
                    guard channelType == .session else {
                        return channel.eventLoop.makeFailedFuture(
                            LoomShellError.protocolViolation("Unexpected SSH channel type.")
                        )
                    }
                    return channel.pipeline.addHandler(sessionHandler)
                }
                return childPromise.futureResult
            }.get()

            try await readyPromise.futureResult.get()

            return LoomOpenSSHSession(
                emitter: emitter,
                eventLoopGroup: eventLoopGroup,
                rootChannel: rootChannel,
                childChannel: childChannel
            )
        } catch {
            emitter.finish()
            try? await Self.shutdownEventLoopGroup(eventLoopGroup)
            throw Self.mapToShellError(error)
        }
    }

    public func sendStdin(_ data: Data) async throws {
        guard !didClose else {
            throw LoomShellError.protocolViolation("OpenSSH shell session is already closed.")
        }

        var buffer = childChannel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await childChannel.writeAndFlush(
            SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        ).get()
    }

    public func resize(_ event: LoomShellResizeEvent) async throws {
        guard !didClose else {
            throw LoomShellError.protocolViolation("OpenSSH shell session is already closed.")
        }

        let request = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: event.columns,
            terminalRowHeight: event.rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )
        try await childChannel.triggerUserOutboundEvent(request).get()
    }

    public func close() async {
        guard !didClose else { return }
        didClose = true

        _ = try? await childChannel.close(mode: .all).get()
        _ = try? await rootChannel.close(mode: .all).get()
        try? await Self.shutdownEventLoopGroup(eventLoopGroup)
        emitter.finish()
    }
}

private extension LoomOpenSSHSession {
    static func makeUserAuthDelegate(
        authentication: LoomShellSSHAuthentication
    ) throws -> any NIOSSHClientUserAuthenticationDelegate {
        let methods = try authentication.methods.map(Self.preparedAuthenticationMethod(from:))
        guard !methods.isEmpty else {
            throw LoomShellError.invalidSSHAuthentication
        }
        return LoomShellAuthenticationDelegate(
            username: authentication.username,
            methods: methods
        )
    }

    static func shutdownEventLoopGroup(_ group: EventLoopGroup) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            group.shutdownGracefully { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    static func timeAmount(from duration: Duration) -> TimeAmount {
        let components = duration.components
        let seconds = max(components.seconds, 0)
        let attoseconds = max(components.attoseconds, 0)
        let nanoseconds = (seconds * 1_000_000_000) + (attoseconds / 1_000_000_000)
        return .nanoseconds(Int64(clamping: nanoseconds))
    }

    static func mapToShellError(_ error: Error) -> Error {
        if let shellError = error as? LoomShellError {
            return shellError
        }
        if let bootstrapError = error as? LoomSSHBootstrapError {
            return bootstrapError
        }
        if let ioError = error as? IOError {
            return LoomShellError.remoteFailure(ioError.localizedDescription)
        }
        if let sshError = error as? NIOSSHError {
            return LoomShellError.remoteFailure(sshError.localizedDescription)
        }
        return LoomShellError.remoteFailure(error.localizedDescription)
    }

    static func preparedAuthenticationMethod(
        from method: LoomShellSSHAuthenticationMethod
    ) throws -> LoomShellPreparedAuthenticationMethod {
        switch method {
        case let .password(password):
            return .password(password)
        case let .privateKey(key):
            return .privateKey(try makePrivateKey(from: key))
        }
    }

    static func makePrivateKey(
        from key: LoomShellSSHPrivateKey
    ) throws -> NIOSSHPrivateKey {
        do {
            switch key {
            case let .ed25519(rawRepresentation):
                return NIOSSHPrivateKey(
                    ed25519Key: try Curve25519.Signing.PrivateKey(
                        rawRepresentation: rawRepresentation
                    )
                )
            case let .p256(rawRepresentation):
                return NIOSSHPrivateKey(
                    p256Key: try P256.Signing.PrivateKey(
                        rawRepresentation: rawRepresentation
                    )
                )
            case let .p384(rawRepresentation):
                return NIOSSHPrivateKey(
                    p384Key: try P384.Signing.PrivateKey(
                        rawRepresentation: rawRepresentation
                    )
                )
            case let .p521(rawRepresentation):
                return NIOSSHPrivateKey(
                    p521Key: try P521.Signing.PrivateKey(
                        rawRepresentation: rawRepresentation
                    )
                )
            }
        } catch {
            throw LoomShellError.invalidSSHPrivateKey(error.localizedDescription)
        }
    }
}

private final class LoomOpenSSHShellHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData

    private let request: LoomShellSessionRequest
    private let emitter: LoomShellEventEmitter
    private let readyPromise: EventLoopPromise<Void>
    private let lock = NIOLock()
    private var resolvedReadiness = false
    private var terminalEventEmitted = false

    init(
        request: LoomShellSessionRequest,
        emitter: LoomShellEventEmitter,
        readyPromise: EventLoopPromise<Void>
    ) {
        self.request = request
        self.emitter = emitter
        self.readyPromise = readyPromise
    }

    func channelActive(context: ChannelHandlerContext) {
        let contextBox = UncheckedSendableBox(context)
        var future = context.eventLoop.makeSucceededFuture(())
        for (name, value) in request.environment.sorted(by: { $0.key < $1.key }) {
            future = future.flatMap {
                contextBox.value.triggerUserOutboundEvent(
                    SSHChannelRequestEvent.EnvironmentRequest(
                        wantReply: false,
                        name: name,
                        value: value
                    )
                )
            }
        }

        future = future.flatMap {
            contextBox.value.triggerUserOutboundEvent(
                SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true,
                    term: self.request.terminalType,
                    terminalCharacterWidth: self.request.columns,
                    terminalRowHeight: self.request.rows,
                    terminalPixelWidth: 0,
                    terminalPixelHeight: 0,
                    terminalModes: .init([:])
                )
            )
        }

        future = future.flatMap {
            if let command = self.request.command?.trimmingCharacters(in: .whitespacesAndNewlines),
               !command.isEmpty {
                return contextBox.value.triggerUserOutboundEvent(
                    SSHChannelRequestEvent.ExecRequest(
                        command: command,
                        wantReply: true
                    )
                )
            }
            return contextBox.value.triggerUserOutboundEvent(
                SSHChannelRequestEvent.ShellRequest(wantReply: true)
            )
        }

        future.whenComplete { result in
            switch result {
            case .success:
                self.resolveReadiness()
                self.emitter.yield(.ready(.init(mergesStandardError: false)))
            case let .failure(error):
                self.fail(
                    with: LoomShellError.remoteFailure(
                        "SSH shell setup failed: \(error.localizedDescription)"
                    ),
                    context: contextBox.value
                )
            }
        }

        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        switch payload.type {
        case .channel:
            emit(payload.data, as: LoomShellEvent.stdout)
        case .stdErr:
            emit(payload.data, as: LoomShellEvent.stderr)
        default:
            break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let exitStatus as SSHChannelRequestEvent.ExitStatus:
            emitTerminalEvent(.exit(.init(exitCode: Int32(exitStatus.exitStatus))))
            context.close(promise: nil)
        case let exitSignal as SSHChannelRequestEvent.ExitSignal:
            emitTerminalEvent(.failure("SSH remote exited with signal \(exitSignal.signalName)."))
            context.close(promise: nil)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        lock.withLock {
            if !terminalEventEmitted {
                emitter.yield(.failure("SSH channel closed."))
            }
        }
        emitter.finish()
        resolveReadiness(error: LoomShellError.remoteFailure("SSH channel closed before becoming ready."))
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(with: LoomShellError.remoteFailure(error.localizedDescription), context: context)
    }

    private func emitTerminalEvent(_ event: LoomShellEvent) {
        lock.withLock {
            terminalEventEmitted = true
        }
        emitter.yield(event)
    }

    private func emit(_ ioData: IOData, as builder: (Data) -> LoomShellEvent) {
        switch ioData {
        case var .byteBuffer(buffer):
            let data = buffer.readData(length: buffer.readableBytes) ?? Data()
            guard !data.isEmpty else { return }
            emitter.yield(builder(data))
        case .fileRegion:
            break
        }
    }

    private func fail(with error: Error, context: ChannelHandlerContext) {
        emitter.yield(.failure(error.localizedDescription))
        emitter.finish()
        resolveReadiness(error: error)
        context.close(promise: nil)
    }

    private func resolveReadiness(error: Error? = nil) {
        lock.withLock {
            guard !resolvedReadiness else { return }
            resolvedReadiness = true
            if let error {
                readyPromise.fail(error)
            } else {
                readyPromise.succeed(())
            }
        }
    }
}

private final class LoomShellHostKeyValidationDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let expectedFingerprint: String?

    init(expectedFingerprint: String?) throws {
        self.expectedFingerprint = try Self.normalizedFingerprint(expectedFingerprint)
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        do {
            guard let expectedFingerprint else {
                validationCompletePromise.succeed(())
                return
            }

            let receivedFingerprint = try Self.fingerprint(for: hostKey)
            guard receivedFingerprint == expectedFingerprint else {
                throw LoomShellError.remoteFailure(
                    "SSH host key fingerprint mismatch (expected \(expectedFingerprint), got \(receivedFingerprint))."
                )
            }
            validationCompletePromise.succeed(())
        } catch {
            validationCompletePromise.fail(error)
        }
    }

    private static func normalizedFingerprint(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LoomShellError.missingSSHHostKeyFingerprint
        }
        if trimmed.uppercased().hasPrefix("SHA256:") {
            return "SHA256:\(trimmed.dropFirst("SHA256:".count))"
        }
        return "SHA256:\(trimmed)"
    }

    private static func fingerprint(for hostKey: NIOSSHPublicKey) throws -> String {
        let openSSH = String(openSSHPublicKey: hostKey)
        let components = openSSH.split(separator: " ")
        guard components.count >= 2,
              let keyData = Data(base64Encoded: String(components[1])) else {
            throw LoomShellError.remoteFailure("Failed to derive SSH host key fingerprint.")
        }

        let digest = SHA256.hash(data: keyData)
        return "SHA256:\(Data(digest).base64EncodedString())"
    }
}

private enum LoomShellPreparedAuthenticationMethod: Sendable {
    case password(String)
    case privateKey(NIOSSHPrivateKey)
}

private final class LoomShellAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private var remainingMethods: [LoomShellPreparedAuthenticationMethod]
    private let lock = NIOLock()

    init(username: String, methods: [LoomShellPreparedAuthenticationMethod]) {
        self.username = username
        remainingMethods = methods
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard let offer = lock.withLock({
            nextOffer(availableMethods: availableMethods)
        }) else {
            nextChallengePromise.fail(LoomSSHBootstrapError.authenticationFailed)
            return
        }
        nextChallengePromise.succeed(offer)
    }

    private func nextOffer(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods
    ) -> NIOSSHUserAuthenticationOffer? {
        guard let nextIndex = remainingMethods.firstIndex(where: {
            Self.canOffer($0, with: availableMethods)
        }) else {
            return nil
        }

        let method = remainingMethods.remove(at: nextIndex)
        return NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "ssh-connection",
            offer: Self.offer(for: method)
        )
    }

    private static func canOffer(
        _ method: LoomShellPreparedAuthenticationMethod,
        with availableMethods: NIOSSHAvailableUserAuthenticationMethods
    ) -> Bool {
        switch method {
        case .password:
            availableMethods.contains(.password)
        case .privateKey:
            availableMethods.contains(.publicKey)
        }
    }

    private static func offer(
        for method: LoomShellPreparedAuthenticationMethod
    ) -> NIOSSHUserAuthenticationOffer.Offer {
        switch method {
        case let .password(password):
            .password(.init(password: password))
        case let .privateKey(privateKey):
            .privateKey(.init(privateKey: privateKey))
        }
    }
}

private final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
