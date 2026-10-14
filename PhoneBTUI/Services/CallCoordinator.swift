//
//  CallCoordinator.swift
//  Rufux
//

import Foundation
import PhoneBTCore

nonisolated enum CallCoordinatorEvent: Equatable, Sendable {
    case hfpDevices([HFPDeviceOption])
    case audioDevices([AudioDeviceOption])
    case hfpConnectionChanged(address: String, isConnected: Bool)
    case audioSelectionChanged(uid: String?)
    case phaseChanged(CallPhase)
    case activity(CallActivityEntry)
    case agent(AgentSessionEvent)
    case result(CallResult)
    case failure(String)
}

nonisolated enum HFPConnectionStatus: Equatable, Sendable {
    case disconnected
    case connecting(address: String)
    case connected(address: String)
    case failed(address: String?, message: String)

    var activeAddress: String? {
        switch self {
        case .connecting(let address), .connected(let address):
            return address
        case .failed(let address, _):
            return address
        case .disconnected:
            return nil
        }
    }

    var connectedAddress: String? {
        guard case .connected(let address) = self else { return nil }
        return address
    }

    var isConnecting: Bool {
        guard case .connecting = self else { return false }
        return true
    }
}

nonisolated enum AudioSelectionStatus: Equatable, Sendable {
    case unselected
    case selected(uid: String)
    case unavailable(uid: String)

    var selectedUID: String? {
        guard case .selected(let uid) = self else { return nil }
        return uid
    }

    var requestedUID: String? {
        switch self {
        case .selected(let uid), .unavailable(let uid):
            return uid
        case .unselected:
            return nil
        }
    }
}

nonisolated enum DeviceReadinessIssue: String, Equatable, Sendable {
    case hfpPhoneNotConnected
    case audioDeviceNotSelected
    case audioDeviceUnavailable
}

nonisolated struct DeviceManagementState: Equatable, Sendable {
    var hfpDevices: [HFPDeviceOption]
    var audioDevices: [AudioDeviceOption]
    var hfpConnection: HFPConnectionStatus
    var audioSelection: AudioSelectionStatus
    var callPhase: CallPhase
    var isRefreshing: Bool
    var lastError: String?

    var canChangeDevices: Bool {
        !Self.callIsInProgress(callPhase) && !isRefreshing && !hfpConnection.isConnecting
    }

    var readinessIssues: [DeviceReadinessIssue] {
        var issues: [DeviceReadinessIssue] = []
        if hfpConnection.connectedAddress == nil {
            issues.append(.hfpPhoneNotConnected)
        }

        switch audioSelection {
        case .unselected:
            issues.append(.audioDeviceNotSelected)
        case .unavailable:
            issues.append(.audioDeviceUnavailable)
        case .selected(let uid):
            if !audioDevices.contains(where: { $0.uid == uid && $0.hasInput && $0.hasOutput }) {
                issues.append(.audioDeviceUnavailable)
            }
        }
        return issues
    }

    var isReady: Bool {
        readinessIssues.isEmpty
    }

    private static func callIsInProgress(_ phase: CallPhase) -> Bool {
        switch phase {
        case .validating, .dialing, .ringing, .active, .ending, .finalizing:
            return true
        case .idle, .completed, .failed:
            return false
        }
    }

    static let empty = DeviceManagementState(
        hfpDevices: [],
        audioDevices: [],
        hfpConnection: .disconnected,
        audioSelection: .unselected,
        callPhase: .idle,
        isRefreshing: false,
        lastError: nil
    )
}

nonisolated enum DeviceManagementOperation: String, Equatable, Sendable {
    case refresh
    case connectHFP
    case disconnectHFP
    case selectAudio
}

nonisolated enum DeviceManagementEvent: Equatable, Sendable {
    case stateChanged(DeviceManagementState)
    case hfpConnectionChanged(HFPConnectionStatus)
    case audioDeviceUnavailable(uid: String)
    case operationFailed(operation: DeviceManagementOperation, message: String)
}

protocol CallCoordinating: Sendable {
    func makeEventStream() -> AsyncStream<CallCoordinatorEvent>
    func bootstrap() async
    func startCall(_ request: CallStartRequest) async
    func endCall() async
}

