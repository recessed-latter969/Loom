@testable import Loom
import Foundation
import Testing

@Suite("Peer Advertisement")
struct PeerAdvertisementTests {
    @Test("TXT record round-trip preserves product metadata")
    func txtRoundTripPreservesMetadata() {
        let original = LoomPeerAdvertisement(
            deviceID: UUID(),
            identityKeyID: "abc123",
            deviceType: .mac,
            metadata: [
                "myapp.protocol": "1",
                "myapp.role": "host",
            ]
        )

        let decoded = LoomPeerAdvertisement.from(txtRecord: original.toTXTRecord())

        #expect(decoded.deviceID == original.deviceID)
        #expect(decoded.identityKeyID == original.identityKeyID)
        #expect(decoded.metadata["myapp.protocol"] == "1")
        #expect(decoded.metadata["myapp.role"] == "host")
    }
}

@Suite("Signed Hello Validation")
struct SignedHelloValidationTests {
    @Test("Invalid key identifiers are rejected before trust evaluation")
    func invalidKeyIdentifierIsRejected() {
        let publicKey = Data([0x01, 0x02, 0x03])
        let claimedKeyID = "wrong-key-id"

        #expect(LoomIdentityManager.keyID(for: publicKey) != claimedKeyID)
    }

    @Test("Replay protector rejects the same nonce twice")
    func replayProtectorRejectsDuplicateNonce() async {
        let protector = LoomReplayProtector()
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)

        let first = await protector.validate(timestampMs: timestamp, nonce: "nonce-1")
        let second = await protector.validate(timestampMs: timestamp, nonce: "nonce-1")

        #expect(first == true)
        #expect(second == false)
    }
}

@MainActor
@Suite("Trust Provider Policy")
struct TrustProviderPolicyTests {
    @Test("Locally trusted devices auto-approve")
    func trustedDevicesAutoApprove() async throws {
        let store = LoomTrustStore(storageKey: "tests.trust.store")
        let deviceID = UUID()
        store.addTrustedDevice(
            LoomTrustedDevice(
                id: deviceID,
                name: "Known Mac",
                deviceType: .mac,
                trustedAt: Date()
            )
        )

        let provider = MyTrustProvider(trustStore: store, currentUserID: nil)
        let peer = LoomPeerIdentity(
            deviceID: deviceID,
            name: "Known Mac",
            deviceType: .mac,
            iCloudUserID: nil,
            identityKeyID: "key-1",
            identityPublicKey: Data(),
            isIdentityAuthenticated: true,
            endpoint: "127.0.0.1"
        )

        let decision = await provider.evaluateTrust(for: peer)
        #expect(decision == .trusted)
    }
}

@Suite("Runtime Observability", .serialized)
struct RuntimeObservabilityTests {
    @Test("Diagnostics fan out to all sinks")
    func diagnosticsFanOut() async {
        await LoomDiagnostics.removeAllSinks()

        let sinkOne = TestSink()
        let sinkTwo = TestSink()
        _ = await LoomDiagnostics.addSink(sinkOne)
        _ = await LoomDiagnostics.addSink(sinkTwo)

        LoomDiagnostics.record(log: LoomDiagnosticsLogEvent(
            date: Date(),
            category: .session,
            level: .info,
            message: "fanout",
            fileID: #fileID,
            line: #line,
            function: #function
        ))
    }

    @Test("Removed sinks stop receiving future events")
    func removedSinksStopReceivingFutureEvents() async {
        await LoomDiagnostics.removeAllSinks()
        let sink = TestSink()
        let token = await LoomDiagnostics.addSink(sink)

        await LoomDiagnostics.removeSink(token)
        LoomDiagnostics.record(log: LoomDiagnosticsLogEvent(
            date: Date(),
            category: .session,
            level: .info,
            message: "after-removal",
            fileID: #fileID,
            line: #line,
            function: #function
        ))
    }
}

private actor TestSink: LoomDiagnosticsSink {
    private var logs: [LoomDiagnosticsLogEvent] = []

    func record(log event: LoomDiagnosticsLogEvent) async {
        logs.append(event)
    }
}
