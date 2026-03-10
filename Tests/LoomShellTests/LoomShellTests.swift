//
//  LoomShellTests.swift
//  LoomShellTests
//
//  Created by Codex on 3/9/26.
//

@testable import LoomShell
import Foundation
import Network
import Testing

@Suite("Loom Shell", .serialized)
struct LoomShellTests {
    @Test("Planner prefers Loom-native and keeps OpenSSH fallbacks ordered")
    func plannerPrefersNative() {
        let metadata = LoomBootstrapMetadata(
            enabled: true,
            supportsPreloginDaemon: true,
            endpoints: [
                .init(host: "host.example.com", port: 22, source: .user),
                .init(host: "10.0.0.2", port: 22, source: .auto),
            ],
            sshPort: 22,
            controlPort: 9849,
            sshHostKeyFingerprint: "SHA256:test",
            controlAuthSecret: "secret",
            wakeOnLAN: nil
        )

        let plan = LoomShellConnectionPlanner.plan(bootstrapMetadata: metadata)

        #expect(plan.primary == LoomShellResolvedTransport.loomNative)
        #expect(plan.fallbacks.count == 2)
    }

    @Test("Planner prefers OpenSSH when peer disables Loom-native shell")
    func plannerRespectsPeerCapabilities() {
        let metadata = LoomBootstrapMetadata(
            enabled: true,
            supportsPreloginDaemon: false,
            endpoints: [
                .init(host: "host.example.com", port: 22, source: .user),
            ],
            sshPort: 22,
            controlPort: nil,
            sshHostKeyFingerprint: "SHA256:test",
            controlAuthSecret: nil,
            wakeOnLAN: nil
        )
        let capabilities = LoomShellPeerCapabilities(
            supportsLoomNativeShell: false,
            supportsOpenSSHFallback: true,
            supportedDirectTransports: [.tcp],
            bootstrapMetadata: metadata
        )

        let plan = LoomShellConnectionPlanner.plan(
            peerCapabilities: capabilities,
            bootstrapMetadata: metadata
        )

        #expect(
            plan.primary == .openSSH(
                endpoint: .init(host: "host.example.com", port: 22, source: .user),
                hostKeyFingerprint: "SHA256:test"
            )
        )
        #expect(plan.fallbacks.isEmpty)
    }

    @Test("Shell capabilities round-trip through advertisements and discovered peers")
    func capabilitiesRoundTripThroughAdvertisement() throws {
        let identity = LoomShellIdentity(
            deviceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            deviceName: "Studio Mac",
            deviceType: .mac,
            additionalAdvertisementMetadata: ["app.role": "host"]
        )
        let capabilities = LoomShellPeerCapabilities(
            supportsLoomNativeShell: true,
            supportsOpenSSHFallback: true,
            supportedDirectTransports: [.quic, .tcp],
            bootstrapMetadata: LoomBootstrapMetadata(
                enabled: true,
                supportsPreloginDaemon: true,
                endpoints: [.init(host: "host.example.com", port: 22, source: .user)],
                sshPort: 22,
                controlPort: 9849,
                sshHostKeyFingerprint: "SHA256:test",
                controlAuthSecret: "secret",
                wakeOnLAN: nil
            )
        )

        let advertisement = try identity.makeAdvertisement(
            identityKeyID: "identity-key-id",
            capabilities: capabilities
        )
        let peer = LoomPeer(
            id: identity.deviceID,
            name: identity.deviceName,
            deviceType: identity.deviceType,
            endpoint: .hostPort(
                host: NWEndpoint.Host("127.0.0.1"),
                port: NWEndpoint.Port(rawValue: 7777)!
            ),
            advertisement: advertisement
        )
        let discoveredPeer = LoomShellDiscoveredPeer(peer: peer)

        #expect(LoomShellAdvertisementCodec.capabilities(from: advertisement) == capabilities)
        #expect(discoveredPeer.capabilities == capabilities)
        #expect(discoveredPeer.supportsAnyShellPath)
    }

    @Test("Shell envelopes round-trip through codable")
    func envelopeRoundTrips() throws {
        let envelope = LoomShellEnvelope.open(
            LoomShellSessionRequest(
                command: "/bin/zsh",
                environment: ["LANG": "en_US.UTF-8"],
                workingDirectory: "/tmp",
                terminalType: "xterm-256color",
                columns: 120,
                rows: 40
            )
        )

        let encoded = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(LoomShellEnvelope.self, from: encoded)

        #expect(decoded == envelope)
    }

    @Test("Binary shell wire codec round-trips runtime frames")
    func wireCodecRoundTrips() throws {
        let envelopes: [LoomShellEnvelope] = [
            .ready(.init(mergesStandardError: true)),
            .stdin(Data([0x41, 0x42, 0x43])),
            .stdout(Data("hello".utf8)),
            .stderr(Data("error".utf8)),
            .resize(.init(columns: 132, rows: 43)),
            .heartbeat,
            .exit(.init(exitCode: 7)),
            .failure("boom"),
        ]

        for envelope in envelopes {
            let encoded = try LoomShellWireCodec.encode(envelope)
            let decoded = try LoomShellWireCodec.decode(encoded)
            #expect(decoded == envelope)
        }
    }

    @Test("Native shell client sends open frame and yields decoded events")
    func nativeClientSessionDrivesChannel() async throws {
        let recorder = RecordedFrames()
        let closed = CloseFlag()
        let (incomingFrames, incomingContinuation) = AsyncStream.makeStream(of: Data.self)
        let channel = LoomShellChannel(
            incomingFrames: incomingFrames,
            send: { frame in
                await recorder.append(frame)
            },
            close: {
                await closed.markClosed()
            }
        )

        let session = LoomNativeShellSession(channel: channel)
        let request = LoomShellSessionRequest(
            command: "/usr/bin/env",
            environment: ["LANG": "en_US.UTF-8"],
            workingDirectory: "/tmp",
            terminalType: "xterm-256color",
            columns: 132,
            rows: 43
        )

        let eventTask = Task { () -> [LoomShellEvent] in
            var events: [LoomShellEvent] = []
            for await event in session.events {
                events.append(event)
                if case .exit = event {
                    break
                }
            }
            return events
        }

        try await session.start(request: request)
        let sentFrames = await recorder.frames
        #expect(sentFrames.count == 1)
        #expect(try LoomShellWireCodec.decode(sentFrames[0]) == .open(request))

        incomingContinuation.yield(try LoomShellWireCodec.encode(.ready(.init(mergesStandardError: true))))
        incomingContinuation.yield(try LoomShellWireCodec.encode(.stdout(Data("hello".utf8))))
        incomingContinuation.yield(try LoomShellWireCodec.encode(.exit(.init(exitCode: 0))))
        incomingContinuation.finish()

        let events = try await withTimeout(seconds: 2) {
            await eventTask.value
        }

        #expect(
            events == [
                .ready(.init(mergesStandardError: true)),
                .stdout(Data("hello".utf8)),
                .exit(.init(exitCode: 0)),
            ]
        )

        await session.close()
        #expect(await closed.isClosed)
    }

    @MainActor
    @Test("Connection failures preserve direct-path and SSH fallback diagnostics")
    func connectionFailurePreservesReport() async throws {
        let node = LoomNode(
            configuration: LoomNetworkConfiguration(
                enabledDirectTransports: [.tcp]
            )
        )
        let connector = LoomShellConnector(node: node)
        let identity = LoomShellIdentity(
            deviceID: UUID(),
            deviceName: "Client Mac",
            deviceType: .mac
        )
        let bootstrapMetadata = LoomBootstrapMetadata(
            enabled: true,
            supportsPreloginDaemon: false,
            endpoints: [.init(host: "host.example.com", port: 22, source: .user)],
            sshPort: 22,
            controlPort: nil,
            sshHostKeyFingerprint: "SHA256:test",
            controlAuthSecret: nil,
            wakeOnLAN: nil
        )

        do {
            _ = try await connector.connect(
                hello: try identity.makeHelloRequest(),
                request: LoomShellSessionRequest(),
                bootstrapMetadata: bootstrapMetadata
            )
            Issue.record("Expected shell connection to fail without direct candidates or SSH credentials.")
        } catch let failure as LoomShellConnectionFailure {
            #expect(failure.report.selectedTransport == nil)
            #expect(failure.report.attempts.count == 2)

            #expect(failure.report.attempts[0].transport == .loomNative)
            #expect(failure.report.attempts[0].directPath == nil)
            if case let .failed(message) = failure.report.attempts[0].outcome {
                #expect(message.contains("No direct Loom transport candidates"))
            } else {
                Issue.record("Expected the Loom-native attempt to fail with a candidate diagnostic.")
            }

            #expect(
                failure.report.attempts[1].transport == .openSSH(
                    endpoint: .init(host: "host.example.com", port: 22, source: .user),
                    hostKeyFingerprint: "SHA256:test"
                )
            )
            if case let .skipped(message) = failure.report.attempts[1].outcome {
                #expect(message.contains("OpenSSH fallback requires authentication"))
            } else {
                Issue.record("Expected the OpenSSH attempt to be skipped without auth material.")
            }
        }
    }

    #if os(macOS)
    @Test("Local PTY host emits ready output and exit")
    func localHostRunsCommand() async throws {
        guard ProcessInfo.processInfo.environment["LOOM_RUN_SHELL_INTEGRATION"] == "1" else {
            return
        }

        let host = LoomLocalShellHost()
        let hostedSession = try await host.startSession(
            request: LoomShellSessionRequest(
                command: "printf 'loom-shell-host'; exit 7",
                terminalType: "xterm-256color",
                columns: 80,
                rows: 24
            )
        )

        let events = try await withTimeout(seconds: 5) {
            var collected: [LoomShellEvent] = []
            for await event in hostedSession.events {
                collected.append(event)
                if case .exit = event {
                    break
                }
            }
            return collected
        }

        await hostedSession.close()

        #expect(events.contains(where: { event in
            if case let .ready(ready) = event {
                return ready.mergesStandardError
            }
            return false
        }))
        #expect(events.contains(where: { event in
            if case let .stdout(data) = event {
                let output = String(decoding: data, as: UTF8.self)
                return output.contains("loom-shell-host")
                    && !output.contains("can't set tty pgrp")
            }
            return false
        }))
        #expect(events.contains(where: { event in
            if case let .exit(exit) = event {
                return exit.exitCode == 7
            }
            return false
        }))
    }

    @Test("Local PTY host starts interactive login shell without tty job-control warnings")
    func localHostStartsInteractiveShellWithoutTTYWarning() async throws {
        guard ProcessInfo.processInfo.environment["LOOM_RUN_SHELL_INTEGRATION"] == "1" else {
            return
        }

        let host = LoomLocalShellHost()
        let hostedSession = try await host.startSession(
            request: LoomShellSessionRequest(
                terminalType: "xterm-256color",
                columns: 80,
                rows: 24
            )
        )

        try await hostedSession.sendStdin(
            Data("printf '__loom_interactive_ready__\\n'; exit 0\n".utf8)
        )

        let events = try await withTimeout(seconds: 5) {
            var collected: [LoomShellEvent] = []
            for await event in hostedSession.events {
                collected.append(event)
                if case .exit = event {
                    break
                }
            }
            return collected
        }

        await hostedSession.close()

        let output = events.reduce(into: "") { partialResult, event in
            if case let .stdout(data) = event {
                partialResult += String(decoding: data, as: UTF8.self)
            }
        }

        #expect(output.contains("__loom_interactive_ready__"))
        #expect(!output.contains("can't set tty pgrp"))
        #expect(!output.contains("failed to claim foreground terminal"))
        #expect(events.contains(where: { event in
            if case let .exit(exit) = event {
                return exit.exitCode == 0
            }
            return false
        }))
    }

    @Test("Local PTY host runs commands inside an interactive login zsh")
    func localHostCommandUsesInteractiveLoginShell() async throws {
        guard ProcessInfo.processInfo.environment["LOOM_RUN_SHELL_INTEGRATION"] == "1" else {
            return
        }

        let host = LoomLocalShellHost()
        let hostedSession = try await host.startSession(
            request: LoomShellSessionRequest(
                command: #"print -r -- "__loom_flags__:$options[login]:$options[interactive]"; exit 0"#,
                environment: ["SHELL": "/bin/zsh"],
                terminalType: "xterm-256color",
                columns: 80,
                rows: 24
            )
        )

        let events = try await withTimeout(seconds: 5) {
            var collected: [LoomShellEvent] = []
            for await event in hostedSession.events {
                collected.append(event)
                if case .exit = event {
                    break
                }
            }
            return collected
        }

        await hostedSession.close()

        let output = events.reduce(into: "") { partialResult, event in
            if case let .stdout(data) = event {
                partialResult += String(decoding: data, as: UTF8.self)
            }
        }

        #expect(output.contains("__loom_flags__:on:on"))
        #expect(!output.contains("failed to claim foreground terminal"))
        #expect(events.contains(where: { event in
            if case let .exit(exit) = event {
                return exit.exitCode == 0
            }
            return false
        }))
    }
    #endif
}

private actor RecordedFrames {
    private(set) var frames: [Data] = []

    func append(_ frame: Data) {
        frames.append(frame)
    }
}

private actor CloseFlag {
    private(set) var isClosed = false

    func markClosed() {
        isClosed = true
    }
}

private func withTimeout<T: Sendable>(
    seconds: Int64,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw LoomError.timeout
        }

        guard let result = try await group.next() else {
            throw LoomError.timeout
        }
        group.cancelAll()
        return result
    }
}
