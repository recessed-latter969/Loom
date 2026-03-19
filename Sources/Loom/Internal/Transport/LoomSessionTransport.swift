//
//  LoomSessionTransport.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/19/26.
//

import Foundation

/// Abstraction over the framing/delivery layer beneath an authenticated Loom session.
///
/// `LoomFramedConnection` (TCP/QUIC) and `LoomReliableChannel` (UDP) both conform,
/// allowing `LoomAuthenticatedSession` to be transport-agnostic.
package protocol LoomSessionTransport: Sendable {
    /// Block until the underlying connection is ready for I/O.
    func awaitReady() async throws

    /// Send a complete message (may be length-prefixed for TCP or packetized for UDP).
    func sendMessage(_ data: Data) async throws

    /// Receive the next complete message. `maxBytes` is advisory and may be ignored
    /// by datagram-based transports where message boundaries are inherent.
    func receiveMessage(maxBytes: Int) async throws -> Data
}