protocol DeviceManaging: Sendable {
    func makeDeviceEventStream() -> AsyncStream<DeviceManagementEvent>
    func deviceState() async -> DeviceManagementState
    func refreshDevices() async
    func connectHFPDevice(address: String) async throws
    func disconnectHFPDevice() async throws
    func selectAudioDevice(uid: String?) async throws
}

nonisolated final class CallCoordinatorEventStream: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<CallCoordinatorEvent>.Continuation] = [:]

    func makeStream() -> AsyncStream<CallCoordinatorEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.lock()
            continuations[id] = continuation
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations.removeValue(forKey: id)
                self.lock.unlock()
            }
        }
    }

    func emit(_ event: CallCoordinatorEvent) {
        lock.lock()
        let activeContinuations = Array(continuations.values)
        lock.unlock()

        for continuation in activeContinuations {
            continuation.yield(event)
        }
    }
}

nonisolated final class DeviceManagementEventStream: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<DeviceManagementEvent>.Continuation] = [:]

    func makeStream() -> AsyncStream<DeviceManagementEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.lock()
            continuations[id] = continuation
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations.removeValue(forKey: id)
                self.lock.unlock()
            }
        }
    }

    func emit(_ event: DeviceManagementEvent) {
        lock.lock()
        let activeContinuations = Array(continuations.values)
        lock.unlock()

        for continuation in activeContinuations {
            continuation.yield(event)
        }
    }
}

