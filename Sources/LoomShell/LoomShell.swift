//
//  LoomShell.swift
//  LoomShell
//
//  Created by Codex on 3/9/26.
//

@_exported import Foundation
@_exported import Loom

/// Outcome selected by shell transport fallback policy.
public enum LoomShellResolvedTransport: Sendable, Equatable {
    case loomNative
    case openSSH(endpoint: LoomBootstrapEndpoint, hostKeyFingerprint: String?)
}

/// Outcome of a single shell transport attempt.
public enum LoomShellConnectionAttemptOutcome: Sendable, Equatable {
    case succeeded
    case failed(String)
    case skipped(String)
}

/// Concrete Loom-native path that was attempted before optional SSH fallback.
public struct LoomShellDirectPath: Sendable, Equatable {
    public let source: LoomConnectionTargetSource
    public let transportKind: LoomTransportKind
    public let endpointDescription: String

    public init(
        source: LoomConnectionTargetSource,
        transportKind: LoomTransportKind,
        endpointDescription: String
    ) {
        self.source = source
        self.transportKind = transportKind
        self.endpointDescription = endpointDescription
    }
}

/// Human-readable record of a single connection attempt.
public struct LoomShellConnectionAttempt: Sendable, Equatable {
    public let transport: LoomShellResolvedTransport
    public let directPath: LoomShellDirectPath?
    public let outcome: LoomShellConnectionAttemptOutcome

    public init(
        transport: LoomShellResolvedTransport,
        directPath: LoomShellDirectPath?,
        outcome: LoomShellConnectionAttemptOutcome
    ) {
        self.transport = transport
        self.directPath = directPath
        self.outcome = outcome
    }
}

/// Full shell transport attempt report surfaced to app code for diagnostics and UI.
public struct LoomShellConnectionReport: Sendable, Equatable {
    public let attempts: [LoomShellConnectionAttempt]
    public let selectedTransport: LoomShellResolvedTransport?

    public init(
        attempts: [LoomShellConnectionAttempt],
        selectedTransport: LoomShellResolvedTransport?
    ) {
        self.attempts = attempts
        self.selectedTransport = selectedTransport
    }
}

/// Failure wrapper that preserves the full shell transport report.
public struct LoomShellConnectionFailure: LocalizedError, Sendable, Equatable {
    public let report: LoomShellConnectionReport
    public let underlyingMessage: String

    public init(report: LoomShellConnectionReport, underlyingMessage: String) {
        self.report = report
        self.underlyingMessage = underlyingMessage
    }

    public var errorDescription: String? {
        underlyingMessage
    }
}

/// Ordered fallback policy for apps that support both Loom-native and OpenSSH shell transports.
public struct LoomShellConnectionPlan: Sendable, Equatable {
    public let primary: LoomShellResolvedTransport
    public let fallbacks: [LoomShellResolvedTransport]

    public init(primary: LoomShellResolvedTransport, fallbacks: [LoomShellResolvedTransport]) {
        self.primary = primary
        self.fallbacks = fallbacks
    }

    public var orderedTransports: [LoomShellResolvedTransport] {
        [primary] + fallbacks
    }
}

/// Shared interactive shell contract used by both Loom-native and OpenSSH-backed sessions.
public protocol LoomShellInteractiveSession: Sendable {
    var events: AsyncStream<LoomShellEvent> { get }

    func sendStdin(_ data: Data) async throws
    func resize(_ event: LoomShellResizeEvent) async throws
    func close() async
}

/// SSH authentication methods offered to fallback OpenSSH transports.
public enum LoomShellSSHAuthenticationMethod: Sendable, Equatable {
    case password(String)
    case privateKey(LoomShellSSHPrivateKey)
}

/// App-owned private key material used for SSH public-key authentication.
public enum LoomShellSSHPrivateKey: Sendable, Equatable {
    case ed25519(rawRepresentation: Data)
    case p256(rawRepresentation: Data)
    case p384(rawRepresentation: Data)
    case p521(rawRepresentation: Data)
}

/// SSH authentication material accepted by ``LoomOpenSSHSession`` and ``LoomShellConnector``.
public struct LoomShellSSHAuthentication: Sendable, Equatable {
    public let username: String
    public let methods: [LoomShellSSHAuthenticationMethod]

