//
//  LoomShellService.swift
//  LoomShell
//
//  Created by Codex on 3/9/26.
//

import Foundation
import Loom

/// Configuration for a LoomShell host service.
public struct LoomShellServiceConfiguration: Sendable, Equatable {
    public let serviceName: String
    public let identity: LoomShellIdentity
    public let bootstrapMetadata: LoomBootstrapMetadata?
    public let supportsOpenSSHFallback: Bool

    public init(
        serviceName: String,
        identity: LoomShellIdentity,
        bootstrapMetadata: LoomBootstrapMetadata? = nil,
        supportsOpenSSHFallback: Bool? = nil
    ) {
        self.serviceName = serviceName
        self.identity = identity
        self.bootstrapMetadata = bootstrapMetadata
        self.supportsOpenSSHFallback = supportsOpenSSHFallback ?? (bootstrapMetadata?.enabled == true)
    }

    func capabilities(
        directTransports: Set<LoomTransportKind>
    ) -> LoomShellPeerCapabilities {
        LoomShellPeerCapabilities(
            supportsLoomNativeShell: true,
            supportsOpenSSHFallback: supportsOpenSSHFallback,
            supportedDirectTransports: Array(directTransports),
            bootstrapMetadata: bootstrapMetadata
        )
    }
}

/// Snapshot returned when a shell host begins advertising.
public struct LoomShellServiceStartup: Sendable {
    public let ports: [LoomTransportKind: UInt16]
    public let advertisement: LoomPeerAdvertisement
    public let capabilities: LoomShellPeerCapabilities
    public let helloRequest: LoomSessionHelloRequest

    public init(
        ports: [LoomTransportKind: UInt16],
        advertisement: LoomPeerAdvertisement,
        capabilities: LoomShellPeerCapabilities,
        helloRequest: LoomSessionHelloRequest
    ) {
        self.ports = ports
        self.advertisement = advertisement
        self.capabilities = capabilities
        self.helloRequest = helloRequest
    }
}

/// Published remote access state for a shell host that is using Loom relay introduction.
public struct LoomShellRemoteAccessStatus: Sendable, Equatable {
    public let sessionID: String
    public let peerCandidates: [LoomRelayCandidate]
    public let heartbeatTTLSeconds: Int
    public let heartbeatInterval: Duration

    public init(
        sessionID: String,
        peerCandidates: [LoomRelayCandidate],
        heartbeatTTLSeconds: Int,
        heartbeatInterval: Duration
    ) {
        self.sessionID = sessionID
        self.peerCandidates = peerCandidates
        self.heartbeatTTLSeconds = heartbeatTTLSeconds
        self.heartbeatInterval = heartbeatInterval
    }
}

/// App-facing wrapper that advertises a shell host and serves authenticated Loom shell sessions.
@MainActor
public final class LoomShellService {
    private let node: LoomNode
    private let server: LoomShellServer
    private var servingTasks: [UUID: Task<Void, Never>] = [:]
    private var currentConfiguration: LoomShellServiceConfiguration?
    private var currentStartup: LoomShellServiceStartup?
    private var remoteHeartbeatTask: Task<Void, Never>?
    private var remoteRelayClient: LoomRelayClient?
    private var currentRemoteAccess: LoomShellRemoteAccessStatus?

    public init(node: LoomNode, host: any LoomShellHost) {
        self.node = node
        server = LoomShellServer(host: host)
    }

    public func start(
        configuration: LoomShellServiceConfiguration
    ) async throws -> LoomShellServiceStartup {
        currentConfiguration = configuration

        do {
            let helloRequest = try await currentHelloRequest()
            let capabilities = configuration.capabilities(
                directTransports: node.configuration.enabledDirectTransports
            )
            let ports = try await node.startAuthenticatedAdvertising(
                serviceName: configuration.serviceName,
                helloProvider: { [weak self] in
                    guard let self else {
                        throw LoomError.notAdvertising
                    }
                    return try await self.currentHelloRequest()
                },
                onSession: { [weak self] session in
                    Task { @MainActor [weak self] in
                        await self?.accept(session: session)
                    }
                }
            )

            let startup = LoomShellServiceStartup(
                ports: ports,
                advertisement: helloRequest.advertisement,
                capabilities: capabilities,
                helloRequest: helloRequest
            )
            currentStartup = startup
            return startup
        } catch {
            currentConfiguration = nil
            currentStartup = nil
            throw error
        }
    }

    public func stop() async {
        await stopRemoteAccess()
        for task in servingTasks.values {
            task.cancel()
        }
        servingTasks.removeAll()
        currentConfiguration = nil
        currentStartup = nil
        await node.stopAdvertising()
    }

    public func updateBootstrapMetadata(
        _ bootstrapMetadata: LoomBootstrapMetadata?,
        supportsOpenSSHFallback: Bool? = nil
    ) async throws -> LoomShellServiceStartup {
        guard let currentStartup,
              let currentConfiguration else {
            throw LoomError.notAdvertising
        }

        let updatedConfiguration = LoomShellServiceConfiguration(
            serviceName: currentConfiguration.serviceName,
            identity: currentConfiguration.identity,
            bootstrapMetadata: bootstrapMetadata,
            supportsOpenSSHFallback: supportsOpenSSHFallback
        )
        self.currentConfiguration = updatedConfiguration
        let helloRequest = try await currentHelloRequest()
        let capabilities = updatedConfiguration.capabilities(
            directTransports: node.configuration.enabledDirectTransports
        )
        await node.updateAdvertisement(helloRequest.advertisement)

        let updated = LoomShellServiceStartup(
            ports: currentStartup.ports,
            advertisement: helloRequest.advertisement,
            capabilities: capabilities,
            helloRequest: helloRequest
        )
        self.currentStartup = updated
        return updated
    }