actor CallCoordinator: CallCoordinating, DeviceManaging {
    nonisolated private let eventStream = CallCoordinatorEventStream()
    nonisolated private let deviceEventStream = DeviceManagementEventStream()
    private let hfpService: any HFPServicing
    private let audioService: any AudioServicing
    private let agentFactory: any AgentSessionCreating
    private var managedDeviceState = DeviceManagementState.empty
    private var hfpEventTask: Task<Void, Never>?
    private var agentEventTask: Task<Void, Never>?
    private var agentSession: (any AgentSessionServicing)?
    private var callID: UUID?
    private var outputConfiguration: AgentSessionOutputConfiguration?
    private var writtenResult: AppointmentResult?
    private var isCleaningUp = false
    private var agentDidClose = false
    private var audioDidStop = true
    private var cleanupFailure: String?

    init(
        hfpService: any HFPServicing,
        audioService: any AudioServicing,
        agentFactory: any AgentSessionCreating
    ) {
        self.hfpService = hfpService
        self.audioService = audioService
        self.agentFactory = agentFactory
    }

    @MainActor static func live() -> CallCoordinator {
        CallCoordinator(
            hfpService: LiveHFPService(),
            audioService: LiveAudioService(),
            agentFactory: LiveAgentSessionFactory()
        )
    }

    nonisolated func makeEventStream() -> AsyncStream<CallCoordinatorEvent> {
        eventStream.makeStream()
    }

    nonisolated func makeDeviceEventStream() -> AsyncStream<DeviceManagementEvent> {
        deviceEventStream.makeStream()
    }

    func deviceState() -> DeviceManagementState {
        managedDeviceState
    }

    func bootstrap() async {
        await refreshDevices()
    }

    func startCall(_ request: CallStartRequest) async {
        guard !managedDeviceState.callPhase.isCallInProgress, !isCleaningUp else {
            emitActivity(CallServiceError.callAlreadyInProgress.localizedDescription, kind: .warning)
            return
        }

        let newCallID = UUID()
        callID = newCallID
        writtenResult = nil
        cleanupFailure = nil
        agentDidClose = false
        audioDidStop = true
        updateCallPhase(.validating)
        emitActivity("Validating call settings")

        do {
            let output = try await validatedOutputConfiguration(for: request)
            guard callID == newCallID, !isCleaningUp else { return }

            let session = try await agentFactory.makeSession(
                apiKey: request.apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                configuration: request.configuration,
                outputConfiguration: output,
                hfpService: hfpService
            )
            guard callID == newCallID, !isCleaningUp else {
                session.close(finalizeOutcome: false)
                return
            }

            outputConfiguration = output
            agentSession = session
            startAgentEventConsumer(for: session, callID: newCallID)
            updateCallPhase(.dialing)
            emitActivity("Dialing \(request.phoneNumber)")
            try await hfpService.dial(number: request.phoneNumber)
            guard callID == newCallID, !isCleaningUp else { return }
            updateCallPhase(.ringing)
            emitActivity("Phone is ringing. The call assistant will start after the call is answered.")
        } catch {
            await beginCleanup(
                failure: "Could not start the call: \(error.localizedDescription)",
                finalizeOutcome: agentSession != nil
            )
        }
    }

    func endCall() async {
        guard managedDeviceState.callPhase.isCallInProgress, !isCleaningUp else { return }
        updateCallPhase(.ending)
        emitActivity("Ending the telephone call")

        do {
            try await hfpService.endCall()
            await beginCleanup(failure: nil, finalizeOutcome: true)
        } catch {
            await beginCleanup(
                failure: "The hang-up command failed: \(error.localizedDescription)",
                finalizeOutcome: true
            )
        }
    }

    func refreshDevices() async {
        guard !managedDeviceState.isRefreshing,
              !managedDeviceState.hfpConnection.isConnecting else { return }

        managedDeviceState.isRefreshing = true
        managedDeviceState.lastError = nil
        publishDeviceState()

        async let pairedPhones = hfpService.pairedDevices()
        async let availableAudioDevices = audioService.availableDevices()
        let inventory = await (pairedPhones, availableAudioDevices)
        let fullDuplexDevices = inventory.1.filter { $0.hasInput && $0.hasOutput }

        managedDeviceState.hfpDevices = inventory.0
        managedDeviceState.audioDevices = fullDuplexDevices
        managedDeviceState.isRefreshing = false
        await reconcileAudioSelection(with: fullDuplexDevices)

        eventStream.emit(.hfpDevices(inventory.0))
        eventStream.emit(.audioDevices(fullDuplexDevices))
        publishDeviceState()
    }

    func connectHFPDevice(address: String) async throws {
        try ensureDevicesCanChange()
        guard managedDeviceState.hfpDevices.contains(where: { $0.address == address }) else {
            try fail(
                operation: .connectHFP,
                error: CallServiceError.hfpDeviceNotFound,
                hfpStatus: .failed(address: address, message: CallServiceError.hfpDeviceNotFound.localizedDescription)
            )
        }

        if managedDeviceState.hfpConnection.connectedAddress == address {
            return
        }

        if managedDeviceState.hfpConnection.connectedAddress != nil {
            await disconnectCurrentHFP()
        }

        hfpEventTask?.cancel()
        hfpEventTask = nil
        managedDeviceState.lastError = nil
        managedDeviceState.hfpConnection = .connecting(address: address)
        deviceEventStream.emit(.hfpConnectionChanged(managedDeviceState.hfpConnection))
        publishDeviceState()

        do {
            try await hfpService.connect(to: address)
        } catch {
            let status = HFPConnectionStatus.failed(
                address: address,
                message: error.localizedDescription
            )
            managedDeviceState.hfpConnection = status
            managedDeviceState.lastError = error.localizedDescription
            deviceEventStream.emit(.hfpConnectionChanged(status))
            deviceEventStream.emit(.operationFailed(
                operation: .connectHFP,
                message: error.localizedDescription
            ))
            publishDeviceState()
            throw error
        }

        managedDeviceState.hfpConnection = .connected(address: address)
        eventStream.emit(.hfpConnectionChanged(address: address, isConnected: true))
        deviceEventStream.emit(.hfpConnectionChanged(managedDeviceState.hfpConnection))
        publishDeviceState()
        startHFPEventConsumer()
    }

    func disconnectHFPDevice() async throws {
        try ensureDevicesCanChange()
        await disconnectCurrentHFP()
    }

    func selectAudioDevice(uid: String?) async throws {
        try ensureDevicesCanChange()

        guard let uid else {
            await audioService.selectDevice(uid: nil)
            managedDeviceState.audioSelection = .unselected
            managedDeviceState.lastError = nil
            eventStream.emit(.audioSelectionChanged(uid: nil))
            publishDeviceState()
            return
        }

        guard managedDeviceState.audioDevices.contains(where: {
            $0.uid == uid && $0.hasInput && $0.hasOutput
        }) else {
            await audioService.selectDevice(uid: nil)
            managedDeviceState.audioSelection = .unavailable(uid: uid)
            try fail(operation: .selectAudio, error: CallServiceError.audioDeviceUnavailable)
        }

        await audioService.selectDevice(uid: uid)
        managedDeviceState.audioSelection = .selected(uid: uid)
        managedDeviceState.lastError = nil
        eventStream.emit(.audioSelectionChanged(uid: uid))
        publishDeviceState()
    }

    /// Stage 5 uses this transition point so device controls remain locked for
    /// the entire call and cleanup lifecycle.
    func updateCallPhase(_ phase: CallPhase) {
        managedDeviceState.callPhase = phase
        eventStream.emit(.phaseChanged(phase))
        publishDeviceState()
    }

    private func ensureDevicesCanChange() throws {
        switch managedDeviceState.callPhase {
        case .validating, .dialing, .ringing, .active, .ending, .finalizing:
            throw CallServiceError.deviceChangesUnavailableDuringCall
        case .idle, .completed, .failed:
            break
        }
        guard !managedDeviceState.isRefreshing,
              !managedDeviceState.hfpConnection.isConnecting else {
            throw CallServiceError.deviceOperationInProgress
        }
    }

    private func reconcileAudioSelection(with devices: [AudioDeviceOption]) async {
        guard let requestedUID = managedDeviceState.audioSelection.requestedUID else {
            return
        }

        if devices.contains(where: { $0.uid == requestedUID && $0.hasInput && $0.hasOutput }) {
            await audioService.selectDevice(uid: requestedUID)
            managedDeviceState.audioSelection = .selected(uid: requestedUID)
            eventStream.emit(.audioSelectionChanged(uid: requestedUID))
        } else {
            await audioService.selectDevice(uid: nil)
            managedDeviceState.audioSelection = .unavailable(uid: requestedUID)
            eventStream.emit(.audioSelectionChanged(uid: nil))
            deviceEventStream.emit(.audioDeviceUnavailable(uid: requestedUID))
        }
    }

    private func disconnectCurrentHFP() async {
        let address = managedDeviceState.hfpConnection.connectedAddress
            ?? managedDeviceState.hfpConnection.activeAddress
        hfpEventTask?.cancel()
        hfpEventTask = nil
        await hfpService.disconnect()
        managedDeviceState.hfpConnection = .disconnected
        managedDeviceState.lastError = nil

        if let address {
            eventStream.emit(.hfpConnectionChanged(address: address, isConnected: false))
        }
        deviceEventStream.emit(.hfpConnectionChanged(.disconnected))
        publishDeviceState()
    }

    private func startHFPEventConsumer() {
        hfpEventTask?.cancel()
        hfpEventTask = Task { [weak self, hfpService] in
            let stream = await hfpService.makeEventStream()
            for await event in stream {
                guard !Task.isCancelled else { return }
                await self?.handleHFPEvent(event)
            }
        }
    }

    private func handleHFPEvent(_ event: HFPEvent) async {
        switch event {
        case .connected:
            guard let address = managedDeviceState.hfpConnection.activeAddress else { return }
            managedDeviceState.hfpConnection = .connected(address: address)
            eventStream.emit(.hfpConnectionChanged(address: address, isConnected: true))
            deviceEventStream.emit(.hfpConnectionChanged(managedDeviceState.hfpConnection))
            publishDeviceState()
        case .disconnected(let error):
            let address = managedDeviceState.hfpConnection.activeAddress
            managedDeviceState.hfpConnection = .disconnected
            managedDeviceState.lastError = error?.localizedDescription
            if let address {
                eventStream.emit(.hfpConnectionChanged(address: address, isConnected: false))
            }
            deviceEventStream.emit(.hfpConnectionChanged(.disconnected))
            publishDeviceState()
            hfpEventTask = nil
            if managedDeviceState.callPhase.isCallInProgress || isCleaningUp {
                let message = error?.localizedDescription ?? "The HFP phone disconnected during the call."
                await beginCleanup(failure: message, finalizeOutcome: true)
            }
        case .connectFailed(let error):
            let address = managedDeviceState.hfpConnection.activeAddress
            let message = error?.localizedDescription
                ?? String(localized: "The phone connection failed.")
            let status = HFPConnectionStatus.failed(address: address, message: message)
            managedDeviceState.hfpConnection = status
            managedDeviceState.lastError = message
            if let address {
                eventStream.emit(.hfpConnectionChanged(address: address, isConnected: false))
            }
            deviceEventStream.emit(.hfpConnectionChanged(status))
            deviceEventStream.emit(.operationFailed(operation: .connectHFP, message: message))
            publishDeviceState()
            hfpEventTask = nil
        case .error(let message):
            managedDeviceState.lastError = message
            deviceEventStream.emit(.operationFailed(operation: .connectHFP, message: message))
            publishDeviceState()
        case .callDialing:
            guard !isCleaningUp, managedDeviceState.callPhase.isCallInProgress else { return }
            updateCallPhase(.dialing)
        case .callAlerting:
            guard !isCleaningUp, managedDeviceState.callPhase.isCallInProgress else { return }
            updateCallPhase(.ringing)
        case .callActive:
            await activateCallAudio()
        case .callEnded:
            guard managedDeviceState.callPhase.isCallInProgress || isCleaningUp else { return }
            emitActivity("Telephone call ended")
            await beginCleanup(failure: nil, finalizeOutcome: true)
        case .incomingCall,
             .callAnswered,
             .callHeld,
             .callWaiting,
             .signalStrength,
             .batteryLevel,
             .serviceAvailable,
             .roaming,
             .callSetup,
             .callIndicator,
             .callHeldIndicator,
             .callerID,
             .operatorName:
            break
        }
    }

    private func validatedOutputConfiguration(
        for request: CallStartRequest
    ) async throws -> AgentSessionOutputConfiguration {
        let apiKey = request.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { throw CallServiceError.missingAPIKey }

        let phoneNumber = request.phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let digitCount = phoneNumber.filter(\.isNumber).count
        guard digitCount >= 5 else { throw CallServiceError.invalidPhoneNumber }

        guard !request.configuration.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.configuration.dateOfBirth.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.configuration.insurance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.configuration.additionalDetails.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CallServiceError.invalidCallerConfiguration
        }
        guard managedDeviceState.hfpConnection.connectedAddress != nil else {
            throw CallServiceError.hfpDeviceNotConnected
        }
        guard let audioDevice = await audioService.selectedDevice() else {
            throw CallServiceError.audioDeviceNotSelected
        }
        guard audioDevice.isFullDuplex,
              managedDeviceState.audioDevices.contains(where: { $0.uid == audioDevice.uid }) else {
            throw CallServiceError.audioDeviceUnavailable
        }

        try validateWritableDirectory(request.resultOutputDirectory)
        if request.isPCMOutputEnabled {
            guard let pcmOutputDirectory = request.pcmOutputDirectory else {
                throw CallServiceError.invalidOutputDirectory(request.resultOutputDirectory)
            }
            try validateWritableDirectory(pcmOutputDirectory)
        }

        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = timestampFormatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let resultURL = request.resultOutputDirectory.appending(
            path: "rufux-\(timestamp)-appointment-result.json",
            directoryHint: .notDirectory
        )
        return AgentSessionOutputConfiguration(
            resultURL: resultURL,
            isPCMOutputEnabled: request.isPCMOutputEnabled,
            pcmOutputDirectory: request.pcmOutputDirectory
        )
    }

    private func validateWritableDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isWritableFile(atPath: url.path) else {
            throw CallServiceError.invalidOutputDirectory(url)
        }
    }

    private func activateCallAudio() async {
        guard !isCleaningUp,
              managedDeviceState.callPhase == .ringing || managedDeviceState.callPhase == .dialing,
              let session = agentSession,
              let activeCallID = callID else { return }

        emitActivity("Call answered. Starting the selected audio route.")
        do {
            let audioSession = try await audioService.startAudioSession()
            guard callID == activeCallID, !isCleaningUp else {
                await audioService.stopAudioSession()
                return
            }
            audioDidStop = false
            session.prepare()
            try session.startAudio(using: audioSession)
            updateCallPhase(.active)
            emitActivity("Call assistant and audio are active", kind: .success)
        } catch {
            try? await hfpService.endCall()
            await beginCleanup(
                failure: "Could not start call audio: \(error.localizedDescription)",
                finalizeOutcome: true
            )
        }
    }

    private func startAgentEventConsumer(
        for session: any AgentSessionServicing,
        callID: UUID
    ) {
        agentEventTask?.cancel()
        let events = session.makeEventStream()
        agentEventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.handleAgentEvent(event, callID: callID)
            }
            await self?.agentEventStreamFinished(callID: callID)
        }
    }

    private func handleAgentEvent(_ event: AgentSessionEvent, callID eventCallID: UUID) async {
        guard callID == eventCallID else { return }
        eventStream.emit(.agent(event))

        switch event {
        case .resultWritten(let result, _):
            writtenResult = result
        case .resultWriteFailed(let message):
            cleanupFailure = cleanupFailure ?? "Could not save the appointment result: \(message)"
        case .failure(let message):
            guard !isCleaningUp else {
                cleanupFailure = cleanupFailure ?? message
                return
            }
            try? await hfpService.endCall()
            await beginCleanup(failure: message, finalizeOutcome: true)
        case .closed:
            agentDidClose = true
            finishCleanupIfPossible()
        case .activity, .diagnostic, .resultRecorded, .reconnecting:
            break
        }
    }

    private func agentEventStreamFinished(callID eventCallID: UUID) {
        guard callID == eventCallID else { return }
        agentDidClose = true
        finishCleanupIfPossible()
    }

    private func beginCleanup(failure: String?, finalizeOutcome: Bool) async {
        if isCleaningUp {
            cleanupFailure = cleanupFailure ?? failure
            return
        }

        isCleaningUp = true
        cleanupFailure = failure
        updateCallPhase(.finalizing)
        emitActivity("Finalizing the call and restoring audio routing")

        if let agentSession {
            agentDidClose = false
            agentSession.close(finalizeOutcome: finalizeOutcome)
        } else {
            agentDidClose = true
        }

        await audioService.stopAudioSession()
        audioDidStop = true
        finishCleanupIfPossible()
    }

    private func finishCleanupIfPossible() {
        guard isCleaningUp, agentDidClose, audioDidStop else { return }

        let failure = cleanupFailure
        let result = writtenResult
        let output = outputConfiguration

        agentEventTask?.cancel()
        agentEventTask = nil
        agentSession = nil
        callID = nil
        outputConfiguration = nil
        writtenResult = nil
        cleanupFailure = nil
        agentDidClose = false
        isCleaningUp = false

        if let failure {
            updateCallPhase(.failed)
            eventStream.emit(.failure(failure))
            emitActivity(failure, kind: .failure)
            return
        }

        if let result, let output {
            let pcmURLs = pcmURLs(for: output)
            eventStream.emit(.result(CallResult(
                appointment: result,
                resultURL: output.resultURL,
                inputPCMURL: pcmURLs?.input,
                outputPCMURL: pcmURLs?.output
            )))
        }
        updateCallPhase(.completed)
        emitActivity("Call cleanup completed", kind: .success)
    }

    private func pcmURLs(
        for output: AgentSessionOutputConfiguration
    ) -> (input: URL, output: URL)? {
        guard let directory = output.resolvedPCMOutputDirectory else { return nil }
        let resultStem = output.resultURL.deletingPathExtension().lastPathComponent
        let suffix = "-appointment-result"
        let callStem = resultStem.hasSuffix(suffix)
            ? String(resultStem.dropLast(suffix.count))
            : resultStem
        return (
            directory.appending(path: "\(callStem)-agent-input.pcm"),
            directory.appending(path: "\(callStem)-agent-output.pcm")
        )
    }

    private func emitActivity(
        _ message: String,
        kind: CallActivityKind = .information
    ) {
        eventStream.emit(.activity(CallActivityEntry(kind: kind, message: message)))
    }

    private func publishDeviceState() {
        deviceEventStream.emit(.stateChanged(managedDeviceState))
    }

    private func fail(
        operation: DeviceManagementOperation,
        error: any Error,
        hfpStatus: HFPConnectionStatus? = nil
    ) throws -> Never {
        managedDeviceState.lastError = error.localizedDescription
        if let hfpStatus {
            managedDeviceState.hfpConnection = hfpStatus
            deviceEventStream.emit(.hfpConnectionChanged(hfpStatus))
        }
        deviceEventStream.emit(.operationFailed(
            operation: operation,
            message: error.localizedDescription
        ))
        publishDeviceState()
        throw error
    }
}

