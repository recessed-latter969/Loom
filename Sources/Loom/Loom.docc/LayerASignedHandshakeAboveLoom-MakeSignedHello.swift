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
