//
//  LoomTransportKind.swift
//  Loom
//
//  Created by Codex on 3/9/26.
//

import Foundation

/// Direct transport kinds supported by Loom session establishment.
public enum LoomTransportKind: String, Codable, CaseIterable, Sendable {
    case tcp
    case quic
}

