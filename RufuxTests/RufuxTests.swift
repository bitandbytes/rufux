// Copyright 2026 Ravindu Kumarasiri.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//
//  RufuxTests.swift
//  RufuxTests
//
//  Created by Ravindu Kumarasiri on 16.10.26.
//

import Foundation
import PhoneBTCore
import Testing
@testable import Rufux

struct RufuxTests {

    @Test func repeatedActivityIsCoalesced() {
        var state = AppViewState.prototype

        state.reduce(.coordinator(.agent(.activity(.assistantSpeaking))))
        state.reduce(.coordinator(.agent(.activity(.assistantSpeaking))))

        #expect(state.activityEntries.count == 1)
        #expect(state.activityEntries.first?.occurrenceCount == 2)
    }

    @Test func activityHistoryIsBounded() {
        var state = AppViewState.prototype

        for index in 0..<105 {
            state.reduce(.coordinator(.activity(.warning("Warning \(index)"))))
        }

        #expect(state.activityEntries.count == 100)
        #expect(state.activityEntries.first?.message == "Warning 5")
    }

    @Test func diagnosticsNeverAppearInActivityHistory() {
        var state = AppViewState.prototype

        state.reduce(.coordinator(.agent(.diagnostic("private transcript text"))))

        #expect(state.activityEntries.isEmpty)
        #expect(state.errorMessage == nil)
        #expect(state.warningMessage == nil)
    }

    @Test func reconnectingIsARecoverableWarning() {
        var state = AppViewState.prototype

        state.reduce(.coordinator(.agent(.reconnecting(
            attempt: 1,
            maximumAttempts: 3,
            reason: "Connection interrupted"
        ))))

        #expect(state.warningMessage != nil)
        #expect(state.errorMessage == nil)
        #expect(state.callPhase != .failed)
        #expect(state.activityEntries.last?.kind == .warning)
    }

    @Test func terminalFailureIsSeparatedFromWarnings() {
        var state = AppViewState.prototype
        state.reduce(.coordinator(.agent(.reconnecting(
            attempt: 1,
            maximumAttempts: 3,
            reason: "Connection interrupted"
        ))))

        state.reduce(.coordinator(.failure("The assistant could not reconnect.")))

        #expect(state.warningMessage == nil)
        #expect(state.errorMessage == "The assistant could not reconnect.")
        #expect(state.callPhase == .failed)
    }

    @Test func elapsedTimeStartsAndStopsWithActiveCall() {
        var state = AppViewState.prototype

        state.reduce(.coordinator(.phaseChanged(.active)))
        #expect(state.callStartedAt != nil)
        #expect(state.callEndedAt == nil)

        state.reduce(.coordinator(.phaseChanged(.finalizing)))
        #expect(state.callEndedAt != nil)
    }

    @Test func appointmentStatusMapsToSupportedOutcomes() {
        #expect(AppointmentOutcome(status: "booked") == .booked)
        #expect(AppointmentOutcome(status: "not_booked") == .notBooked)
        #expect(AppointmentOutcome(status: "unknown") == .unknown)
        #expect(AppointmentOutcome(status: "unexpected-value") == .unknown)
    }

    @Test func completedResultIsRetainedUntilTheNextCallStarts() {
        var state = AppViewState.prototype
        let result = CallResult(
            appointment: AppointmentResult(
                status: "booked",
                appointmentDate: "2026-11-03",
                appointmentTime: "10:30",
                practice: "Example Practice",
                notes: "Bring the referral."
            ),
            resultURL: URL(fileURLWithPath: "/results/call-result.json"),
            inputPCMURL: nil,
            outputPCMURL: nil
        )

        state.reduce(.coordinator(.result(result)))
        state.reduce(.setCaller(.prototype))
        #expect(state.latestResult == result)

        state.reduce(.coordinator(.phaseChanged(.validating)))
        #expect(state.latestResult == nil)
    }