    public init(username: String, methods: [LoomShellSSHAuthenticationMethod]) {
        self.username = username
        self.methods = methods
    }

    public static func password(username: String, password: String) -> LoomShellSSHAuthentication {
        LoomShellSSHAuthentication(
            username: username,
            methods: [.password(password)]
        )
    }

    public static func privateKey(
        username: String,
        key: LoomShellSSHPrivateKey
    ) -> LoomShellSSHAuthentication {
        LoomShellSSHAuthentication(
            username: username,
            methods: [.privateKey(key)]
        )
    }

    public func appendingMethod(
        _ method: LoomShellSSHAuthenticationMethod
    ) -> LoomShellSSHAuthentication {
        LoomShellSSHAuthentication(
            username: username,
            methods: methods + [method]
        )
    }
}

/// Host key verification policy for interactive SSH fallback sessions.
public enum LoomShellSSHHostKeyPolicy: Sendable, Equatable {
    /// Require the pinned fingerprint embedded in bootstrap metadata.
    case metadataRequired
    /// Require an explicit pinned fingerprint.
    case fingerprint(String)
    /// Skip host-key verification.
    case acceptAny
}

/// App-visible shell connection failure.
public enum LoomShellError: LocalizedError, Sendable, Equatable {
    case invalidConfiguration(String)
    case missingSSHAuthentication
    case invalidSSHAuthentication
    case missingSSHHostKeyFingerprint
    case invalidSSHPrivateKey(String)
    case remoteFailure(String)
    case protocolViolation(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(detail):
            "Shell configuration is invalid: \(detail)"
        case .missingSSHAuthentication:
            "OpenSSH fallback requires authentication material."
        case .invalidSSHAuthentication:
            "OpenSSH fallback requires at least one valid authentication method."
        case .missingSSHHostKeyFingerprint:
            "OpenSSH fallback requires a pinned host key fingerprint unless the caller explicitly opts out."
        case let .invalidSSHPrivateKey(detail):
            "OpenSSH private key is invalid: \(detail)"
        case let .remoteFailure(detail):
            "Remote shell failed: \(detail)"
        case let .protocolViolation(detail):
            "Shell protocol error: \(detail)"
        case let .unsupported(detail):
            "Shell transport is unsupported: \(detail)"
        }
    }
}

/// Successful shell connection result returned by the connector.
public struct LoomShellConnectionResult: Sendable {
    public let transport: LoomShellResolvedTransport
    public let session: any LoomShellInteractiveSession
    public let authenticatedSessionContext: LoomAuthenticatedSessionContext?
    public let report: LoomShellConnectionReport

    public init(
        transport: LoomShellResolvedTransport,
        session: any LoomShellInteractiveSession,
        authenticatedSessionContext: LoomAuthenticatedSessionContext? = nil,
        report: LoomShellConnectionReport
    ) {
        self.transport = transport
        self.session = session
        self.authenticatedSessionContext = authenticatedSessionContext
        self.report = report
    }
}

/// Resolves app-visible fallback order between Loom-native and OpenSSH shell sessions.
public enum LoomShellConnectionPlanner {
    public static func plan(
        peerCapabilities: LoomShellPeerCapabilities? = nil,
        bootstrapMetadata: LoomBootstrapMetadata?,
        preferLoomNative: Bool = true
    ) -> LoomShellConnectionPlan {
        let sshFallbacks = resolvedSSHFallbacks(from: bootstrapMetadata)
        if peerCapabilities?.supportsLoomNativeShell == false {
            let primary = sshFallbacks.first ?? .loomNative
            return LoomShellConnectionPlan(
                primary: primary,
                fallbacks: Array(sshFallbacks.dropFirst())
            )
        }
        if preferLoomNative {
            return LoomShellConnectionPlan(primary: .loomNative, fallbacks: sshFallbacks)
        }
        let primary = sshFallbacks.first ?? .loomNative
        let remainder = sshFallbacks.dropFirst()
        var fallbacks = Array(remainder)
        if primary != .loomNative {
            fallbacks.append(.loomNative)
        }
        return LoomShellConnectionPlan(primary: primary, fallbacks: fallbacks)
    }

