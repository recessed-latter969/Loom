//
//  LoomConnectionCoordinator.swift
//  Loom
//
//  Created by Codex on 3/9/26.
//

import Foundation
import Network

/// Origin of a direct connection attempt chosen by the coordinator.
public enum LoomConnectionTargetSource: String, Sendable, Codable {
    case localDiscovery
    case relay
}

/// Candidate selected by the Loom connection coordinator.
public struct LoomConnectionTarget: Sendable {
    public let source: LoomConnectionTargetSource
    public let transportKind: LoomTransportKind
    public let endpoint: NWEndpoint

    public init(
        source: LoomConnectionTargetSource,
        transportKind: LoomTransportKind,
        endpoint: NWEndpoint
    ) {
        self.source = source
        self.transportKind = transportKind
        self.endpoint = endpoint
    }
}

/// Ordered direct-connect plan resolved from discovery and relay presence.
public struct LoomConnectionPlan: Sendable {
    public let targets: [LoomConnectionTarget]

    public init(targets: [LoomConnectionTarget]) {
        self.targets = targets
    }
}

/// Collects directly reachable candidates to publish through relay presence.
public enum LoomDirectCandidateCollector {
    public static func collect(
        configuration: LoomNetworkConfiguration,
        listeningPorts: [LoomTransportKind: UInt16] = [:],
        publicHostForTCP: String? = nil
    ) async -> [LoomRelayCandidate] {
        var candidates: [LoomRelayCandidate] = []
        let quicPort = listeningPorts[.quic] ?? configuration.quicPort
        let tcpPort = listeningPorts[.tcp] ?? configuration.controlPort

        if configuration.enabledDirectTransports.contains(.quic),
           quicPort > 0 {
            let quicProbe = await LoomSTUNProbe.run(localPort: quicPort)
            if quicProbe.reachable,
               let address = quicProbe.mappedAddress,
               let mappedPort = quicProbe.mappedPort {
                candidates.append(
                    LoomRelayCandidate(
                        transport: .quic,
                        address: address,
                        port: mappedPort
                    )
                )
            }
        }

        if configuration.enabledDirectTransports.contains(.tcp),
           tcpPort > 0,
           let publicHostForTCP {
            candidates.append(
                LoomRelayCandidate(
                    transport: .tcp,
                    address: publicHostForTCP,
                    port: tcpPort
                )
            )
        }

        return candidates
    }
}

/// Resolves and attempts authenticated Loom-native direct connections.
@MainActor
public final class LoomConnectionCoordinator {
    private let node: LoomNode
    private let relayClient: LoomRelayClient?

    public init(node: LoomNode, relayClient: LoomRelayClient? = nil) {
        self.node = node
        self.relayClient = relayClient
    }

    public func makePlan(
        localPeer: LoomPeer? = nil,
        relaySessionID: String? = nil
    ) async throws -> LoomConnectionPlan {
        var targets: [LoomConnectionTarget] = []

        if let localPeer {
            targets.append(
                LoomConnectionTarget(
                    source: .localDiscovery,
                    transportKind: .tcp,
                    endpoint: localPeer.endpoint
                )
            )
        }

        if let relaySessionID,
           let relayClient {
            let presence = try await relayClient.fetchPresence(sessionID: relaySessionID)
            let relayTargets = presence.peerCandidates
                .sorted(by: compareRelayCandidates(_:_:))
                .compactMap(Self.target(from:))
            targets.append(contentsOf: relayTargets)
        }

        return LoomConnectionPlan(targets: targets)
    }

    public func connect(
        hello: LoomSessionHelloRequest,
        localPeer: LoomPeer? = nil,
        relaySessionID: String? = nil
    ) async throws -> LoomAuthenticatedSession {
        let plan = try await makePlan(localPeer: localPeer, relaySessionID: relaySessionID)
        guard !plan.targets.isEmpty else {
            throw LoomError.sessionNotFound
        }

        var lastError: Error?
        for target in plan.targets {
            do {
                return try await node.connect(
                    to: target.endpoint,
                    using: target.transportKind,
                    hello: hello
                )
            } catch {
                lastError = error
            }
        }

        throw lastError ?? LoomError.sessionNotFound
    }

    public func connect(
        to target: LoomConnectionTarget,
        hello: LoomSessionHelloRequest
    ) async throws -> LoomAuthenticatedSession {
        try await node.connect(
            to: target.endpoint,
            using: target.transportKind,
            hello: hello
        )
    }

    private func compareRelayCandidates(
        _ lhs: LoomRelayCandidate,
        _ rhs: LoomRelayCandidate
    ) -> Bool {
        let leftPriority = relayPriority(lhs.transport)
        let rightPriority = relayPriority(rhs.transport)
        if leftPriority != rightPriority {
            return leftPriority < rightPriority
        }
        if lhs.address != rhs.address {
            return lhs.address < rhs.address
        }
        return lhs.port < rhs.port
    }

    private func relayPriority(_ transport: LoomRelayCandidateTransport) -> Int {
        switch transport {
        case .quic:
            0
        case .tcp:
            1
        }
    }

    private static func target(from candidate: LoomRelayCandidate) -> LoomConnectionTarget? {
        guard let endpointPort = NWEndpoint.Port(rawValue: candidate.port) else {
            return nil
        }
        let host = NWEndpoint.Host(candidate.address)
        let transportKind: LoomTransportKind = switch candidate.transport {
        case .quic: .quic
        case .tcp: .tcp
        }
        return LoomConnectionTarget(
            source: .relay,
            transportKind: transportKind,
            endpoint: .hostPort(host: host, port: endpointPort)
        )
    }
}
