//
//  LoomNativeShellSession.swift
//  LoomShell
//
//  Created by Codex on 3/9/26.
//

import Foundation
import Loom

/// Client-side interactive Loom-native shell session.
public actor LoomNativeShellSession: LoomShellInteractiveSession {
    public nonisolated let events: AsyncStream<LoomShellEvent>

    private let eventContinuation: AsyncStream<LoomShellEvent>.Continuation
    private let channel: LoomShellChannel
    private var readTask: Task<Void, Never>?
    private var didClose = false
    private var didCloseTransport = false

    public init(channel: LoomShellChannel) {
        self.channel = channel
        let (stream, continuation) = AsyncStream.makeStream(of: LoomShellEvent.self)
        events = stream
        eventContinuation = continuation
    }

    deinit {
        eventContinuation.finish()
        readTask?.cancel()
    }

    public static func open(
        over authenticatedSession: LoomAuthenticatedSession,
        request: LoomShellSessionRequest,
        label: String = LoomShellProtocol.streamLabel
    ) async throws -> LoomNativeShellSession {
        let stream = try await authenticatedSession.openStream(label: label)
        let session = LoomNativeShellSession(channel: LoomShellChannel(stream: stream))
        try await session.start(request: request)
        return session
    }

    public func sendStdin(_ data: Data) async throws {
        try await sendEnvelope(.stdin(data))
    }

    public func resize(_ event: LoomShellResizeEvent) async throws {
        try await sendEnvelope(.resize(event))
    }

    public func close() async {
        if !didCloseTransport {
            didCloseTransport = true
            readTask?.cancel()
            await channel.close()
        }
        guard !didClose else { return }
        didClose = true
        eventContinuation.finish()
    }

    public func start(request: LoomShellSessionRequest) async throws {
        guard readTask == nil else {
            throw LoomShellError.protocolViolation("Shell session has already started.")
        }

        readTask = Task { [weak self] in
            await self?.runReadLoop()
        }
        try await sendEnvelope(.open(request))
    }

    private func sendEnvelope(_ envelope: LoomShellEnvelope) async throws {
        guard !didClose else {
            throw LoomShellError.protocolViolation("Shell session is already closed.")
        }
        try await channel.send(try LoomShellWireCodec.encode(envelope))
    }

    private func runReadLoop() async {
        var iterator = channel.incomingFrames.makeAsyncIterator()
        do {
            while !Task.isCancelled, let frame = await iterator.next() {
                let envelope = try LoomShellWireCodec.decode(frame)
                try handleIncomingEnvelope(envelope)
            }
        } catch {
            if !didClose {
                eventContinuation.yield(.failure(error.localizedDescription))
            }
        }

        didClose = true
        eventContinuation.finish()
    }

    private func handleIncomingEnvelope(_ envelope: LoomShellEnvelope) throws {
        switch envelope {
        case let .ready(event):
            eventContinuation.yield(.ready(event))
        case let .stdout(data):
            eventContinuation.yield(.stdout(data))
        case let .stderr(data):
            eventContinuation.yield(.stderr(data))
        case .heartbeat:
            eventContinuation.yield(.heartbeat)
        case let .exit(event):
            eventContinuation.yield(.exit(event))
        case let .failure(message):
            eventContinuation.yield(.failure(message))
        case .open, .stdin, .resize:
            throw LoomShellError.protocolViolation("Received client-only shell frame on the client session.")
        }
    }
}

/// Host-side shell execution contract.
public protocol LoomShellHostedSession: Sendable {
    var events: AsyncStream<LoomShellEvent> { get }

    func sendStdin(_ data: Data) async throws
    func resize(_ event: LoomShellResizeEvent) async throws
    func close() async
}

/// Factory that binds accepted shell requests to a local or remote host runtime.
public protocol LoomShellHost: Sendable {
    func startSession(request: LoomShellSessionRequest) async throws -> any LoomShellHostedSession
}

