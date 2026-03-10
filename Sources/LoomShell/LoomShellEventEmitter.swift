//
//  LoomShellEventEmitter.swift
//  LoomShell
//
//  Created by Codex on 3/9/26.
//

import Foundation

final class LoomShellEventEmitter: @unchecked Sendable {
    let stream: AsyncStream<LoomShellEvent>

    private let lock = NSLock()
    private var continuation: AsyncStream<LoomShellEvent>.Continuation?

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: LoomShellEvent.self)
        self.stream = stream
        self.continuation = continuation
    }

    func yield(_ event: LoomShellEvent) {
        lock.lock()
        let continuation = continuation
        lock.unlock()
        continuation?.yield(event)
    }

    func finish() {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.finish()
    }
}
