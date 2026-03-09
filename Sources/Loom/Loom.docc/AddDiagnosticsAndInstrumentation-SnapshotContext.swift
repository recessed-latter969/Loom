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

    func startObservability() async {
        diagnosticsToken = await LoomDiagnostics.addSink(DiagnosticsRecorder())
        instrumentationToken = await LoomInstrumentation.addSink(StepRecorder())
    }

    func stopObservability() async {
        if let diagnosticsToken {
            await LoomDiagnostics.removeSink(diagnosticsToken)
        }
        if let instrumentationToken {
            await LoomInstrumentation.removeSink(instrumentationToken)
        }
        if let diagnosticsContextToken {
            await LoomDiagnostics.unregisterContextProvider(diagnosticsContextToken)
        }
    }

    func startDiagnosticsContext() {
        Task { [weak self] in
            guard let self else { return }
            diagnosticsContextToken = await LoomDiagnostics.registerContextProvider { [weak self] in
                guard let self else { return [:] }
                return await MainActor.run {
                    [
                        "client.connectionState": .string(self.connectionState),
                        "client.availablePeerCount": .int(self.availablePeerCount),
                        "client.awaitingApproval": .bool(self.isAwaitingApproval),
                    ]
                }
            }
        }
    }

    func snapshotDiagnosticsContext() async -> LoomDiagnosticsContext {
        await LoomDiagnostics.snapshotContext()
    }
}