    @Test func pcmOutputFailureIsNonterminalAndVisible() {
        var state = AppViewState.prototype

        state.reduce(.coordinator(.agent(.pcmOutputFailed("The disk is full."))))

        #expect(state.warningKind == .pcmOutput)
        #expect(state.warningMessage?.contains("The disk is full.") == true)
        #expect(state.errorMessage == nil)
        #expect(state.callPhase == .idle)
        #expect(state.activityEntries.last?.kind == .warning)
    }

    @Test func outputFilenamesAreCollisionSafe() throws {
        let directory = URL(fileURLWithPath: "/results", isDirectory: true)
        let date = Date(timeIntervalSince1970: 1_795_027_200)
        let firstIdentifier = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let secondIdentifier = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let first = CallOutputURLBuilder.resultURL(
            in: directory,
            date: date,
            identifier: firstIdentifier
        )
        let second = CallOutputURLBuilder.resultURL(
            in: directory,
            date: date,
            identifier: secondIdentifier
        )

        #expect(first != second)
        #expect(first.pathExtension == "json")
        #expect(first.lastPathComponent.hasSuffix("-appointment-result.json"))
        #expect(!first.lastPathComponent.contains(":"))
    }

    @MainActor
    @Test func callerAndDestinationPhoneNumbersRemainIndependent() throws {
        let profilePhoneNumber = "+49 111 11111"
        let destinationPhoneNumber = "+49 222 22222"
        var caller = CallerDraft.prototype
        caller.telephoneNumber = profilePhoneNumber
        let editor = CallerEditorStore(caller: caller)
        let configuration = try editor.inputConfiguration()
        let request = CallStartRequest(
            apiKey: "test-key",
            configuration: configuration,
            phoneNumber: PhoneNumberValidator.normalized(destinationPhoneNumber),
            resultOutputDirectory: URL(fileURLWithPath: "/results", isDirectory: true),
            isPCMOutputEnabled: false,
            pcmOutputDirectory: nil
        )

        #expect(configuration.telephoneNumber == profilePhoneNumber)
        #expect(request.phoneNumber == destinationPhoneNumber)
        #expect(request.phoneNumber != configuration.telephoneNumber)
        #expect(PhoneNumberValidator.isValid(request.phoneNumber))
    }

}

@Suite("Caller import and validation")
struct CallerImportAndValidationTests {

