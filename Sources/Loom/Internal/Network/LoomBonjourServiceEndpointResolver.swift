//
//  LoomBonjourServiceEndpointResolver.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/15/26.
//

@preconcurrency import Foundation
import Network

/// Resolves a Bonjour `.service` endpoint to a numeric `.hostPort` endpoint.
final class LoomBonjourServiceEndpointResolver: NSObject, NetServiceDelegate {
    private let service: NetService
    private var continuation: CheckedContinuation<NWEndpoint, Error>?

    private init(service: NetService) {
        self.service = service
        super.init()
        service.delegate = self
    }

    static func resolve(
        endpoint: NWEndpoint,
        enablePeerToPeer: Bool,
        timeout: TimeInterval = 3
    ) async throws -> NWEndpoint {
        guard case let .service(name, type, domain, _) = endpoint else {
            return endpoint
        }

        let resolvedDomain = normalizedDomain(domain)
        let service = NetService(domain: resolvedDomain, type: type, name: name)
        service.includesPeerToPeer = enablePeerToPeer

        let resolver = LoomBonjourServiceEndpointResolver(service: service)
        return try await resolver.resolve(timeout: timeout)
    }

    private func resolve(timeout: TimeInterval) async throws -> NWEndpoint {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            service.resolve(withTimeout: timeout)
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        finish(with: Result {
            let host = try Self.resolveHost(from: sender)
            guard sender.port > 0,
                  let port = NWEndpoint.Port(rawValue: UInt16(sender.port)) else {
                throw LoomError.protocolError("Resolved Bonjour service is missing a valid port")
            }
            return .hostPort(host: host, port: port)
        })
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        let code = errorDict[NetService.errorCode]?.intValue ?? -1
        finish(
            with: .failure(
                LoomError.protocolError("Bonjour resolution failed (code=\(code))")
            )
        )
    }

    private func finish(with result: Result<NWEndpoint, Error>) {
        service.stop()
        service.delegate = nil

        guard let continuation else { return }
        self.continuation = nil

        switch result {
        case let .success(endpoint):
            continuation.resume(returning: endpoint)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }

    private static func normalizedDomain(_ domain: String) -> String {
        let trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "local."
        }
        return trimmed.hasSuffix(".") ? trimmed : "\(trimmed)."
    }

    private static func resolveHost(from service: NetService) throws -> NWEndpoint.Host {
        if let addresses = service.addresses,
           let preferredAddress = preferredNumericHost(from: addresses) {
            return NWEndpoint.Host(preferredAddress)
        }

        if let hostName = service.hostName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !hostName.isEmpty {
            return NWEndpoint.Host(hostName)
        }

        throw LoomError.protocolError("Resolved Bonjour service is missing a host address")
    }

    private static func preferredNumericHost(from addresses: [Data]) -> String? {
        let candidates = addresses.compactMap(numericHost(from:))
        if let ipv4 = candidates.first(where: { $0.contains(".") }) {
            return ipv4
        }
        return candidates.first
    }

    private static func numericHost(from data: Data) -> String? {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: sockaddr.self) else {
                return nil
            }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(data.count)
            let result = getnameinfo(
                baseAddress,
                length,
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else {
                return nil
            }
            let terminatorIndex = hostBuffer.firstIndex(of: 0) ?? hostBuffer.count
            let bytes = hostBuffer[..<terminatorIndex].map(UInt8.init(bitPattern:))
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
