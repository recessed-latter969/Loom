//
//  LoomHostCatalog.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/10/26.
//

import Foundation

/// One app entry published by a shared Loom host.
public struct LoomHostCatalogEntry: Codable, Hashable, Sendable, Identifiable {
    public let appID: String
    public let displayName: String
    public let metadata: [String: String]
    public let supportedFeatures: [String]

    public var id: String { appID }

    public init(
        appID: String,
        displayName: String,
        metadata: [String: String] = [:],
        supportedFeatures: [String] = []
    ) {
        let normalizedAppID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.appID = normalizedAppID.isEmpty ? "unknown.app" : normalizedAppID

        let normalizedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = normalizedDisplayName.isEmpty ? self.appID : normalizedDisplayName

        var normalizedMetadata: [String: String] = [:]
        for (key, value) in metadata {
            let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedKey.isEmpty, !trimmedValue.isEmpty else {
                continue
            }
            normalizedMetadata[trimmedKey] = trimmedValue
        }
        self.metadata = normalizedMetadata
        self.supportedFeatures = Array(
            Set(
                supportedFeatures
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        )
        .sorted()
    }
}

/// Catalog of app identities exposed by one shared Loom host.
public struct LoomHostCatalog: Codable, Hashable, Sendable {
    public let entries: [LoomHostCatalogEntry]

    public init(entries: [LoomHostCatalogEntry]) {
        var deduplicated: [String: LoomHostCatalogEntry] = [:]
        for entry in entries {
            deduplicated[entry.appID] = entry
        }
        self.entries = deduplicated.values.sorted { lhs, rhs in
            if lhs.displayName != rhs.displayName {
                return lhs.displayName < rhs.displayName
            }
            return lhs.appID < rhs.appID
        }
    }
}

/// Resolved synthetic peer projected from a shared host advertisement.
public struct LoomHostCatalogProjection: Hashable, Sendable {
    public let peerID: LoomPeerID
    public let displayName: String
    public let advertisement: LoomPeerAdvertisement
    public let supportedFeatures: [String]

    public init(
        peerID: LoomPeerID,
        displayName: String,
        advertisement: LoomPeerAdvertisement,
        supportedFeatures: [String]
    ) {
        self.peerID = peerID
        self.displayName = displayName
        self.advertisement = advertisement
        self.supportedFeatures = supportedFeatures
    }
}

/// Loom-owned codec for the shared-host catalog metadata payload.
public enum LoomHostCatalogCodec {
    public static let metadataKey = "loom.host.catalog.v1"
    public static let targetAppIDKey = "loom.host.target-app.v1"
    public static let sourceAppIDKey = "loom.host.source-app.v1"

    public static func addingCatalog(
        _ catalog: LoomHostCatalog?,
        to metadata: [String: String]
    ) throws -> [String: String] {
        var metadata = metadata
        if let catalog, !catalog.entries.isEmpty {
            let encoded = try JSONEncoder().encode(catalog)
            metadata[metadataKey] = encoded.base64EncodedString()
        } else {
            metadata.removeValue(forKey: metadataKey)
        }
        return metadata
    }

    public static func catalog(from advertisement: LoomPeerAdvertisement) -> LoomHostCatalog? {
        guard let encoded = advertisement.metadata[metadataKey],
              let data = Data(base64Encoded: encoded) else {
            return nil
        }
        return try? JSONDecoder().decode(LoomHostCatalog.self, from: data)
    }

    public static func addingTargetAppID(
        _ appID: String?,
        to metadata: [String: String]
    ) -> [String: String] {
        var metadata = metadata
        let normalizedAppID = appID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedAppID, !normalizedAppID.isEmpty {
            metadata[targetAppIDKey] = normalizedAppID
        } else {
            metadata.removeValue(forKey: targetAppIDKey)
        }
        return metadata
    }

    public static func targetAppID(from advertisement: LoomPeerAdvertisement) -> String? {
        let appID = advertisement.metadata[targetAppIDKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return appID?.isEmpty == false ? appID : nil
    }

    public static func addingSourceAppID(
        _ appID: String?,
        to metadata: [String: String]
    ) -> [String: String] {
        var metadata = metadata
        let normalizedAppID = appID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedAppID, !normalizedAppID.isEmpty {
            metadata[sourceAppIDKey] = normalizedAppID
        } else {
            metadata.removeValue(forKey: sourceAppIDKey)
        }
        return metadata
    }

    public static func sourceAppID(from advertisement: LoomPeerAdvertisement) -> String? {
        let appID = advertisement.metadata[sourceAppIDKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return appID?.isEmpty == false ? appID : nil
    }

    public static func projections(
        peerName: String,
        advertisement: LoomPeerAdvertisement
    ) -> [LoomHostCatalogProjection] {
        guard let deviceID = advertisement.deviceID else {
            return []
        }

        guard let catalog = catalog(from: advertisement),
              !catalog.entries.isEmpty else {
            return [
                LoomHostCatalogProjection(
                    peerID: LoomPeerID(deviceID: deviceID),
                    displayName: peerName,
                    advertisement: strippingCatalog(from: advertisement),
                    supportedFeatures: []
                ),
            ]
        }

        return catalog.entries.map { entry in
            LoomHostCatalogProjection(
                peerID: LoomPeerID(deviceID: deviceID, appID: entry.appID),
                displayName: entry.displayName,
                advertisement: projecting(entry: entry, from: advertisement),
                supportedFeatures: entry.supportedFeatures
            )
        }
    }

    public static func strippingCatalog(from advertisement: LoomPeerAdvertisement) -> LoomPeerAdvertisement {
        var metadata = advertisement.metadata
        metadata.removeValue(forKey: metadataKey)
        return LoomPeerAdvertisement(
            protocolVersion: advertisement.protocolVersion,
            deviceID: advertisement.deviceID,
            identityKeyID: advertisement.identityKeyID,
            deviceType: advertisement.deviceType,
            modelIdentifier: advertisement.modelIdentifier,
            iconName: advertisement.iconName,
            machineFamily: advertisement.machineFamily,
            hostName: advertisement.hostName,
            directTransports: advertisement.directTransports,
            metadata: metadata
        )
    }

    public static func projecting(
        entry: LoomHostCatalogEntry,
        from advertisement: LoomPeerAdvertisement
    ) -> LoomPeerAdvertisement {
        var metadata = strippingCatalog(from: advertisement).metadata
        for (key, value) in entry.metadata {
            metadata[key] = value
        }
        return LoomPeerAdvertisement(
            protocolVersion: advertisement.protocolVersion,
            deviceID: advertisement.deviceID,
            identityKeyID: advertisement.identityKeyID,
            deviceType: advertisement.deviceType,
            modelIdentifier: advertisement.modelIdentifier,
            iconName: advertisement.iconName,
            machineFamily: advertisement.machineFamily,
            hostName: advertisement.hostName,
            directTransports: advertisement.directTransports,
            metadata: metadata
        )
    }
}
