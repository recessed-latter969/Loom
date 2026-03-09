import Dispatch
import Foundation
import Loom
import Network

@MainActor
final class MyClientService {
    enum ConnectionState: Equatable {
        case disconnected
        case browsing
        case connecting(peerID: UUID)
        case connected(peerID: UUID)
        case failed(String)
    }

    private let node: LoomNode
    private let discovery: LoomDiscovery

    private(set) var peers: [LoomPeer] = []
    private(set) var selectedPeerID: UUID?
    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var session: LoomSession?
    private let reconnectDelay: Duration = .seconds(1)

    init() {
        let configuration = LoomNetworkConfiguration(
            serviceType: "_myapp._tcp",
            enablePeerToPeer: true
        )
        node = LoomNode(
            configuration: configuration,
            identityManager: LoomIdentityManager.shared
        )
        discovery = node.makeDiscovery()
    }

    func startBrowsing() {
        discovery.onPeersChanged = { [weak self] peers in
            guard let self else { return }
            self.peers = peers.filter(Self.isCompatible(peer:))
        }

        discovery.startDiscovery()
        connectionState = .browsing
    }

    func selectPeer(_ peer: LoomPeer) {
        selectedPeerID = peer.id
    }

    func connect(to peer: LoomPeer) async {
        selectedPeerID = peer.id
        connectionState = .connecting(peerID: peer.id)

        let connection = NWConnection(to: peer.endpoint, using: .tcp)
        let session = node.makeSession(connection: connection)

        session.setStateUpdateHandler { [weak self] state in
            guard let self else { return }
            if case .failed(let error) = state {
                self.connectionState = .failed(error.localizedDescription)
            }
        }

        session.start(queue: .main)
        self.session = session
        connectionState = .connected(peerID: peer.id)

        Task {
            await performClientHandshake(over: session, expectedPeer: peer)
        }
    }

    private static func isCompatible(peer: LoomPeer) -> Bool {
        let metadata = peer.advertisement.metadata
        return metadata["myapp.protocol"] == "1"
            && metadata["myapp.role"] == "host"
            && peer.advertisement.identityKeyID != nil
    }
}
