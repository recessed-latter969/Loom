//
//  LoomReliableChannel.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/19/26.
//

import Foundation
import Network

/// Reliable datagram transport for Loom sessions over UDP.
///
/// Provides ordered, reliable delivery of arbitrary-size messages on top of an
/// `NWConnection` configured for UDP. Implements selective-ACK with piggyback
/// acknowledgments, automatic retransmission, and transparent fragmentation
/// for messages exceeding a single datagram.
package actor LoomReliableChannel: LoomSessionTransport {
    private let connection: NWConnection

    // MARK: - Send State

    private var nextSequence: UInt32 = 0
    private var pendingAcks: [UInt32: PendingPacket] = [:]
    private var retryTimer: DispatchSourceTimer?
    private let sendQueue = DispatchQueue(label: "loom.reliable.send", qos: .userInteractive)

    // MARK: - Receive State

    private var highestContiguousReceived: UInt32 = 0
    private var receivedBeyondContiguous: Set<UInt32> = []
    private var hasReceivedFirstPacket = false
    private var fragments: [FragmentKey: FragmentAssembly] = [:]
    private var needsAck = false

    // MARK: - Delivery

    private var deliveryContinuation: AsyncStream<Data>.Continuation?
    private let deliveryStream: AsyncStream<Data>

    // MARK: - RTT Estimation

    private var smoothedRTT: Double = 0.2
    private var rttVariance: Double = 0.1
    private var rto: Double = 0.5

    // MARK: - Configuration

    private let maxRetries = 5
    private let ackCoalesceInterval: Double = 0.02
    private let fragmentPruneInterval: Double = 5.0

    // MARK: - Lifecycle

    private var receiveTask: Task<Void, Never>?
    private var ackTask: Task<Void, Never>?
    private var isClosed = false

    package init(connection: NWConnection) {
        self.connection = connection
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        deliveryStream = stream
        deliveryContinuation = continuation
    }

    deinit {
        retryTimer?.cancel()
        receiveTask?.cancel()
        ackTask?.cancel()
        deliveryContinuation?.finish()
    }

    // MARK: - LoomSessionTransport

    package func awaitReady() async throws {
        // UDP connections transition to .ready almost instantly after start() —
        // often before this method is called. Check current state first to avoid
        // a lost-event race where the .ready transition already fired.
        if connection.state != .ready {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let box = ReadyContinuationBox(continuation: continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        box.complete(.success(()))
                    case let .failed(error):
                        box.complete(.failure(LoomError.connectionFailed(error)))
                    case .cancelled:
                        box.complete(.failure(LoomError.connectionFailed(CancellationError())))
                    default:
                        break
                    }
                }
            }
        }
        startReceiveLoop()
        startRetryTimer()
    }

    package func sendMessage(_ data: Data) async throws {
        guard !isClosed else {
            throw LoomError.protocolError("Reliable channel is closed.")
        }

        let fragmentPayload = loomReliableMaxFragmentPayload
        if data.count <= fragmentPayload {
            let seq = allocateSequence()
            let header = LoomReliablePacketHeader(
                flags: .reliable,
                sequence: seq,
                ackSequence: currentAckSequence(),
                ackBitmap: currentAckBitmap(),
                fragmentIndex: 0,
                fragmentCount: 1,
                payloadLength: UInt16(data.count)
            )
            let packet = header.serialize() + data
            trackPending(seq: seq, packet: packet)
            clearNeedsAck()
            try await sendRaw(packet)
        } else {
            let totalFragments = (data.count + fragmentPayload - 1) / fragmentPayload
            guard totalFragments <= Int(UInt16.max) else {
                throw LoomError.protocolError("Message too large to fragment (\(data.count) bytes).")
            }

            for i in 0..<totalFragments {
                let start = i * fragmentPayload
                let end = min(start + fragmentPayload, data.count)
                let chunk = data[start..<end]
                let seq = allocateSequence()

                let header = LoomReliablePacketHeader(
                    flags: [.reliable, .fragment],
                    sequence: seq,
                    ackSequence: currentAckSequence(),
                    ackBitmap: currentAckBitmap(),
                    fragmentIndex: UInt16(i),
                    fragmentCount: UInt16(totalFragments),
                    payloadLength: UInt16(chunk.count)
                )
                let packet = header.serialize() + chunk
                trackPending(seq: seq, packet: packet)
                clearNeedsAck()
                try await sendRaw(packet)
            }
        }
    }

    package func receiveMessage(maxBytes: Int) async throws -> Data {
        for await message in deliveryStream {
            if message.count > maxBytes {
                throw LoomError.protocolError(
                    "Received message exceeds limit: \(message.count) > \(maxBytes)"
                )
            }
            return message
        }
        throw LoomError.connectionFailed(CancellationError())
    }

    /// Send a message without requiring acknowledgment (fire-and-forget).
    package func sendUnreliable(_ data: Data) async throws {
        guard !isClosed else { return }

        let seq = allocateSequence()
        let header = LoomReliablePacketHeader(
            flags: [],
            sequence: seq,
            ackSequence: currentAckSequence(),
            ackBitmap: currentAckBitmap(),
            fragmentIndex: 0,
            fragmentCount: 1,
            payloadLength: UInt16(data.count)
        )
        clearNeedsAck()
        try await sendRaw(header.serialize() + data)
    }

    package func close() {
        guard !isClosed else { return }
        isClosed = true
        retryTimer?.cancel()
        receiveTask?.cancel()
        ackTask?.cancel()
        deliveryContinuation?.finish()
        deliveryContinuation = nil
        connection.cancel()
    }

    // MARK: - Sequence Management

    private func allocateSequence() -> UInt32 {
        let seq = nextSequence
        nextSequence &+= 1
        return seq
    }

    // MARK: - Ack State

    private func currentAckSequence() -> UInt32 {
        highestContiguousReceived
    }

    private func currentAckBitmap() -> UInt32 {
        var bitmap: UInt32 = 0
        let base = highestContiguousReceived
        for seq in receivedBeyondContiguous {
            let diff = seq &- base
            if diff >= 1 && diff <= 32 {
                bitmap |= 1 << (diff - 1)
            }
        }
        return bitmap
    }

    private func recordReceivedSequence(_ seq: UInt32) {
        if !hasReceivedFirstPacket {
            hasReceivedFirstPacket = true
            highestContiguousReceived = seq
            return
        }

        let diff = Int32(bitPattern: seq &- highestContiguousReceived)

        if diff <= 0 {
            // Already received or old — ignore
            return
        }

        if diff == 1 {
            highestContiguousReceived = seq
            // Advance past any buffered contiguous sequences
            while receivedBeyondContiguous.remove(highestContiguousReceived &+ 1) != nil {
                highestContiguousReceived &+= 1
            }
        } else {
            receivedBeyondContiguous.insert(seq)
            // Prune entries too far behind
            let pruneThreshold = highestContiguousReceived &+ 64
            receivedBeyondContiguous = receivedBeyondContiguous.filter { s in
                let d = Int32(bitPattern: s &- highestContiguousReceived)
                return d > 0 && s &- highestContiguousReceived <= 64
            }
            _ = pruneThreshold
        }
    }

    private func processIncomingAck(ackSequence: UInt32, ackBitmap: UInt32) {
        // Remove acked packets
        pendingAcks.removeValue(forKey: ackSequence)

        // Process bitmap — bit N means (ackSequence + N + 1) is also acked
        for bit in 0..<32 {
            if ackBitmap & (1 << bit) != 0 {
                let ackedSeq = ackSequence &+ UInt32(bit) &+ 1
                if let pending = pendingAcks.removeValue(forKey: ackedSeq) {
                    updateRTT(sample: CFAbsoluteTimeGetCurrent() - pending.sentAt)
                }
            }
        }

        // Also ack everything up to ackSequence
        let toRemove = pendingAcks.keys.filter { key in
            let diff = Int32(bitPattern: ackSequence &- key)
            return diff >= 0
        }
        for key in toRemove {
            if let pending = pendingAcks.removeValue(forKey: key) {
                updateRTT(sample: CFAbsoluteTimeGetCurrent() - pending.sentAt)
            }
        }
    }

    private func clearNeedsAck() {
        needsAck = false
    }

    // MARK: - RTT Estimation

    private func updateRTT(sample: Double) {
        guard sample > 0 else { return }
        // EWMA: smoothedRTT = 0.875 * smoothedRTT + 0.125 * sample
        smoothedRTT = 0.875 * smoothedRTT + 0.125 * sample
        rttVariance = 0.75 * rttVariance + 0.25 * abs(sample - smoothedRTT)
        rto = max(0.1, smoothedRTT + 4 * rttVariance)
    }

    // MARK: - Pending Packet Tracking

    private struct PendingPacket {
        let packet: Data
        var sentAt: CFAbsoluteTime
        var retryCount: Int
    }

    private func trackPending(seq: UInt32, packet: Data) {
        pendingAcks[seq] = PendingPacket(
            packet: packet,
            sentAt: CFAbsoluteTimeGetCurrent(),
            retryCount: 0
        )
    }

    // MARK: - Retry Timer

    private func startRetryTimer() {
        let timer = DispatchSource.makeTimerSource(queue: sendQueue)
        timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task {
                await self.retryExpiredPackets()
            }
        }
        timer.resume()
        retryTimer = timer
    }

    private func retryExpiredPackets() {
        let now = CFAbsoluteTimeGetCurrent()
        var failed = false

        for (seq, var pending) in pendingAcks {
            if now - pending.sentAt >= rto {
                if pending.retryCount >= maxRetries {
                    failed = true
                    break
                }
                pending.retryCount += 1
                pending.sentAt = now

                // Update ack fields in the retransmitted packet
                var retransmitPacket = pending.packet
                let ackSeq = currentAckSequence()
                let ackBmp = currentAckBitmap()
                retransmitPacket.withUnsafeMutableBytes { buf in
                    buf.storeBytes(of: ackSeq.littleEndian, toByteOffset: 12, as: UInt32.self)
                    buf.storeBytes(of: ackBmp.littleEndian, toByteOffset: 16, as: UInt32.self)
                }

                pendingAcks[seq] = pending
                connection.send(content: retransmitPacket, completion: .idempotent)
            }
        }

        if failed {
            close()
        }

        // Send dedicated ack if peer is waiting
        if needsAck {
            needsAck = false
            let header = LoomReliablePacketHeader(
                flags: .ackOnly,
                ackSequence: currentAckSequence(),
                ackBitmap: currentAckBitmap()
            )
            connection.send(content: header.serialize(), completion: .idempotent)
        }

        // Prune stale fragment assemblies
        for (key, assembly) in fragments {
            if now - assembly.createdAt > fragmentPruneInterval {
                fragments.removeValue(forKey: key)
            }
        }
    }

    // MARK: - Receive Loop

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let data = try await self.receiveRawDatagram()
                    await self.handleIncomingPacket(data)
                } catch {
                    if !Task.isCancelled {
                        await self.close()
                    }
                    break
                }
            }
        }
    }

    private func handleIncomingPacket(_ data: Data) {
        guard let header = LoomReliablePacketHeader.deserialize(from: data) else {
            return
        }

        // Process piggyback acks
        if hasReceivedFirstPacket || header.flags.contains(.ackOnly) {
            processIncomingAck(ackSequence: header.ackSequence, ackBitmap: header.ackBitmap)
        }

        // Pure ack — no payload to deliver
        if header.flags.contains(.ackOnly) {
            return
        }

        // Record this sequence for our outgoing acks
        recordReceivedSequence(header.sequence)

        if header.flags.contains(.reliable) {
            needsAck = true
            scheduleAckIfNeeded()
        }

        let payloadStart = loomReliableHeaderSize
        let payloadEnd = payloadStart + Int(header.payloadLength)
        guard data.count >= payloadEnd else { return }
        let payload = Data(data[payloadStart..<payloadEnd])

        if header.flags.contains(.fragment) {
            handleFragment(header: header, payload: payload)
        } else {
            deliveryContinuation?.yield(payload)
        }
    }

    private func scheduleAckIfNeeded() {
        guard ackTask == nil || ackTask?.isCancelled == true else { return }
        ackTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(20))
            guard let self, !Task.isCancelled else { return }
            await self.sendDedicatedAckIfNeeded()
        }
    }

    private func sendDedicatedAckIfNeeded() {
        guard needsAck else { return }
        needsAck = false
        let header = LoomReliablePacketHeader(
            flags: .ackOnly,
            ackSequence: currentAckSequence(),
            ackBitmap: currentAckBitmap()
        )
        connection.send(content: header.serialize(), completion: .idempotent)
    }

    // MARK: - Fragment Reassembly

    private struct FragmentKey: Hashable {
        let streamID: UInt16
        let firstSequence: UInt32
    }

    private struct FragmentAssembly {
        let fragmentCount: UInt16
        var fragments: [UInt16: Data]
        let createdAt: CFAbsoluteTime

        var isComplete: Bool { fragments.count == Int(fragmentCount) }

        func reassemble() -> Data {
            var result = Data()
            for i in 0..<fragmentCount {
                if let chunk = fragments[i] {
                    result.append(chunk)
                }
            }
            return result
        }
    }

    private func handleFragment(header: LoomReliablePacketHeader, payload: Data) {
        let firstSeq = header.sequence &- UInt32(header.fragmentIndex)
        let key = FragmentKey(streamID: header.streamID, firstSequence: firstSeq)

        var assembly = fragments[key] ?? FragmentAssembly(
            fragmentCount: header.fragmentCount,
            fragments: [:],
            createdAt: CFAbsoluteTimeGetCurrent()
        )

        assembly.fragments[header.fragmentIndex] = payload
        if assembly.isComplete {
            fragments.removeValue(forKey: key)
            deliveryContinuation?.yield(assembly.reassemble())
        } else {
            fragments[key] = assembly
        }
    }

    // MARK: - Raw I/O

    private func sendRaw(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: LoomError.connectionFailed(error))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receiveRawDatagram() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receiveMessage { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: LoomError.connectionFailed(error))
                    return
                }
                if let data {
                    continuation.resume(returning: data)
                    return
                }
                if isComplete {
                    continuation.resume(throwing: LoomError.connectionFailed(CancellationError()))
                    return
                }
                continuation.resume(
                    throwing: LoomError.protocolError("No data received from UDP connection.")
                )
            }
        }
    }
}

// MARK: - Continuation Safety

private final class ReadyContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func complete(_ result: Result<Void, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()

        switch result {
        case .success:
            continuation.resume()
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}
