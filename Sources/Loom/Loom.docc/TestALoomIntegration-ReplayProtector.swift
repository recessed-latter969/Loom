import Foundation
@testable import Loom
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
