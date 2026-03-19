//
//  LoomReliablePacketHeader.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/19/26.
//

import Foundation

/// Size of the reliable-UDP packet header in bytes.
package let loomReliableHeaderSize: Int = 26

/// Flags for reliable-UDP packets.
package struct LoomReliablePacketFlags: OptionSet, Sendable {
    package let rawValue: UInt8

    package init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Packet requires acknowledgment from the peer.
    package static let reliable = LoomReliablePacketFlags(rawValue: 1 << 0)
    /// Message is fragmented across multiple packets.
    package static let fragment = LoomReliablePacketFlags(rawValue: 1 << 1)
    /// Pure acknowledgment — no payload.
    package static let ackOnly = LoomReliablePacketFlags(rawValue: 1 << 2)
    /// Pre-encryption handshake packet (hello exchange).
    package static let hello = LoomReliablePacketFlags(rawValue: 1 << 3)
    /// Connection teardown.
    package static let fin = LoomReliablePacketFlags(rawValue: 1 << 4)
}

/// 26-byte header for Loom reliable-UDP packets.
///
/// Wire layout (little-endian):
/// ```
/// [0..3]   magic           UInt32 = 0x4C4F4D55 ("LOMU")
/// [4]      version         UInt8
/// [5]      flags           UInt8
/// [6..7]   streamID        UInt16
/// [8..11]  sequence        UInt32
/// [12..15] ackSequence     UInt32
/// [16..19] ackBitmap       UInt32
/// [20..21] fragmentIndex   UInt16
/// [22..23] fragmentCount   UInt16
/// [24..25] payloadLength   UInt16
/// ```
package struct LoomReliablePacketHeader: Sendable {
    package var magic: UInt32 = loomReliablePacketMagic
    package var version: UInt8 = loomProtocolVersion
    package var flags: LoomReliablePacketFlags
    package var streamID: UInt16
    package var sequence: UInt32
    package var ackSequence: UInt32
    package var ackBitmap: UInt32
    package var fragmentIndex: UInt16
    package var fragmentCount: UInt16
    package var payloadLength: UInt16

    package init(
        flags: LoomReliablePacketFlags = [],
        streamID: UInt16 = 0,
        sequence: UInt32 = 0,
        ackSequence: UInt32 = 0,
        ackBitmap: UInt32 = 0,
        fragmentIndex: UInt16 = 0,
        fragmentCount: UInt16 = 1,
        payloadLength: UInt16 = 0
    ) {
        self.flags = flags
        self.streamID = streamID
        self.sequence = sequence
        self.ackSequence = ackSequence
        self.ackBitmap = ackBitmap
        self.fragmentIndex = fragmentIndex
        self.fragmentCount = fragmentCount
        self.payloadLength = payloadLength
    }

    package func serialize() -> Data {
        var data = Data(capacity: loomReliableHeaderSize)
        withUnsafeBytes(of: magic.littleEndian) { data.append(contentsOf: $0) }
        data.append(version)
        data.append(flags.rawValue)
        withUnsafeBytes(of: streamID.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: sequence.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: ackSequence.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: ackBitmap.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: fragmentIndex.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: fragmentCount.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: payloadLength.littleEndian) { data.append(contentsOf: $0) }
        return data
    }

    package static func deserialize(from data: Data) -> LoomReliablePacketHeader? {
        guard data.count >= loomReliableHeaderSize else { return nil }

        var offset = 0

        func read<T: FixedWidthInteger>(_: T.Type) -> T {
            let value = data.withUnsafeBytes { ptr in
                ptr.loadUnaligned(fromByteOffset: offset, as: T.self)
            }
            offset += MemoryLayout<T>.size
            return T(littleEndian: value)
        }

        func readByte() -> UInt8 {
            let value = data[data.startIndex + offset]
            offset += 1
            return value
        }

        let magic = read(UInt32.self)
        guard magic == loomReliablePacketMagic else { return nil }

        let version = readByte()
        guard version == loomProtocolVersion else { return nil }

        let flags = LoomReliablePacketFlags(rawValue: readByte())
        let streamID = read(UInt16.self)
        let sequence = read(UInt32.self)
        let ackSequence = read(UInt32.self)
        let ackBitmap = read(UInt32.self)
        let fragmentIndex = read(UInt16.self)
        let fragmentCount = read(UInt16.self)
        let payloadLength = read(UInt16.self)

        return LoomReliablePacketHeader(
            flags: flags,
            streamID: streamID,
            sequence: sequence,
            ackSequence: ackSequence,
            ackBitmap: ackBitmap,
            fragmentIndex: fragmentIndex,
            fragmentCount: fragmentCount,
            payloadLength: payloadLength
        )
    }
}

/// Maximum payload bytes per reliable-UDP fragment.
package let loomReliableMaxFragmentPayload: Int = loomDefaultMaxPacketSize - loomReliableHeaderSize