    @MainActor
    @Test func jsonImportPopulatesEverySupportedField() throws {
        let editor = CallerEditorStore(caller: .prototype)
        let data = Data(#"{"name":"Jane Doe","dateOfBirth":"1990-05-20","insurance":"Example Health","additionalDetails":"Morning preferred","gender":"female","language":"German","telephoneNumber":"+49 123 45678","doctorReferralDetails":{"Referral":"Radiology"}}"#.utf8)

        editor.importJSONData(data, sourceURL: URL(fileURLWithPath: "/tmp/caller.json"))

        #expect(editor.importState == .imported)
        #expect(editor.sourceFilename == "caller.json")
        #expect(editor.name == "Jane Doe")
        #expect(editor.gender == .female)
        #expect(editor.language == "German")
        #expect(editor.telephoneNumber == "+49 123 45678")
        #expect(editor.referralRows.first?.key == "Referral")
        #expect(editor.referralRows.first?.value == "Radiology")
        #expect(editor.isValid)
    }

    @MainActor
    @Test func malformedImportProducesAnActionableErrorWithoutReplacingTheDraft() {
        let editor = CallerEditorStore(caller: .prototype)
        let originalDraft = editor.callerDraft

        editor.importJSONData(Data(#"{"name":42}"#.utf8))

        #expect(editor.importState == .idle)
        #expect(editor.importErrorMessage?.contains("wrong type") == true)
        #expect(editor.callerDraft == originalDraft)
    }

    @MainActor
    @Test func conversionTrimsValuesAndRejectsDuplicateReferralKeys() throws {
        let editor = CallerEditorStore(caller: .prototype)
        editor.name = "  Jane Doe  "
        editor.telephoneNumber = "  +49 123 45678  "
        editor.referralRows = [
            ReferralDraftRow(key: " Referral ", value: " Radiology "),
            ReferralDraftRow(key: "Referral", value: "Duplicate"),
        ]

        #expect(editor.validationIssues.contains { $0.field == .referralDetails })
        #expect(throws: CallerConfigurationValidationError.self) {
            try editor.inputConfiguration()
        }

        editor.referralRows.removeLast()
        let configuration = try editor.inputConfiguration()
        #expect(configuration.name == "Jane Doe")
        #expect(configuration.telephoneNumber == "+49 123 45678")
        #expect(configuration.doctorReferralDetails?["Referral"] == "Radiology")
    }

    @Test func phoneNumberValidationCoversCommonEdgeCases() {
        #expect(PhoneNumberValidator.isValid("+49 (30) 123-45"))
        #expect(!PhoneNumberValidator.isValid("1234"))
        #expect(!PhoneNumberValidator.isValid("+49 CALL-NOW"))
        #expect(!PhoneNumberValidator.isValid("   "))
    }
}

@Suite("Readiness and settings")
struct ReadinessAndSettingsTests {

    @Test func readinessRequiresEveryDependencyAndAFullDuplexDevice() {
        var state = AppViewState.prototype
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
        state.reduce(.setSettings(AppSettings(
            hasAPIKey: true,
            isPCMOutputEnabled: false,
            pcmOutputDirectory: nil,
            resultOutputDirectory: directory,
            preferredHFPDeviceAddress: nil,
            preferredAudioDeviceUID: nil
        )))
        state.reduce(.coordinator(.hfpConnectionChanged(address: "phone", isConnected: true)))
        state.reduce(.coordinator(.audioDevices([
            AudioDeviceOption(name: "Output only", uid: "output", hasInput: false, hasOutput: true),
        ])))
        state.reduce(.coordinator(.audioSelectionChanged(uid: "output")))
        #expect(!state.readiness.isReady)

        state.reduce(.coordinator(.audioDevices([
            AudioDeviceOption(name: "Call interface", uid: "duplex", hasInput: true, hasOutput: true),
        ])))
        state.reduce(.coordinator(.audioSelectionChanged(uid: "duplex")))
        #expect(state.readiness.isReady)

        state.reduce(.coordinator(.hfpConnectionChanged(address: "phone", isConnected: false)))
        #expect(!state.readiness.isReady)
    }

    @MainActor
    @Test func pcmOutputDefaultsToDisabled() throws {
        let suiteName = "RufuxTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(
            defaults: defaults,
            keychain: KeychainStore(service: suiteName)
        )

        #expect(!store.isPCMOutputEnabled)
        #expect(!store.appSettings.isPCMOutputEnabled)
        #expect(store.appSettings.pcmOutputDirectory == nil)
    }

#if DEBUG
    @MainActor
    @Test func nonSensitiveSettingsRoundTripThroughIsolatedDefaults() throws {
        let suiteName = "RufuxTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(
            defaults: defaults,
            keychain: KeychainStore(service: suiteName)
        )
        store.isPCMOutputEnabled = true
        store.setPreferredHFPDeviceAddress("  phone-address  ")
        store.setPreferredAudioDeviceUID("  audio-uid  ")

        let restored = SettingsStore(
            defaults: defaults,
            keychain: KeychainStore(service: suiteName)
        )
        #expect(restored.isPCMOutputEnabled)
        #expect(restored.appSettings.preferredHFPDeviceAddress == "phone-address")
        #expect(restored.appSettings.preferredAudioDeviceUID == "audio-uid")
    }
#endif

    @MainActor
    @Test func apiKeySaveLoadAndRemovalUseTheKeychainContract() async throws {
        let suiteName = "RufuxTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = InMemoryKeychainStore()
        let store = SettingsStore(defaults: defaults, keychain: keychain)

        store.apiKeyDraft = "  test-api-key  "
        await store.saveAPIKey()
        #expect(store.hasStoredAPIKey)
        #expect(try await store.openAIAPIKey() == "test-api-key")

        await store.removeAPIKey()
        #expect(!store.hasStoredAPIKey)
        #expect(keychain.apiKeyValue() == nil)
    }
}

