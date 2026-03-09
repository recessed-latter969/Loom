import Loom
import LoomCloudKit

@MainActor
final class MyCloudPeerRuntime {
    let configuration = LoomCloudKitConfiguration(
        containerIdentifier: "iCloud.com.example.myapp",
        deviceRecordType: "MyAppDevice",
        peerRecordType: "MyAppPeer",
        peerZoneName: "MyAppPeerZone",
        participantIdentityRecordType: "MyAppParticipantIdentity",
        shareTitle: "MyApp Device Access",
        deviceIDKey: "com.example.myapp.deviceID"
    )

    lazy var cloudKitManager = LoomCloudKitManager(configuration: configuration)
    lazy var shareManager = LoomCloudKitShareManager(cloudKitManager: cloudKitManager)
    lazy var peerProvider = LoomCloudKitPeerProvider(cloudKitManager: cloudKitManager)

    func initialize() async throws {
        await cloudKitManager.initialize()
        guard cloudKitManager.isAvailable else { return }

        let identity = try LoomIdentityManager.shared.currentIdentity()
        await cloudKitManager.registerIdentity(
            keyID: identity.keyID,
            publicKey: identity.publicKey
        )

        await shareManager.setup()
    }
}