    private static func resolvedSSHFallbacks(
        from bootstrapMetadata: LoomBootstrapMetadata?
    ) -> [LoomShellResolvedTransport] {
        guard let bootstrapMetadata,
              bootstrapMetadata.enabled else {
            return []
        }

        let endpoints = LoomBootstrapEndpointResolver.resolve(bootstrapMetadata.endpoints)
        return endpoints.map { endpoint in
            .openSSH(
                endpoint: endpoint,
                hostKeyFingerprint: bootstrapMetadata.sshHostKeyFingerprint
            )
        }
    }
}

/// High-level connector that prefers Loom-native shell sessions and falls back to OpenSSH when enabled.
@MainActor
public final class LoomShellConnector {
    private let connectionCoordinator: LoomConnectionCoordinator

    public init(node: LoomNode, relayClient: LoomRelayClient? = nil) {
        connectionCoordinator = LoomConnectionCoordinator(node: node, relayClient: relayClient)
    }

    public func connect(
        hello: LoomSessionHelloRequest,
        request: LoomShellSessionRequest,
        localPeer: LoomPeer? = nil,
        relaySessionID: String? = nil,
        peerCapabilities: LoomShellPeerCapabilities? = nil,
        bootstrapMetadata: LoomBootstrapMetadata? = nil,
        sshAuthentication: LoomShellSSHAuthentication? = nil,
        preferLoomNative: Bool = true,
        sshHostKeyPolicy: LoomShellSSHHostKeyPolicy = .metadataRequired,
        timeout: Duration = .seconds(10)
    ) async throws -> LoomShellConnectionResult {
        try await connect(
            using: LoomShellConnectionPlanner.plan(
                peerCapabilities: peerCapabilities,
                bootstrapMetadata: bootstrapMetadata,
                preferLoomNative: preferLoomNative
            ),
            hello: hello,
            request: request,
            localPeer: localPeer,
            relaySessionID: relaySessionID,
            peerCapabilities: peerCapabilities,
            bootstrapMetadata: bootstrapMetadata,
            sshAuthentication: sshAuthentication,
            sshHostKeyPolicy: sshHostKeyPolicy,
            timeout: timeout
        )
    }

    public func connect(
        to peer: LoomShellDiscoveredPeer,
        identity: LoomShellIdentity,
        request: LoomShellSessionRequest,
        relaySessionID: String? = nil,
        sshAuthentication: LoomShellSSHAuthentication? = nil,
        preferLoomNative: Bool = true,
        sshHostKeyPolicy: LoomShellSSHHostKeyPolicy = .metadataRequired,
        timeout: Duration = .seconds(10)
    ) async throws -> LoomShellConnectionResult {
        let hello = try identity.makeHelloRequest()
        return try await connect(
            hello: hello,
            request: request,
            localPeer: peer.peer,
            relaySessionID: relaySessionID,
            peerCapabilities: peer.capabilities,
            bootstrapMetadata: peer.bootstrapMetadata,
            sshAuthentication: sshAuthentication,
            preferLoomNative: preferLoomNative,
            sshHostKeyPolicy: sshHostKeyPolicy,
            timeout: timeout
        )
    }

