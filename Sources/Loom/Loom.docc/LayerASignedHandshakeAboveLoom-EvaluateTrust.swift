import Foundation
import Loom

enum HandshakeError: Error {
    case invalidKeyID
    case invalidSignature
    case protocolVersionMismatch
    case replayRejected
}

struct HelloEnvelope: Codable {
    struct Identity: Codable {
        let keyID: String
        let publicKey: Data
        let timestampMs: Int64
        let nonce: String
        let signature: Data
    }

    let deviceID: UUID
    let deviceName: String
    let deviceType: DeviceType
    let protocolVersion: Int
    let advertisement: LoomPeerAdvertisement
    let supportedFeatures: [String]
    let iCloudUserID: String?
    let identity: Identity
}

struct CanonicalHelloPayload: Codable {
    let deviceID: UUID
    let deviceName: String
    let deviceType: DeviceType
    let protocolVersion: Int
    let advertisement: LoomPeerAdvertisement
    let supportedFeatures: [String]
    let iCloudUserID: String?
    let keyID: String
    let publicKey: Data
    let timestampMs: Int64
    let nonce: String
}

func makeCanonicalHelloPayload(
    from hello: CanonicalHelloPayload
) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(hello)
}

@MainActor
func makeSignedHello(
    deviceID: UUID,
    deviceName: String,
    deviceType: DeviceType,
    advertisement: LoomPeerAdvertisement,
    supportedFeatures: [String],
    iCloudUserID: String?
) throws -> HelloEnvelope {
    let identity = try LoomIdentityManager.shared.currentIdentity()
    let timestampMs = Int64(Date().timeIntervalSince1970 * 1000)
    let nonce = UUID().uuidString.lowercased()

    let payload = CanonicalHelloPayload(
        deviceID: deviceID,
        deviceName: deviceName,
        deviceType: deviceType,
        protocolVersion: Int(Loom.protocolVersion),
        advertisement: advertisement,
        supportedFeatures: supportedFeatures,
        iCloudUserID: iCloudUserID,
        keyID: identity.keyID,
        publicKey: identity.publicKey,
        timestampMs: timestampMs,
        nonce: nonce
    )

    let payloadData = try makeCanonicalHelloPayload(from: payload)
    let signature = try LoomIdentityManager.shared.sign(payloadData)

    return HelloEnvelope(
        deviceID: deviceID,
        deviceName: deviceName,
        deviceType: deviceType,
        protocolVersion: Int(Loom.protocolVersion),
        advertisement: advertisement,
        supportedFeatures: supportedFeatures,
        iCloudUserID: iCloudUserID,
        identity: .init(
            keyID: identity.keyID,
            publicKey: identity.publicKey,
            timestampMs: timestampMs,
            nonce: nonce,
            signature: signature
        )
    )
}

actor HostHandshakeValidator {
    private let replayProtector = LoomReplayProtector()

    func validate(_ hello: HelloEnvelope) async throws -> LoomPeerIdentity {
        guard hello.protocolVersion == Int(Loom.protocolVersion) else {
            throw HandshakeError.protocolVersionMismatch
        }

        let derivedKeyID = LoomIdentityManager.keyID(for: hello.identity.publicKey)
        guard derivedKeyID == hello.identity.keyID else {
            throw HandshakeError.invalidKeyID
        }

        let payload = CanonicalHelloPayload(
            deviceID: hello.deviceID,
            deviceName: hello.deviceName,
            deviceType: hello.deviceType,
            protocolVersion: hello.protocolVersion,
            advertisement: hello.advertisement,
            supportedFeatures: hello.supportedFeatures,
            iCloudUserID: hello.iCloudUserID,
            keyID: hello.identity.keyID,
            publicKey: hello.identity.publicKey,
            timestampMs: hello.identity.timestampMs,
            nonce: hello.identity.nonce
        )

        let payloadData = try makeCanonicalHelloPayload(from: payload)
        guard LoomIdentityManager.verify(
            signature: hello.identity.signature,
            payload: payloadData,
            publicKey: hello.identity.publicKey
        ) else {
            throw HandshakeError.invalidSignature
        }

        let replayAccepted = await replayProtector.validate(
            timestampMs: hello.identity.timestampMs,
            nonce: hello.identity.nonce
        )
        guard replayAccepted else {
            throw HandshakeError.replayRejected
        }

        return LoomPeerIdentity(
            deviceID: hello.deviceID,
            name: hello.deviceName,
            deviceType: hello.deviceType,
            iCloudUserID: hello.iCloudUserID,
            identityKeyID: hello.identity.keyID,
            identityPublicKey: hello.identity.publicKey,
            isIdentityAuthenticated: true,
            endpoint: "session-endpoint"
        )
    }
}

@MainActor
func evaluateHandshakeTrust(
    peerIdentity: LoomPeerIdentity,
    trustProvider: (any LoomTrustProvider)?
) async -> LoomTrustDecision {
    guard let trustProvider else { return .requiresApproval }
    return await trustProvider.evaluateTrust(for: peerIdentity)
}
