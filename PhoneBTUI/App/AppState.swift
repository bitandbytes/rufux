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
    case resetForNewCall
}

extension AppViewState {
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
            errorMessage = message
            callPhase = .failed
        case .dismissError:
            errorMessage = nil
        case .resetForNewCall:
            callPhase = .idle
            activityEntries.removeAll()
            latestResult = nil
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
                latestResult = nil
                errorMessage = nil
            }
            callPhase = phase
        case .activity(let entry):
            activityEntries.append(entry)
        case .agent(let event):
            apply(event)
        case .result(let result):
            latestResult = result
            callPhase = .completed
        case .failure(let message):
            errorMessage = message
            callPhase = .failed
        }
    }

    private mutating func apply(_ event: AgentSessionEvent) {
        switch event {
        case .activity(let activity):
            activityEntries.append(CallActivityEntry(message: activity.rawValue))
        case .diagnostic:
            break
        case .resultRecorded(let result):
            activityEntries.append(CallActivityEntry(
                kind: .success,
                message: "Appointment outcome recorded: \(result.status)"
            ))
        case .resultWritten(let result, let url):
            latestResult = CallResult(
                appointment: result,
                resultURL: url,
                inputPCMURL: nil,
                outputPCMURL: nil
            )
        case .resultWriteFailed(let message), .failure(let message):
            errorMessage = message
        case .reconnecting(let attempt, let maximumAttempts, let reason):
            activityEntries.append(CallActivityEntry(
                kind: .warning,
                message: "Reconnecting assistant (\(attempt)/\(maximumAttempts)): \(reason)"
            ))
        case .closed:
            break
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
