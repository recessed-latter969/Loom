//
//  LoomCloudKitManagerErrorClassificationTests.swift
//  Loom
//
//  Created by Ethan Lipnik on 3/12/26.
//

@testable import LoomCloudKit
import CloudKit
import Foundation
import Testing

@Suite("Loom CloudKit Manager Error Classification")
struct LoomCloudKitManagerErrorClassificationTests {
    @Test("Same-account identity verification retries use a bounded backoff")
    func sameAccountIdentityVerificationRetriesUseABoundedBackoff() {
        #expect(LoomCloudKitManager.sameAccountIdentityVerificationRetryDelay(afterAttempt: 0) == .milliseconds(200))
        #expect(LoomCloudKitManager.sameAccountIdentityVerificationRetryDelay(afterAttempt: 1) == .milliseconds(400))
        #expect(LoomCloudKitManager.sameAccountIdentityVerificationRetryDelay(afterAttempt: 2) == .milliseconds(800))
        #expect(LoomCloudKitManager.sameAccountIdentityVerificationRetryDelay(afterAttempt: 3) == nil)
    }

    @Test("Wrapped unknown item errors are treated as missing published identities")
    func wrappedUnknownItemErrorsAreTreatedAsMissingPublishedIdentities() {
        let error = NSError(domain: CKError.errorDomain, code: CKError.unknownItem.rawValue)

        #expect(LoomCloudKitManager.isMissingPublishedIdentityLookupError(error))
    }

    @Test("Non-unknown item CloudKit errors remain actionable")
    func nonUnknownItemCloudKitErrorsRemainActionable() {
        let error = NSError(domain: CKError.errorDomain, code: CKError.networkFailure.rawValue)

        #expect(LoomCloudKitManager.isMissingPublishedIdentityLookupError(error) == false)
    }
}