/// Host-side stream bridge that turns authenticated Loom shell streams into real shell runtimes.
public actor LoomShellServer {
    private let host: any LoomShellHost

    public init(host: any LoomShellHost) {
        self.host = host
    }

    public func serve(session: LoomAuthenticatedSession) async {
        for await stream in session.incomingStreams {
            guard stream.label == nil || stream.label == LoomShellProtocol.streamLabel else {
                continue
            }
            Task { [host] in
                await LoomShellServer.handleIncomingStream(stream, host: host)
            }
        }
    }

    public func handleIncomingStream(_ stream: LoomMultiplexedStream) async {
        await Self.handleIncomingStream(stream, host: host)
    }

    private static func handleIncomingStream(
        _ stream: LoomMultiplexedStream,
        host: any LoomShellHost
    ) async {
        let channel = LoomShellChannel(stream: stream)
        var iterator = channel.incomingFrames.makeAsyncIterator()

        do {
            guard let firstFrame = await iterator.next() else {
                await channel.close()
                return
            }

            guard case let .open(request) = try LoomShellWireCodec.decode(firstFrame) else {
                try await channel.send(
                    LoomShellWireCodec.encode(
                        .failure("First shell frame must be an open request.")
                    )
                )
                await channel.close()
                return
            }

            let remainingFrames = AsyncStream<Data> { continuation in
                let pump = LoomShellFramePump(iterator: iterator)
                Task {
                    while let frame = await pump.next() {
                        continuation.yield(frame)
                    }
                    continuation.finish()
                }
            }
            let hostedSession = try await host.startSession(request: request)
            await runBridge(
                channel: channel,
                remainingFrames: remainingFrames,
                hostedSession: hostedSession
            )
        } catch {
            try? await channel.send(
                LoomShellWireCodec.encode(.failure(error.localizedDescription))
            )
            await channel.close()
        }
    }

    private static func runBridge(
        channel: LoomShellChannel,
        remainingFrames: AsyncStream<Data>,
        hostedSession: any LoomShellHostedSession
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await pumpHostedEvents(
                    from: hostedSession.events,
                    to: channel
                )
            }
            group.addTask {
                await pumpClientFrames(
                    from: remainingFrames,
                    to: hostedSession,
                    channel: channel
                )
            }

            _ = await group.next()
            await hostedSession.close()
            await channel.close()
            group.cancelAll()
            while await group.next() != nil {}
        }
    }

    private static func pumpHostedEvents(
        from events: AsyncStream<LoomShellEvent>,
        to channel: LoomShellChannel
    ) async {
        for await event in events {
            do {
                try await channel.send(try LoomShellWireCodec.encode(envelope(for: event)))
            } catch {
                return
            }

            if case .exit = event {
                return
            }
            if case .failure = event {
                return
            }
        }
    }

    private static func pumpClientFrames(
        from frames: AsyncStream<Data>,
        to hostedSession: any LoomShellHostedSession,
        channel: LoomShellChannel
    ) async {
        do {
            for await frame in frames {
                let envelope = try LoomShellWireCodec.decode(frame)
                switch envelope {
                case let .stdin(data):
                    try await hostedSession.sendStdin(data)
                case let .resize(event):
                    try await hostedSession.resize(event)
                case .heartbeat:
                    break
                case .open, .stdout, .stderr, .exit, .ready:
                    throw LoomShellError.protocolViolation("Received a host-only shell frame from the client.")
                case let .failure(message):
                    throw LoomShellError.remoteFailure(message)
                }
            }
        } catch {
            try? await channel.send(
                LoomShellWireCodec.encode(.failure(error.localizedDescription))
            )
        }
    }

    private static func envelope(for event: LoomShellEvent) -> LoomShellEnvelope {
        switch event {
        case let .ready(ready):
            .ready(ready)
        case let .stdout(data):
            .stdout(data)
        case let .stderr(data):
            .stderr(data)
        case .heartbeat:
            .heartbeat
        case let .exit(exit):
            .exit(exit)
        case let .failure(message):
            .failure(message)
        }
    }
}

private final class LoomShellFramePump: @unchecked Sendable {
    private var iterator: AsyncStream<Data>.Iterator

    init(iterator: AsyncStream<Data>.Iterator) {
        self.iterator = iterator
    }

    func next() async -> Data? {
        await iterator.next()
    }
}
