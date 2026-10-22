//
//  AppState.swift
//  Rufux
//

import Foundation
import Observation
import PhoneBTCore

enum AppAction: Sendable {
    case setCaller(CallerDraft)
    case setSelection(DeviceSelection)
    case setSettings(AppSettings)
    case coordinator(CallCoordinatorEvent)
    case presentCallFailure(String)
    case dismissError
    case dismissWarning
    case resetForNewCall
}

extension AppViewState {
    private static let maximumActivityEntries = 100

    mutating func reduce(_ action: AppAction) {
        switch action {
        case .setCaller(let caller):
            self.caller = caller
        case .setSelection(let selection):
            self.selection = selection
        case .setSettings(let settings):
            self.settings = settings
        case .coordinator(let event):
            apply(event)
        case .presentCallFailure(let message):
            warningKind = nil
            warningMessage = nil
            errorMessage = message
            applyPhase(.failed)
        case .dismissError:
            errorMessage = nil
        case .dismissWarning:
            warningKind = nil
            warningMessage = nil
        case .resetForNewCall:
            callPhase = .idle
            activityEntries.removeAll()
            callStartedAt = nil
            callEndedAt = nil
            latestResult = nil
            warningKind = nil
            warningMessage = nil
            errorMessage = nil
        }

        recomputeReadiness()
    }

    private mutating func apply(_ event: CallCoordinatorEvent) {
        switch event {
        case .hfpDevices(let devices):
            availableHFPDevices = devices
        case .audioDevices(let devices):
            availableAudioDevices = devices
        case .hfpConnectionChanged(let address, let isConnected):
            if isConnected {
                selection.hfpDeviceAddress = address
            } else if selection.hfpDeviceAddress == address {
                selection.hfpDeviceAddress = nil
            }
        case .audioSelectionChanged(let uid):
            selection.audioDeviceUID = uid
        case .phaseChanged(let phase):
            if phase == .validating {
                activityEntries.removeAll()
                callStartedAt = nil
                callEndedAt = nil
                latestResult = nil
                warningKind = nil
                warningMessage = nil
                errorMessage = nil
            }
            applyPhase(phase)
        case .activity(let activity):
            appendActivity(activity.makeEntry())
        case .agent(let event):
            apply(event)
        case .result(let result):
            latestResult = result
            applyPhase(.completed)
        case .failure(let message):
            warningKind = nil
            warningMessage = nil
            errorMessage = message
            applyPhase(.failed)
        }
    }

    private mutating func apply(_ event: AgentSessionEvent) {
        switch event {
        case .activity(let activity):
            if warningKind == .reconnecting {
                warningKind = nil
                warningMessage = nil
            }
            appendActivity(activity.callActivityEvent.makeEntry())
        case .diagnostic:
            break
        case .resultRecorded:
            appendActivity(CallActivityEvent.resultRecorded.makeEntry())
        case .resultWritten(let result, let url):
            latestResult = CallResult(
                appointment: result,
                resultURL: url,
                inputPCMURL: nil,
                outputPCMURL: nil
            )
        case .resultWriteFailed, .failure:
            // The coordinator decides whether these failures are terminal and emits
            // a separate failure event after cleanup. Keeping that distinction here
            // prevents recoverable status from presenting a terminal alert.
            break
        case .pcmOutputReady:
            break
        case .pcmOutputFailed(let message):
            let warning = String(localized: "PCM audio could not be saved: \(message)")
            warningKind = .pcmOutput
            warningMessage = warning
            appendActivity(CallActivityEvent.warning(warning).makeEntry())
        case .reconnecting(let attempt, let maximumAttempts, _):
            warningKind = .reconnecting
            warningMessage = String(localized: "The assistant connection was interrupted. Rufux is reconnecting.")
            appendActivity(CallActivityEvent.reconnecting(
                attempt: attempt,
                maximumAttempts: maximumAttempts
            ).makeEntry())
        case .closed:
            break
        }
    }

    private mutating func applyPhase(_ phase: CallPhase) {
        if phase == .active, callStartedAt == nil {
            callStartedAt = Date()
            callEndedAt = nil
        } else if callStartedAt != nil,
                  callEndedAt == nil,
                  phase == .ending || phase == .finalizing || phase == .completed || phase == .failed {
            callEndedAt = Date()
        }
        callPhase = phase
    }

    private mutating func appendActivity(_ entry: CallActivityEntry) {
        if let lastIndex = activityEntries.indices.last,
           activityEntries[lastIndex].coalescingKey == entry.coalescingKey {
            let previous = activityEntries[lastIndex]
            activityEntries[lastIndex] = CallActivityEntry(
                id: previous.id,
                timestamp: entry.timestamp,
                kind: entry.kind,
                message: entry.message,
                coalescingKey: entry.coalescingKey,
                occurrenceCount: previous.occurrenceCount + 1
            )
        } else {
            activityEntries.append(entry)
        }

        if activityEntries.count > Self.maximumActivityEntries {
            activityEntries.removeFirst(activityEntries.count - Self.maximumActivityEntries)
        }
    }

    private mutating func recomputeReadiness() {
        let selectedAudioDevice = availableAudioDevices.first {
            $0.uid == selection.audioDeviceUID
        }
        readiness = CallReadiness(
            hasCallerInformation: caller.hasRequiredInformation,
            hasAPIKey: settings.hasAPIKey,
            isHFPConnected: selection.hfpDeviceAddress != nil,
            hasFullDuplexAudioDevice: selectedAudioDevice?.isFullDuplex == true,
            hasValidOutputConfiguration: settings.hasValidOutputConfiguration
        )
    }
}

private extension AgentSessionActivity {
    var callActivityEvent: CallActivityEvent {
        switch self {
        case .preparing:
            return .preparingAssistant
        case .waitingForCallee:
            return .waitingForCallee
        case .calleeSpeaking:
            return .calleeSpeaking
        case .assistantSpeaking:
            return .assistantSpeaking
        case .waitingForAssistant, .assistantWorking:
            return .waitingForReasoning
        case .discussionOngoing:
            return .conversationInProgress
        case .recoveringOutcome:
            return .recoveringResult
        case .closing:
            return .finalizing
        }
    }
}

@MainActor
@Observable
final class AppStore {
    private(set) var state: AppViewState

    @ObservationIgnored private let coordinator: any CallCoordinating
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false

    init(
        state: AppViewState? = nil,
        coordinator: any CallCoordinating
    ) {
        self.state = state ?? .prototype
        self.coordinator = coordinator
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        let events = coordinator.makeEventStream()
        eventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.send(.coordinator(event))
            }
        }

        Task {
            await coordinator.bootstrap()
        }
    }

    func send(_ action: AppAction) {
        state.reduce(action)
    }

    func startCall(_ request: CallStartRequest) async {
        await coordinator.startCall(request)
    }

    func endCall() async {
        await coordinator.endCall()
    }

    func presentCallFailure(_ error: any Error) {
        send(.presentCallFailure(error.localizedDescription))
    }

    deinit {
        eventTask?.cancel()
    }

    static func prototype() -> AppStore {
        AppStore(coordinator: PreviewCallCoordinator())
    }
}
