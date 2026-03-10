//
//  LoomShellProtocol.swift
//  LoomShell
//
//  Created by Codex on 3/9/26.
//

import Foundation
import Loom

/// Stable Loom-native stream label used for interactive shell streams.
public enum LoomShellProtocol {
    public static let streamLabel = "loom.shell.v1"
    public static let nativeFeature = "loom.shell.native.v1"
    public static let openSSHFallbackFeature = "loom.shell.ssh-fallback.v1"
}

/// Initial native shell session request.
public struct LoomShellSessionRequest: Codable, Sendable, Equatable {
    public let command: String?
    public let environment: [String: String]
    public let workingDirectory: String?
    public let terminalType: String
    public let columns: Int
    public let rows: Int

    public init(
        command: String? = nil,
        environment: [String: String] = [:],
        workingDirectory: String? = nil,
        terminalType: String = "xterm-256color",
        columns: Int = 80,
        rows: Int = 24
    ) {
        self.command = command
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.terminalType = terminalType
        self.columns = max(1, columns)
        self.rows = max(1, rows)
    }
}

/// Native shell resize control event.
public struct LoomShellResizeEvent: Codable, Sendable, Equatable {
    public let columns: Int
    public let rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
    }
}

/// Native shell session metadata emitted when the host accepts a session request.
public struct LoomShellReadyEvent: Codable, Sendable, Equatable {
    public let mergesStandardError: Bool

    public init(mergesStandardError: Bool) {
        self.mergesStandardError = mergesStandardError
    }
}

/// Exit notification emitted by a Loom native shell session.
public struct LoomShellExitEvent: Codable, Sendable, Equatable {
    public let exitCode: Int32

    public init(exitCode: Int32) {
        self.exitCode = exitCode
    }
}

/// Runtime events surfaced by interactive shell sessions.
public enum LoomShellEvent: Sendable, Equatable {
    case ready(LoomShellReadyEvent)
    case stdout(Data)
    case stderr(Data)
    case heartbeat
    case exit(LoomShellExitEvent)
    case failure(String)
}

/// Wire events carried over a Loom-native shell stream.
public enum LoomShellEnvelope: Codable, Sendable, Equatable {
    case open(LoomShellSessionRequest)
    case stdin(Data)
    case stdout(Data)
    case stderr(Data)
    case resize(LoomShellResizeEvent)
    case heartbeat
    case exit(LoomShellExitEvent)
    case ready(LoomShellReadyEvent)
    case failure(String)
}

/// Generic shell frame transport that can be backed by Loom streams or tests.
public struct LoomShellChannel: Sendable {
    public let incomingFrames: AsyncStream<Data>

    private let sendHandler: @Sendable (Data) async throws -> Void
    private let closeHandler: @Sendable () async -> Void

    public init(
        incomingFrames: AsyncStream<Data>,
        send: @escaping @Sendable (Data) async throws -> Void,
        close: @escaping @Sendable () async -> Void
    ) {
        self.incomingFrames = incomingFrames
        sendHandler = send
        closeHandler = close
    }

    public init(stream: LoomMultiplexedStream) {
        incomingFrames = stream.incomingBytes
        sendHandler = { data in
            try await stream.send(data)
        }
        closeHandler = {
            try? await stream.close()
        }
    }

    public func send(_ data: Data) async throws {
        try await sendHandler(data)
    }

    public func close() async {
        await closeHandler()
    }
}

enum LoomShellWireCodec {
    private enum FrameType: UInt8 {
        case open = 1
        case stdin = 2
        case stdout = 3
        case stderr = 4
        case resize = 5
        case heartbeat = 6
        case exit = 7
        case ready = 8
        case failure = 9
    }

    static func encode(_ envelope: LoomShellEnvelope) throws -> Data {
        switch envelope {
        case let .open(request):
            return try encodeJSONFrame(type: .open, value: request)
        case let .stdin(data):
            return encodeRawFrame(type: .stdin, payload: data)
        case let .stdout(data):
            return encodeRawFrame(type: .stdout, payload: data)
        case let .stderr(data):
            return encodeRawFrame(type: .stderr, payload: data)
        case let .resize(event):
            return try encodeJSONFrame(type: .resize, value: event)
        case .heartbeat:
            return Data([FrameType.heartbeat.rawValue])
        case let .exit(event):
            return try encodeJSONFrame(type: .exit, value: event)
        case let .ready(event):
            return try encodeJSONFrame(type: .ready, value: event)
        case let .failure(message):
            return encodeRawFrame(type: .failure, payload: Data(message.utf8))
        }
    }

    static func decode(_ data: Data) throws -> LoomShellEnvelope {
        guard let frameType = data.first.flatMap(FrameType.init(rawValue:)) else {
            throw LoomShellError.protocolViolation("Received an empty or unknown shell frame.")
        }

        let payload = Data(data.dropFirst())
        switch frameType {
        case .open:
            return .open(try decodeJSONPayload(LoomShellSessionRequest.self, from: payload))
        case .stdin:
            return .stdin(payload)
        case .stdout:
            return .stdout(payload)
        case .stderr:
            return .stderr(payload)
        case .resize:
            return .resize(try decodeJSONPayload(LoomShellResizeEvent.self, from: payload))
        case .heartbeat:
            guard payload.isEmpty else {
                throw LoomShellError.protocolViolation("Heartbeat frames must not include a payload.")
            }
            return .heartbeat
        case .exit:
            return .exit(try decodeJSONPayload(LoomShellExitEvent.self, from: payload))
        case .ready:
            return .ready(try decodeJSONPayload(LoomShellReadyEvent.self, from: payload))
        case .failure:
            guard let message = String(data: payload, encoding: .utf8) else {
                throw LoomShellError.protocolViolation("Failure frames must contain UTF-8 payloads.")
            }
            return .failure(message)
        }
    }

    private static func encodeRawFrame(type: FrameType, payload: Data) -> Data {
        var data = Data([type.rawValue])
        data.append(payload)
        return data
    }

    private static func encodeJSONFrame<T: Encodable>(type: FrameType, value: T) throws -> Data {
        var data = Data([type.rawValue])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        data.append(try encoder.encode(value))
        return data
    }

    private static func decodeJSONPayload<T: Decodable>(_ type: T.Type, from payload: Data) throws -> T {
        try JSONDecoder().decode(type, from: payload)
    }
}
