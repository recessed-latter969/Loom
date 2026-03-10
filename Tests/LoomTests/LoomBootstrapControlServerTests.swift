//
//  LoomBootstrapControlServerTests.swift
//  Loom
//
//  Created by Codex on 3/9/26.
//

@testable import Loom
import Testing

@Suite("Loom Bootstrap Control Server", .serialized)
struct LoomBootstrapControlServerTests {
    @MainActor
    @Test("Server status and unlock handlers round-trip through the client")
    func statusAndUnlockRoundTrip() async throws {
        let identityManager = LoomIdentityManager(
            service: "com.ethanlipnik.loom.tests.bootstrap-control.\(UUID().uuidString)",
            account: "p256-signing",
            synchronizable: false
        )
        let server = LoomBootstrapControlServer(
            controlAuthSecret: "server-secret",
            onStatus: { peer in
                #expect(!peer.keyID.isEmpty)
                return LoomBootstrapControlResult(state: .credentialsRequired, message: "unlock needed")
            },
            onUnlock: { peer, credentials in
                #expect(!peer.keyID.isEmpty)
                #expect(credentials.userIdentifier == "ethan")
                #expect(credentials.secret == "hunter2")
                return LoomBootstrapControlResult(state: .ready, message: "ready")
            }
        )
        let port = try await server.start(port: 0)
        defer {
            Task {
                await server.stop()
            }
        }

        let endpoint = LoomBootstrapEndpoint(host: "127.0.0.1", port: 22, source: .user)
        let client = LoomDefaultBootstrapControlClient(identityManager: identityManager)

        let status = try await client.requestStatus(
            endpoint: endpoint,
            controlPort: port,
            controlAuthSecret: "server-secret",
            timeout: .seconds(5)
        )
        #expect(status.state == .credentialsRequired)
        #expect(status.message == "unlock needed")

        let unlock = try await client.requestUnlock(
            endpoint: endpoint,
            controlPort: port,
            controlAuthSecret: "server-secret",
            username: "ethan",
            password: "hunter2",
            timeout: .seconds(5)
        )
        #expect(unlock.state == .ready)
        #expect(unlock.message == "ready")
    }
}