actor PreviewCallCoordinator: CallCoordinating, DeviceManaging {
    nonisolated private let eventStream = CallCoordinatorEventStream()
    nonisolated private let deviceEventStream = DeviceManagementEventStream()
    private let samplePhones = [
        HFPDeviceOption(
            name: "Suchetha’s iPhone",
            address: "00:00:00:00:00:01",
            supportsHandsFreeGateway: true
        ),
    ]
    private let sampleAudioDevices = [
        AudioDeviceOption(
            name: "USB Advanced Audio Device",
            uid: "prototype.usb-audio",
            hasInput: true,
            hasOutput: true
        ),
    ]
    private var managedDeviceState = DeviceManagementState.empty

    nonisolated func makeEventStream() -> AsyncStream<CallCoordinatorEvent> {
        eventStream.makeStream()
    }

    nonisolated func makeDeviceEventStream() -> AsyncStream<DeviceManagementEvent> {
        deviceEventStream.makeStream()
    }

    func deviceState() -> DeviceManagementState {
        managedDeviceState
    }

    func bootstrap() async {
        await refreshDevices()
    }

    func startCall(_ request: CallStartRequest) async {
        guard !managedDeviceState.callPhase.isCallInProgress else { return }
        managedDeviceState.callPhase = .dialing
        eventStream.emit(.phaseChanged(.dialing))
        eventStream.emit(.activity(CallActivityEntry(message: "Dialing \(request.phoneNumber)")))
        publishDeviceState()
        managedDeviceState.callPhase = .ringing
        eventStream.emit(.phaseChanged(.ringing))
        publishDeviceState()
    }

    func endCall() async {
        guard managedDeviceState.callPhase.isCallInProgress else { return }
        managedDeviceState.callPhase = .completed
        eventStream.emit(.phaseChanged(.completed))
        publishDeviceState()
    }

    func refreshDevices() async {
        managedDeviceState.hfpDevices = samplePhones
        managedDeviceState.audioDevices = sampleAudioDevices
        eventStream.emit(.hfpDevices(samplePhones))
        eventStream.emit(.audioDevices(sampleAudioDevices))
        publishDeviceState()
    }

    func connectHFPDevice(address: String) async throws {
        guard managedDeviceState.canChangeDevices else {
            throw CallServiceError.deviceChangesUnavailableDuringCall
        }
        managedDeviceState.hfpConnection = .connected(address: address)
        eventStream.emit(.hfpConnectionChanged(address: address, isConnected: true))
        deviceEventStream.emit(.hfpConnectionChanged(managedDeviceState.hfpConnection))
        publishDeviceState()
    }

    func disconnectHFPDevice() async throws {
        guard managedDeviceState.canChangeDevices else {
            throw CallServiceError.deviceChangesUnavailableDuringCall
        }
        if let address = managedDeviceState.hfpConnection.connectedAddress {
            eventStream.emit(.hfpConnectionChanged(address: address, isConnected: false))
        }
        managedDeviceState.hfpConnection = .disconnected
        deviceEventStream.emit(.hfpConnectionChanged(.disconnected))
        publishDeviceState()
    }

    func selectAudioDevice(uid: String?) async throws {
        guard managedDeviceState.canChangeDevices else {
            throw CallServiceError.deviceChangesUnavailableDuringCall
        }
        managedDeviceState.audioSelection = uid.map(AudioSelectionStatus.selected(uid:))
            ?? .unselected
        eventStream.emit(.audioSelectionChanged(uid: uid))
        publishDeviceState()
    }

    private func publishDeviceState() {
        deviceEventStream.emit(.stateChanged(managedDeviceState))
    }
}
