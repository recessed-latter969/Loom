//
//  LoomLocalShellHost.swift
//  LoomShell
//
//  Created by Codex on 3/9/26.
//

import Foundation
import Loom

/// macOS host runtime that executes shell sessions behind a local PTY.
public struct LoomLocalShellHost: LoomShellHost {
    public init() {}

    public func startSession(request: LoomShellSessionRequest) async throws -> any LoomShellHostedSession {
#if os(macOS)
        try LoomLocalPTYHostedSession(request: request)
#else
        throw LoomShellError.unsupported("PTY hosting is only available on macOS.")
#endif
    }
}

#if os(macOS)
import Darwin

private final class LoomLocalPTYHostedSession: LoomShellHostedSession, @unchecked Sendable {
    let events: AsyncStream<LoomShellEvent>

    private let emitter: LoomShellEventEmitter
    private let process: Process
    private let masterFileDescriptor: Int32
    private let readSource: DispatchSourceRead
    private let stateLock = NSLock()
    private var didClose = false

    init(request: LoomShellSessionRequest) throws {
        emitter = LoomShellEventEmitter()
        events = emitter.stream
        process = Process()

        var master: Int32 = 0
        var slave: Int32 = 0
        var windowSize = winsize(
            ws_row: UInt16(clamping: request.rows),
            ws_col: UInt16(clamping: request.columns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        guard openpty(&master, &slave, nil, nil, &windowSize) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        masterFileDescriptor = master
        readSource = DispatchSource.makeReadSource(
            fileDescriptor: master,
            queue: DispatchQueue(label: "com.loom.shell.local-pty")
        )

        let shellPath = Self.resolvedShellPath(environment: request.environment)
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = Self.arguments(for: request)
        process.environment = Self.environment(for: request)
        if let workingDirectory = request.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }

        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        do {
            try process.run()
            Darwin.close(slave)
        } catch {
            Darwin.close(master)
            Darwin.close(slave)
            throw error
        }

        process.terminationHandler = { [weak self] process in
            self?.handleTermination(process)
        }
        readSource.setEventHandler { [weak self] in
            self?.readAvailableOutput()
        }
        readSource.setCancelHandler { [master] in
            Darwin.close(master)
        }
        readSource.resume()

        emitter.yield(.ready(.init(mergesStandardError: true)))
    }

    func sendStdin(_ data: Data) async throws {
        try Self.withOpenState(lock: stateLock, didClose: &didClose) {
            var remaining = data
            while !remaining.isEmpty {
                let written = remaining.withUnsafeBytes { bytes in
                    write(masterFileDescriptor, bytes.baseAddress, remaining.count)
                }
                if written < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                remaining.removeFirst(written)
            }
        }
    }

    func resize(_ event: LoomShellResizeEvent) async throws {
        try Self.withOpenState(lock: stateLock, didClose: &didClose) {
            var windowSize = winsize(
                ws_row: UInt16(clamping: event.rows),
                ws_col: UInt16(clamping: event.columns),
                ws_xpixel: 0,
                ws_ypixel: 0
            )
            guard ioctl(masterFileDescriptor, TIOCSWINSZ, &windowSize) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            _ = kill(process.processIdentifier, SIGWINCH)
        }
    }

    func close() async {
        let alreadyClosed = markClosed()
        guard !alreadyClosed else { return }
        readSource.cancel()
        if process.isRunning {
            process.terminate()
        } else {
            emitter.finish()
        }
    }

    private func readAvailableOutput() {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let result = read(masterFileDescriptor, &buffer, buffer.count)
            if result > 0 {
                emitter.yield(.stdout(Data(buffer.prefix(result))))
                continue
            }
            if result == 0 {
                readSource.cancel()
                return
            }

            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                return
            }

            emitter.yield(.failure("Local PTY read failed: \(String(cString: strerror(errno)))"))
            emitter.finish()
            readSource.cancel()
            return
        }
    }

    private func handleTermination(_ process: Process) {
        _ = markClosed()

        let exitCode: Int32
        switch process.terminationReason {
        case .exit:
            exitCode = process.terminationStatus
        case .uncaughtSignal:
            exitCode = -process.terminationStatus
        @unknown default:
            exitCode = process.terminationStatus
        }

        emitter.yield(.exit(.init(exitCode: exitCode)))
        emitter.finish()
        readSource.cancel()
    }

    private static func resolvedShellPath(environment: [String: String]) -> String {
        if let shell = environment["SHELL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !shell.isEmpty {
            return shell
        }
        if let shell = ProcessInfo.processInfo.environment["SHELL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !shell.isEmpty {
            return shell
        }
        return "/bin/zsh"
    }

    private static func arguments(for request: LoomShellSessionRequest) -> [String] {
        if let command = request.command?.trimmingCharacters(in: .whitespacesAndNewlines),
           !command.isEmpty {
            return ["-lc", command]
        }
        return ["-l"]
    }

    private static func environment(for request: LoomShellSessionRequest) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment.merge(request.environment, uniquingKeysWith: { _, new in new })
        environment["TERM"] = request.terminalType
        environment["COLUMNS"] = String(request.columns)
        environment["LINES"] = String(request.rows)
        return environment
    }

    private static func withOpenState<T>(
        lock: NSLock,
        didClose: inout Bool,
        body: () throws -> T
    ) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard !didClose else {
            throw LoomShellError.protocolViolation("Local shell session is already closed.")
        }
        return try body()
    }

    private func markClosed() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        let alreadyClosed = didClose
        didClose = true
        return alreadyClosed
    }
}
#endif
