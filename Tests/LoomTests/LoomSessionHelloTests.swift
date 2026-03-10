//
//  LoomSessionHelloTests.swift
//  Loom
//
//  Created by Codex on 3/9/26.
//

@testable import Loom
import Testing

@Suite("Loom Session Hello")
struct LoomSessionHelloTests {
    @MainActor
    @Test("Signed hello validates into an authenticated peer identity")
    func signedHelloValidates() async throws {
        let identityManager = LoomIdentityManager(
            service: "com.ethanlipnik.loom.tests.session-hello.\(UUID().uuidString)",
            account: "p256-signing",
            synchronizable: false
        )
        let request = LoomSessionHelloRequest(
            deviceID: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            deviceName: "Test Mac",
            deviceType: .mac,
            advertisement: LoomPeerAdvertisement(
                deviceID: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
                deviceType: .mac
            ),
            supportedFeatures: ["loom.streams.v1"],
            iCloudUserID: "user-1"
        )

        let hello = try LoomSessionHelloValidator.makeSignedHello(
            from: request,
            identityManager: identityManager
        )
        let validator = LoomSessionHelloValidator()
        let peerIdentity = try await validator.validate(
            hello,
            endpointDescription: "127.0.0.1:9999"
        )

        #expect(peerIdentity.deviceID == request.deviceID)
        #expect(peerIdentity.name == request.deviceName)
        #expect(peerIdentity.deviceType == request.deviceType)
        #expect(peerIdentity.iCloudUserID == "user-1")
        #expect(peerIdentity.isIdentityAuthenticated)
    }

    @MainActor
    @Test("Hello validation rejects replayed nonces")
    func helloRejectsReplay() async throws {
        let identityManager = LoomIdentityManager(
            service: "com.ethanlipnik.loom.tests.session-replay.\(UUID().uuidString)",
            account: "p256-signing",
            synchronizable: false
        )
        let request = LoomSessionHelloRequest(
            deviceID: UUID(),
            deviceName: "Replay Test",
            deviceType: .mac,
            advertisement: LoomPeerAdvertisement()
        )
        let hello = try LoomSessionHelloValidator.makeSignedHello(
            from: request,
            identityManager: identityManager
        )
        let validator = LoomSessionHelloValidator()

        _ = try await validator.validate(hello, endpointDescription: "127.0.0.1:1")
        await #expect(throws: LoomSessionHelloError.replayRejected) {
            try await validator.validate(hello, endpointDescription: "127.0.0.1:2")
        }
    }
}