@MainActor
@Suite("Call coordinator")
struct CallCoordinatorTests {

    @Test func successfulCallCleansUpOnceAndPublishesResultWithPCMFiles() async throws {
        let hfp = FakeHFPService()
        let audio = FakeAudioService()
        let agent = FakeAgentSession(closesAutomatically: true)
        let factory = FakeAgentFactory(session: agent)
        let coordinator = CallCoordinator(
            hfpService: hfp,
            audioService: audio,
            agentFactory: factory,
            cleanupTimeoutNanoseconds: 1_000_000_000
        )
        let events = CoordinatorEventRecorder()
        let eventTask = Task {
            for await event in coordinator.makeEventStream() {
                await events.append(event)
            }
        }
        defer { eventTask.cancel() }

        try await prepare(coordinator: coordinator)
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        await coordinator.startCall(makeRequest(directory: directory, pcmEnabled: true))
        hfp.emit(.callActive)
        #expect(await eventually { (await coordinator.deviceState()).callPhase == .active })

        let result = AppointmentResult(
            status: "booked",
            appointmentDate: "2026-11-03",
            appointmentTime: "10:30",
            practice: "Example Practice",
            notes: "Bring the referral."
        )
        let output = try #require(await factory.outputConfiguration())
        let pcmFiles = PCMOutputFiles(
            inputURL: directory.appending(path: "input.pcm"),
            outputURL: directory.appending(path: "output.pcm")
        )
        agent.emit(.resultWritten(result, output.resultURL))
        agent.emit(.pcmOutputReady(pcmFiles))

        await coordinator.endCall()
        await coordinator.endCall()
        hfp.emit(.callEnded)

        #expect(await eventually { (await coordinator.deviceState()).callPhase == .completed })
        #expect(await audio.operationCounts() == AudioOperationCounts(start: 1, stop: 1))
        #expect(await hfp.endCallCount() == 1)
        #expect(agent.closeCount() == 1)
        #expect(agent.lastFinalizeOutcome() == true)
        #expect(await eventually {
            await events.containsResult(result, pcmFiles: pcmFiles)
        })
        #expect(output.isPCMOutputEnabled)
        #expect(output.pcmOutputDirectory == directory)
    }

    @Test func pcmDisabledIsPassedToTheAgentWithoutAnOutputDirectory() async throws {
        let hfp = FakeHFPService()
        let audio = FakeAudioService()
        let factory = FakeAgentFactory(session: FakeAgentSession(closesAutomatically: true))
        let coordinator = CallCoordinator(
            hfpService: hfp,
            audioService: audio,
            agentFactory: factory
        )
        try await prepare(coordinator: coordinator)
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        await coordinator.startCall(makeRequest(directory: directory, pcmEnabled: false))

        let output = try #require(await factory.outputConfiguration())
        #expect(!output.isPCMOutputEnabled)
        #expect(output.pcmOutputDirectory == nil)
    }

    @Test func audioStartupFailureEndsTheCallAndRestoresAudio() async throws {
        let hfp = FakeHFPService()
        let audio = FakeAudioService(shouldFailStart: true)
        let agent = FakeAgentSession(closesAutomatically: true)
        let coordinator = CallCoordinator(
            hfpService: hfp,
            audioService: audio,
            agentFactory: FakeAgentFactory(session: agent)
        )
        try await prepare(coordinator: coordinator)
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        await coordinator.startCall(makeRequest(directory: directory, pcmEnabled: false))

        hfp.emit(.callActive)

        #expect(await eventually { (await coordinator.deviceState()).callPhase == .failed })
        #expect(await audio.operationCounts() == AudioOperationCounts(start: 1, stop: 1))
        #expect(await hfp.endCallCount() == 1)
        #expect(agent.closeCount() == 1)
    }

    @Test func stalledAgentClosureCannotLeaveCleanupRunningForever() async throws {
        let hfp = FakeHFPService()
        let audio = FakeAudioService()
        let agent = FakeAgentSession(closesAutomatically: false)
        let coordinator = CallCoordinator(
            hfpService: hfp,
            audioService: audio,
            agentFactory: FakeAgentFactory(session: agent),
            cleanupTimeoutNanoseconds: 20_000_000
        )
        try await prepare(coordinator: coordinator)
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        await coordinator.startCall(makeRequest(directory: directory, pcmEnabled: false))

        await coordinator.endCall()

        #expect(await eventually { (await coordinator.deviceState()).callPhase == .failed })
        #expect(await audio.operationCounts().stop == 1)
        #expect(agent.closeCount() == 1)
    }

    @Test func applicationShutdownStopsAudioAndDisconnectsThePhone() async throws {
        let hfp = FakeHFPService()
        let audio = FakeAudioService()
        let agent = FakeAgentSession(closesAutomatically: true)
        let coordinator = CallCoordinator(
            hfpService: hfp,
            audioService: audio,
            agentFactory: FakeAgentFactory(session: agent)
        )
        try await prepare(coordinator: coordinator)
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        await coordinator.startCall(makeRequest(directory: directory, pcmEnabled: false))
        hfp.emit(.callActive)
        #expect(await eventually { (await coordinator.deviceState()).callPhase == .active })

        await coordinator.shutdown()

        #expect(await audio.operationCounts().stop >= 1)
        #expect(await hfp.endCallCount() == 1)
        #expect(await hfp.disconnectCount() == 1)
        #expect(agent.lastFinalizeOutcome() == false)
    }

    private func prepare(coordinator: CallCoordinator) async throws {
        await coordinator.bootstrap()
        try await coordinator.connectHFPDevice(address: FakeHFPService.device.address)
        try await coordinator.selectAudioDevice(uid: FakeAudioService.device.uid)
    }

    private func makeRequest(directory: URL, pcmEnabled: Bool) -> CallStartRequest {
        CallStartRequest(
            apiKey: "test-key",
            configuration: CallerDraft.prototype.inputConfiguration(),
            phoneNumber: "+49 123 45678",
            resultOutputDirectory: directory,
            isPCMOutputEnabled: pcmEnabled,
            pcmOutputDirectory: pcmEnabled ? directory : nil
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "RufuxTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func eventually(
        attempts: Int = 100,
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }
}