    public var remoteAccess: LoomShellRemoteAccessStatus? {
        currentRemoteAccess
    }

    public func startRemoteAccess(
        sessionID: String,
        relayClient: LoomRelayClient,
        publicTCPHost: String? = nil,
        ttlSeconds: Int = 360,
        heartbeatInterval: Duration? = nil
    ) async throws -> LoomShellRemoteAccessStatus {
        guard let startup = currentStartup else {
            throw LoomError.notAdvertising
        }

        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else {
            throw LoomShellError.invalidConfiguration("Relay session ID must not be empty.")
        }
        guard ttlSeconds > 0 else {
            throw LoomShellError.invalidConfiguration("Relay TTL must be greater than zero.")
        }

        await stopRemoteAccess()

        let candidates = await LoomDirectCandidateCollector.collect(
            configuration: node.configuration,
            listeningPorts: startup.ports,
            publicHostForTCP: publicTCPHost
        )
        let resolvedInterval = Self.resolvedHeartbeatInterval(
            ttlSeconds: ttlSeconds,
            preferred: heartbeatInterval
        )
        try await relayClient.advertisePeerSession(
            sessionID: normalizedSessionID,
            peerID: startup.helloRequest.deviceID,
            acceptingConnections: true,
            peerCandidates: candidates,
            ttlSeconds: ttlSeconds
        )

        let remoteAccess = LoomShellRemoteAccessStatus(
            sessionID: normalizedSessionID,
            peerCandidates: candidates,
            heartbeatTTLSeconds: ttlSeconds,
            heartbeatInterval: resolvedInterval
        )
        currentRemoteAccess = remoteAccess
        remoteRelayClient = relayClient
        remoteHeartbeatTask = Task { [weak self] in
            await self?.runRemoteHeartbeatLoop()
        }
        return remoteAccess
    }

    public func refreshRemoteAccess(
        publicTCPHost: String? = nil
    ) async throws -> LoomShellRemoteAccessStatus {
        guard let relayClient = remoteRelayClient,
              let remoteAccess = currentRemoteAccess,
              let startup = currentStartup else {
            throw LoomError.notAdvertising
        }

        let candidates = await LoomDirectCandidateCollector.collect(
            configuration: node.configuration,
            listeningPorts: startup.ports,
            publicHostForTCP: publicTCPHost
        )
        try await relayClient.peerHeartbeat(
            sessionID: remoteAccess.sessionID,
            acceptingConnections: true,
            peerCandidates: candidates,
            ttlSeconds: remoteAccess.heartbeatTTLSeconds
        )

        let updated = LoomShellRemoteAccessStatus(
            sessionID: remoteAccess.sessionID,
            peerCandidates: candidates,
            heartbeatTTLSeconds: remoteAccess.heartbeatTTLSeconds,
            heartbeatInterval: remoteAccess.heartbeatInterval
        )
        currentRemoteAccess = updated
        return updated
    }

    public func stopRemoteAccess() async {
        remoteHeartbeatTask?.cancel()
        remoteHeartbeatTask = nil

        guard let relayClient = remoteRelayClient,
              let currentRemoteAccess else {
            remoteRelayClient = nil
            self.currentRemoteAccess = nil
            return
        }

        try? await relayClient.closePeerSession(sessionID: currentRemoteAccess.sessionID)
        remoteRelayClient = nil
        self.currentRemoteAccess = nil
    }

    private func currentHelloRequest() async throws -> LoomSessionHelloRequest {
        guard let currentConfiguration else {
            throw LoomError.notAdvertising
        }
        return try await makeHelloRequest(for: currentConfiguration)
    }

    private func makeHelloRequest(
        for configuration: LoomShellServiceConfiguration
    ) async throws -> LoomSessionHelloRequest {
        let identityManager = node.identityManager ?? LoomIdentityManager.shared
        let identityKeyID = try identityManager.currentIdentity().keyID
        let capabilities = configuration.capabilities(
            directTransports: node.configuration.enabledDirectTransports
        )
        return try configuration.identity.makeHelloRequest(
            identityKeyID: identityKeyID,
            capabilities: capabilities
        )
    }

    private func accept(session: LoomAuthenticatedSession) async {
        let taskID = UUID()
        let server = self.server
        let task = Task { [weak self] in
            guard let self else { return }
            await server.serve(session: session)
            removeServingTask(taskID)
        }
        servingTasks[taskID] = task
    }

    private func removeServingTask(_ taskID: UUID) {
        servingTasks.removeValue(forKey: taskID)
    }

    private func runRemoteHeartbeatLoop() async {
        while !Task.isCancelled {
            guard let currentRemoteAccess else { return }
            do {
                try await Task.sleep(for: currentRemoteAccess.heartbeatInterval)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await sendRemoteHeartbeat()
        }
    }

    private func sendRemoteHeartbeat() async {
        guard let relayClient = remoteRelayClient,
              let currentRemoteAccess else {
            return
        }

        do {
            try await relayClient.peerHeartbeat(
                sessionID: currentRemoteAccess.sessionID,
                acceptingConnections: true,
                peerCandidates: currentRemoteAccess.peerCandidates,
                ttlSeconds: currentRemoteAccess.heartbeatTTLSeconds
            )
        } catch {
            return
        }
    }

    private static func resolvedHeartbeatInterval(
        ttlSeconds: Int,
        preferred: Duration?
    ) -> Duration {
        if let preferred, preferred > .zero {
            return preferred
        }
        let seconds = max(30, ttlSeconds / 3)
        return .seconds(seconds)
    }
}
