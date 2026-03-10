# Build A Shell App On Loom

## Overview

The intended shape is:

1. A host app runs `LoomShellService` with a `LoomShellHost`.
2. The host optionally publishes relay presence with `startRemoteAccess`.
3. A client app discovers peers locally or learns a relay session ID remotely.
4. The client connects with `LoomShellConnector`, which prefers Loom-native direct paths and only falls back to SSH when needed.

That keeps AWDL, local network transport, relay introduction, and SSH compatibility as one coherent app-level story.

## Start a host

On macOS, the simplest host runtime is `LoomLocalShellHost`.

```swift
import Loom
import LoomShell

let node = LoomNode(
    configuration: LoomNetworkConfiguration(
        serviceType: "_myterminal._tcp",
        enablePeerToPeer: true,
        enabledDirectTransports: [.tcp, .quic]
    )
)

let service = LoomShellService(
    node: node,
    host: LoomLocalShellHost()
)

let identity = LoomShellIdentity(
    deviceID: myStableDeviceID,
    deviceName: Host.current().localizedName ?? "Mac",
    deviceType: .mac,
    iCloudUserID: cloudKitUserID
)

let startup = try await service.start(
    configuration: LoomShellServiceConfiguration(
        serviceName: identity.deviceName,
        identity: identity,
        bootstrapMetadata: bootstrapMetadata
    )
)

print(startup.ports)
```

`LoomShellService` handles:

- authenticated Loom session acceptance
- Loom-native shell stream bridging
- capability publication in advertisements
- consistent session hello generation for new peers

## Publish remote access through the relay

When you want remote reachability without turning the relay into a TURN service, publish direct candidates and heartbeat them through your app-owned signaling service.

```swift
let relayClient = LoomRelayClient(configuration: relayConfiguration)

let remoteAccess = try await service.startRemoteAccess(
    sessionID: remoteSessionID,
    relayClient: relayClient,
    publicTCPHost: publicHostNameIfYouWantTCPFallback
)

print(remoteAccess.peerCandidates)
```

`startRemoteAccess` does three important things:

- collects direct candidates using the actual bound listener ports
- advertises them through the relay as peer presence
- keeps the session alive with heartbeats until you call `stopRemoteAccess`

That means the relay stays control-plane only. Payload traffic still goes directly over Loom-native transport.

## Discover and connect from a client

For local discovery, convert `LoomPeer` values into `LoomShellDiscoveredPeer`.

```swift
let discovery = node.makeDiscovery()

discovery.onPeersChanged = { peers in
    let shellPeers = peers.map(LoomShellDiscoveredPeer.init(peer:))
    for peer in shellPeers where peer.supportsAnyShellPath {
        print(peer.peer.name, peer.capabilities as Any)
    }
}

discovery.startDiscovery()
```

Then connect with one policy-driven connector.

```swift
let connector = LoomShellConnector(node: node, relayClient: relayClient)

let clientIdentity = LoomShellIdentity(
    deviceID: myStableDeviceID,
    deviceName: "My iPad",
    deviceType: .iPad,
    iCloudUserID: cloudKitUserID
)

let result = try await connector.connect(
    to: discoveredPeer,
    identity: clientIdentity,
    request: LoomShellSessionRequest(
        command: nil,
        terminalType: "xterm-256color",
        columns: 132,
        rows: 43
    ),
    relaySessionID: optionalRemoteSessionID,
    sshAuthentication: optionalSSHAuthentication
)

print(result.transport)
print(result.report)
```

Connection order is deterministic:

1. Local Loom-native direct path
2. Relay-discovered QUIC direct path
3. Relay-discovered TCP direct path
4. OpenSSH fallback, if configured

## Handle SSH fallback

If the peer does not run the Loom host runtime, pass SSH credentials and a host-key policy.

```swift
let sshAuth = LoomShellSSHAuthentication
    .privateKey(username: "ethan", key: myEd25519Key)
    .appendingMethod(.password(myPassword))

let result = try await connector.connect(
    hello: try clientIdentity.makeHelloRequest(),
    request: LoomShellSessionRequest(),
    bootstrapMetadata: bootstrapMetadata,
    sshAuthentication: sshAuth,
    sshHostKeyPolicy: .metadataRequired
)
```

The app should keep SSH as a compatibility path, not as the primary transport, when both peers can speak Loom-native shell.

## Drive the session

Both Loom-native and OpenSSH-backed sessions conform to `LoomShellInteractiveSession`.

```swift
let session = result.session

Task {
    for await event in session.events {
        switch event {
        case .ready:
            break
        case let .stdout(data), let .stderr(data):
            terminalView.append(data)
        case let .exit(exit):
            terminalView.finish(exitCode: exit.exitCode)
        case let .failure(message):
            terminalView.showError(message)
        case .heartbeat:
            break
        }
    }
}

try await session.sendStdin(Data("ls\n".utf8))
try await session.resize(.init(columns: 160, rows: 48))
```

## Surface failures to the user

When a connection fails, cast the error to `LoomShellConnectionFailure`.

```swift
do {
    _ = try await connector.connect(...)
} catch let failure as LoomShellConnectionFailure {
    print(failure.report.attempts)
}
```

That report is the right place to drive user-facing diagnostics such as:

- "Nearby direct connection failed"
- "Relay discovered only TCP candidates"
- "SSH fallback skipped because no credentials were provided"
- "SSH host key fingerprint did not match metadata"

## Recommended product split

For a serious terminal app, keep this architecture boundary:

- Your app owns terminal rendering, tabs, profiles, bookmarks, history, SSH agent UX, and host approval UX.
- `LoomShell` owns the shell transport contract and transport fallback policy.
- `Loom` owns authenticated device networking, trust, relay presence, and recovery primitives.

That split is what lets you build a polished product without re-implementing AWDL, trust, or direct-connection plumbing each time.