private enum FakeCoordinatorError: Error {
    case audioStartFailed
}

private final class InMemoryKeychainStore: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storedAPIKey: String?

    func apiKey() -> String? {
        lock.withLock { storedAPIKey }
    }

    func saveAPIKey(_ key: String) {
        lock.withLock { storedAPIKey = key }
    }

    func removeAPIKey() {
        lock.withLock { storedAPIKey = nil }
    }

    func apiKeyValue() -> String? {
        lock.withLock { storedAPIKey }
    }
}

private actor FakeHFPService: HFPServicing {
    static let device = HFPDeviceOption(
        name: "Test Phone",
        address: "00:00:00:00:00:01",
        supportsHandsFreeGateway: true
    )

    nonisolated private let stream: AsyncStream<HFPEvent>
    nonisolated private let continuation: AsyncStream<HFPEvent>.Continuation
    private var isConnected = false
    private var hangupCount = 0
    private var disconnectionCount = 0

    init() {
        let pair = AsyncStream<HFPEvent>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func pairedDevices() -> [HFPDeviceOption] {
        [Self.device]
    }

    func connect(to address: String) throws {
        isConnected = address == Self.device.address
    }

    func disconnect() {
        isConnected = false
        disconnectionCount += 1
    }

    func dial(number: String) throws {
        guard isConnected else { throw CallServiceError.hfpDeviceNotConnected }
    }

    func endCall() throws {
        hangupCount += 1
    }

    func makeEventStream() -> AsyncStream<HFPEvent> {
        stream
    }

    func connectedDevice() -> HFPDevice? {
        nil
    }

    nonisolated func emit(_ event: HFPEvent) {
        continuation.yield(event)
    }

    func endCallCount() -> Int {
        hangupCount
    }

    func disconnectCount() -> Int {
        disconnectionCount
    }
}

private struct AudioOperationCounts: Equatable {
    let start: Int
    let stop: Int
}

private actor FakeAudioService: AudioServicing {
    static let device = AudioDeviceOption(
        name: "Test Call Interface",
        uid: "test-audio-device",
        hasInput: true,
        hasOutput: true
    )

    private let shouldFailStart: Bool
    private var selectedUID: String?
    private var startCount = 0
    private var stopCount = 0

    init(shouldFailStart: Bool = false) {
        self.shouldFailStart = shouldFailStart
    }

    func availableDevices() -> [AudioDeviceOption] {
        [Self.device]
    }

    func selectDevice(uid: String?) {
        selectedUID = uid
    }

    func selectedDevice() -> AudioDeviceOption? {
        selectedUID == Self.device.uid ? Self.device : nil
    }

    func startAudioSession() throws -> AudioSessionManager {
        startCount += 1
        if shouldFailStart {
            throw FakeCoordinatorError.audioStartFailed
        }
        return AudioSessionManager()
    }

    func stopAudioSession() {
        stopCount += 1
    }

    func operationCounts() -> AudioOperationCounts {
        AudioOperationCounts(start: startCount, stop: stopCount)
    }
}

private final class FakeAgentSession: AgentSessionServicing, @unchecked Sendable {
    private let stream: AsyncStream<AgentSessionEvent>
    private let continuation: AsyncStream<AgentSessionEvent>.Continuation
    private let closesAutomatically: Bool
    private let lock = NSLock()
    private var prepareInvocationCount = 0
    private var startInvocationCount = 0
    private var closeInvocationCount = 0
    private var finalizeOutcome: Bool?

    init(closesAutomatically: Bool) {
        self.closesAutomatically = closesAutomatically
        let pair = AsyncStream<AgentSessionEvent>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func makeEventStream() -> AsyncStream<AgentSessionEvent> {
        stream
    }

    func prepare() {
        lock.withLock { prepareInvocationCount += 1 }
    }

    func startAudio(using sessionManager: AudioSessionManager) throws {
        lock.withLock { startInvocationCount += 1 }
    }

    func close(finalizeOutcome: Bool) {
        lock.withLock {
            closeInvocationCount += 1
            self.finalizeOutcome = finalizeOutcome
        }
        if closesAutomatically {
            continuation.yield(.closed)
            continuation.finish()
        }
    }

    func emit(_ event: AgentSessionEvent) {
        continuation.yield(event)
    }

    func closeCount() -> Int {
        lock.withLock { closeInvocationCount }
    }

    func lastFinalizeOutcome() -> Bool? {
        lock.withLock { finalizeOutcome }
    }
}

private actor FakeAgentFactory: AgentSessionCreating {
    private let session: FakeAgentSession
    private var output: AgentSessionOutputConfiguration?

    init(session: FakeAgentSession) {
        self.session = session
    }

    func makeSession(
        apiKey: String,
        configuration: InputConfiguration,
        outputConfiguration: AgentSessionOutputConfiguration,
        hfpService: any HFPServicing
    ) -> any AgentSessionServicing {
        output = outputConfiguration
        return session
    }

    func outputConfiguration() -> AgentSessionOutputConfiguration? {
        output
    }
}

private actor CoordinatorEventRecorder {
    private var events: [CallCoordinatorEvent] = []

    func append(_ event: CallCoordinatorEvent) {
        events.append(event)
    }

    func containsResult(_ result: AppointmentResult, pcmFiles: PCMOutputFiles) -> Bool {
        events.contains { event in
            guard case .result(let callResult) = event else { return false }
            return callResult.appointment == result &&
                callResult.inputPCMURL == pcmFiles.inputURL &&
                callResult.outputPCMURL == pcmFiles.outputURL
        }
    }
}