    private func connect(
        using plan: LoomShellConnectionPlan,
        hello: LoomSessionHelloRequest,
        request: LoomShellSessionRequest,
        localPeer: LoomPeer?,
        relaySessionID: String?,
        peerCapabilities: LoomShellPeerCapabilities?,
        bootstrapMetadata: LoomBootstrapMetadata?,
        sshAuthentication: LoomShellSSHAuthentication?,
        sshHostKeyPolicy: LoomShellSSHHostKeyPolicy,
        timeout: Duration
    ) async throws -> LoomShellConnectionResult {
        var attempts: [LoomShellConnectionAttempt] = []
        var lastError: Error?
        for transport in plan.orderedTransports {
            do {
                switch transport {
                case .loomNative:
                    if peerCapabilities?.supportsLoomNativeShell == false {
                        attempts.append(
                            LoomShellConnectionAttempt(
                                transport: .loomNative,
                                directPath: nil,
                                outcome: .skipped("Peer does not advertise Loom-native shell support.")
                            )
                        )
                        continue
                    }

                    let nativePlan = try await connectionCoordinator.makePlan(
                        localPeer: localPeer,
                        relaySessionID: relaySessionID
                    )
                    if nativePlan.targets.isEmpty {
                        attempts.append(
                            LoomShellConnectionAttempt(
                                transport: .loomNative,
                                directPath: nil,
                                outcome: .failed("No direct Loom transport candidates were available.")
                            )
                        )
                        lastError = LoomError.sessionNotFound
                        continue
                    }

                    for target in nativePlan.targets {
                        let directPath = LoomShellDirectPath(
                            source: target.source,
                            transportKind: target.transportKind,
                            endpointDescription: target.endpoint.debugDescription
                        )
                        do {
                            let authenticatedSession = try await connectionCoordinator.connect(
                                to: target,
                                hello: hello
                            )
                            let shellSession = try await LoomNativeShellSession.open(
                                over: authenticatedSession,
                                request: request
                            )
                            attempts.append(
                                LoomShellConnectionAttempt(
                                    transport: .loomNative,
                                    directPath: directPath,
                                    outcome: .succeeded
                                )
                            )
                            let report = LoomShellConnectionReport(
                                attempts: attempts,
                                selectedTransport: .loomNative
                            )
                            return LoomShellConnectionResult(
                                transport: .loomNative,
                                session: shellSession,
                                authenticatedSessionContext: await authenticatedSession.context,
                                report: report
                            )
                        } catch {
                            attempts.append(
                                LoomShellConnectionAttempt(
                                    transport: .loomNative,
                                    directPath: directPath,
                                    outcome: .failed(error.localizedDescription)
                                )
                            )
                            lastError = error
                        }
                    }
                case let .openSSH(endpoint, metadataFingerprint):
                    guard let sshAuthentication else {
                        let error = LoomShellError.missingSSHAuthentication
                        attempts.append(
                            LoomShellConnectionAttempt(
                                transport: transport,
                                directPath: nil,
                                outcome: .skipped(error.localizedDescription)
                            )
                        )
                        lastError = error
                        continue
                    }
                    let validatedAuthentication = try validateSSHAuthentication(sshAuthentication)
                    let resolvedFingerprint = try resolveHostKeyFingerprint(
                        policy: sshHostKeyPolicy,
                        metadataFingerprint: metadataFingerprint
                    )
                    let shellSession = try await LoomOpenSSHSession.connect(
                        endpoint: endpoint,
                        authentication: validatedAuthentication,
                        request: request,
                        expectedHostKeyFingerprint: resolvedFingerprint,
                        timeout: timeout
                    )
                    attempts.append(
                        LoomShellConnectionAttempt(
                            transport: transport,
                            directPath: nil,
                            outcome: .succeeded
                        )
                    )
                    let report = LoomShellConnectionReport(
                        attempts: attempts,
                        selectedTransport: transport
                    )
                    return LoomShellConnectionResult(
                        transport: transport,
                        session: shellSession,
                        authenticatedSessionContext: nil,
                        report: report
                    )
                }
            } catch {
                attempts.append(
                    LoomShellConnectionAttempt(
                        transport: transport,
                        directPath: nil,
                        outcome: .failed(error.localizedDescription)
                    )
                )
                lastError = error
            }
        }

        let report = LoomShellConnectionReport(
            attempts: attempts,
            selectedTransport: nil
        )
        let message = (lastError ?? LoomError.sessionNotFound).localizedDescription
        throw LoomShellConnectionFailure(report: report, underlyingMessage: message)
    }

    private func resolveHostKeyFingerprint(
        policy: LoomShellSSHHostKeyPolicy,
        metadataFingerprint: String?
    ) throws -> String? {
        switch policy {
        case .acceptAny:
            return nil
        case let .fingerprint(value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw LoomShellError.missingSSHHostKeyFingerprint
            }
            return trimmed
        case .metadataRequired:
            guard let metadataFingerprint else {
                throw LoomShellError.missingSSHHostKeyFingerprint
            }
            let trimmed = metadataFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw LoomShellError.missingSSHHostKeyFingerprint
            }
            return trimmed
        }
    }

    private func validateSSHAuthentication(
        _ authentication: LoomShellSSHAuthentication
    ) throws -> LoomShellSSHAuthentication {
        let username = authentication.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            throw LoomShellError.invalidSSHAuthentication
        }
        guard !authentication.methods.isEmpty else {
            throw LoomShellError.invalidSSHAuthentication
        }
        return LoomShellSSHAuthentication(
            username: username,
            methods: authentication.methods
        )
    }
}
