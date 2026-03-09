import Foundation
import Loom

actor DiagnosticsRecorder: LoomDiagnosticsSink {
    private(set) var logs: [LoomDiagnosticsLogEvent] = []
    private(set) var errors: [LoomDiagnosticsErrorEvent] = []

    func record(log event: LoomDiagnosticsLogEvent) async {
        logs.append(event)
    }

    func record(error event: LoomDiagnosticsErrorEvent) async {
        errors.append(event)
    }
}

actor StepRecorder: LoomInstrumentationSink {
    private(set) var events: [LoomInstrumentationEvent] = []

    func record(event: LoomInstrumentationEvent) async {
        events.append(event)
    }
}

@MainActor
final class MyClientServiceWithDiagnostics {
    private var diagnosticsToken: LoomDiagnosticsSinkToken?
    private var instrumentationToken: LoomInstrumentationSinkToken?
    private var diagnosticsContextToken: LoomDiagnosticsContextProviderToken?

    private(set) var availablePeerCount = 0
    private(set) var isAwaitingApproval = false
    private(set) var connectionState = "disconnected"
}
