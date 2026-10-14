//
//  RufarooTests.swift
//  RufarooTests
//

import Foundation
import PhoneBTCore
import Testing
@testable import Rufux

struct CallCoordinatorLifecycleTests {
    @Test
    func waitsForActiveCallBeforeStartingAgentAndCleansUpOnce() async throws {
        let harness = try await CallCoordinatorHarness()
        let events = EventCollector()
        let eventTask = collect(harness.coordinator.makeEventStream(), into: events)
        defer { eventTask.cancel() }

        await harness.coordinator.startCall(harness.request)

        #expect(await harness.coordinator.deviceState().callPhase == .ringing)
        #expect(harness.agent.prepareCount == 0)
        #expect(await harness.audio.startCount == 0)

        harness.hfp.send(.callActive)
        #expect(await eventually {
            await harness.coordinator.deviceState().callPhase == .active
        })
        #expect(harness.agent.prepareCount == 1)
        #expect(harness.agent.startAudioCount == 1)
        #expect(await harness.audio.startCount == 1)

        let result = AppointmentResult(
            status: "booked",
            appointmentDate: "10-20",
            appointmentTime: "09:30",
            practice: "Example Practice",
            notes: "Booked"
        )
        harness.agent.send(.resultWritten(result, harness.resultDirectory.appending(path: "result.json")))
        harness.hfp.send(.callEnded)

        #expect(await eventually {
            await harness.coordinator.deviceState().callPhase == .completed
        })
        #expect(harness.agent.closeCount == 1)
        #expect(await harness.audio.stopCount == 1)

        harness.hfp.send(.callEnded)
        harness.hfp.send(.disconnected(nil))
        try await Task.sleep(for: .milliseconds(30))
        #expect(harness.agent.closeCount == 1)
        #expect(await harness.audio.stopCount == 1)
    }

    @Test
    func failedDialClosesSessionWithoutStartingAudio() async throws {
        let harness = try await CallCoordinatorHarness()
        await harness.hfp.setDialError(TestFailure.dial)

        await harness.coordinator.startCall(harness.request)

        #expect(await eventually {
            await harness.coordinator.deviceState().callPhase == .failed
        })
        #expect(harness.agent.closeCount == 1)
        #expect(harness.agent.prepareCount == 0)
        #expect(harness.agent.startAudioCount == 0)
        #expect(await harness.audio.startCount == 0)
        #expect(await harness.audio.stopCount == 1)
    }

    @Test
    func audioStartupFailureEndsPhoneCallAndReachesFailedState() async throws {
        let harness = try await CallCoordinatorHarness()
        await harness.audio.setStartError(TestFailure.audio)

        await harness.coordinator.startCall(harness.request)
        harness.hfp.send(.callActive)

        #expect(await eventually {
            await harness.coordinator.deviceState().callPhase == .failed
        })
        #expect(await harness.hfp.endCallCount == 1)
        #expect(harness.agent.closeCount == 1)
        #expect(await harness.audio.stopCount == 1)
    }

    @Test
    func reconnectingKeepsCallActiveButTerminalAgentFailureCleansUp() async throws {
        let harness = try await CallCoordinatorHarness()

        await harness.coordinator.startCall(harness.request)
        harness.hfp.send(.callActive)
        #expect(await eventually {
            await harness.coordinator.deviceState().callPhase == .active
        })

        harness.agent.send(.reconnecting(attempt: 1, maximumAttempts: 3, reason: "connection_lost"))
        try await Task.sleep(for: .milliseconds(30))
        #expect(await harness.coordinator.deviceState().callPhase == .active)

        harness.agent.send(.failure("GPT-Live reconnection stopped after 3 attempts"))
        #expect(await eventually {
            await harness.coordinator.deviceState().callPhase == .failed
        })
        #expect(await harness.hfp.endCallCount == 1)
        #expect(harness.agent.closeCount == 1)
        #expect(await harness.audio.stopCount == 1)
    }

}

private struct CallCoordinatorHarness {
    let hfp: FakeHFPService
    let audio: FakeAudioService
    let agent: FakeAgentSession
    let coordinator: CallCoordinator
    let request: CallStartRequest
    let resultDirectory: URL

    @MainActor
    init() async throws {
        let hfp = FakeHFPService()
        let audio = FakeAudioService()
        let agent = FakeAgentSession()
        let coordinator = CallCoordinator(
            hfpService: hfp,
            audioService: audio,
            agentFactory: FakeAgentFactory(session: agent)
        )

        let resultDirectory = FileManager.default.temporaryDirectory
            .appending(path: "RufuxTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: resultDirectory,
            withIntermediateDirectories: true
        )

        await coordinator.bootstrap()
        try await coordinator.connectHFPDevice(address: FakeHFPService.phone.address)
        try await coordinator.selectAudioDevice(uid: FakeAudioService.device.uid)

        self.hfp = hfp
        self.audio = audio
        self.agent = agent
        self.coordinator = coordinator
        self.resultDirectory = resultDirectory
        self.request = CallStartRequest(
            apiKey: "test-key",
            configuration: InputConfiguration(
                name: "Test Caller",
                dateOfBirth: "1990-01-01",
                insurance: "Test Insurance",
                additionalDetails: "Book a routine appointment",
                gender: .female,
                language: "English",
                telephoneNumber: "+49 12345",
                doctorReferralDetails: nil
            ),
            phoneNumber: "+49 12345",
            resultOutputDirectory: resultDirectory,
            isPCMOutputEnabled: false,
            pcmOutputDirectory: nil
        )
    }
}

private actor FakeHFPService: HFPServicing {
    static let phone = HFPDeviceOption(
        name: "Test Phone",
        address: "00:00:00:00:00:01",
        supportsHandsFreeGateway: true
    )

    private let events = HFPEventStream()
    private var dialError: (any Error)?
    private(set) var endCallCount = 0

    func pairedDevices() -> [HFPDeviceOption] { [Self.phone] }
    func connect(to address: String) throws {}
    func disconnect() {}
    func dial(number: String) throws {
        if let dialError { throw dialError }
    }
    func endCall() throws {
        endCallCount += 1
    }
    func makeEventStream() -> AsyncStream<HFPEvent> {
        events.makeStream()
    }
    func connectedDevice() -> HFPDevice? { nil }

    nonisolated func send(_ event: HFPEvent) {
        events.emit(event)
    }

    func setDialError(_ error: any Error) {
        dialError = error
    }
}

private actor FakeAudioService: AudioServicing {
    static let device = AudioDeviceOption(
        name: "Test Audio",
        uid: "test.audio",
        hasInput: true,
        hasOutput: true
    )

    private var selectedUID: String?
    private var startError: (any Error)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func availableDevices() -> [AudioDeviceOption] { [Self.device] }
    func selectDevice(uid: String?) {
        selectedUID = uid
    }
    func selectedDevice() -> AudioDeviceOption? {
        selectedUID == Self.device.uid ? Self.device : nil
    }
    func startAudioSession() throws -> AudioSessionManager {
        startCount += 1
        if let startError { throw startError }
        return AudioSessionManager()
    }
    func stopAudioSession() {
        stopCount += 1
    }
    func setStartError(_ error: any Error) {
        startError = error
    }
}

private nonisolated final class FakeAgentFactory: AgentSessionCreating, @unchecked Sendable {
    let session: FakeAgentSession

    init(session: FakeAgentSession) {
        self.session = session
    }

    func makeSession(
        apiKey: String,
        configuration: InputConfiguration,
        outputConfiguration: AgentSessionOutputConfiguration,
        hfpService: any HFPServicing
    ) async throws -> any AgentSessionServicing {
        session
    }
}

private nonisolated final class FakeAgentSession: AgentSessionServicing, @unchecked Sendable {
    private struct State {
        var prepareCount = 0
        var startAudioCount = 0
        var closeCount = 0
        var isClosed = false
    }

    private let lock = NSLock()
    private var state = State()
    private let stream: AsyncStream<AgentSessionEvent>
    private let continuation: AsyncStream<AgentSessionEvent>.Continuation

    init() {
        let pair = Self.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    var prepareCount: Int {
        lock.withLock { state.prepareCount }
    }

    var startAudioCount: Int {
        lock.withLock { state.startAudioCount }
    }

    var closeCount: Int {
        lock.withLock { state.closeCount }
    }

    func makeEventStream() -> AsyncStream<AgentSessionEvent> {
        stream
    }

    func prepare() {
        lock.withLock { state.prepareCount += 1 }
    }

    func startAudio(using sessionManager: AudioSessionManager) throws {
        lock.withLock { state.startAudioCount += 1 }
    }

    func close(finalizeOutcome: Bool) {
        let shouldClose = lock.withLock {
            guard !state.isClosed else { return false }
            state.isClosed = true
            state.closeCount += 1
            return true
        }
        if shouldClose {
            continuation.yield(.closed)
            continuation.finish()
        }
    }

    func send(_ event: AgentSessionEvent) {
        continuation.yield(event)
    }

    private static func makeStream() -> (
        stream: AsyncStream<AgentSessionEvent>,
        continuation: AsyncStream<AgentSessionEvent>.Continuation
    ) {
        var continuation: AsyncStream<AgentSessionEvent>.Continuation?
        let stream = AsyncStream<AgentSessionEvent> {
            continuation = $0
        }
        return (stream, continuation!)
    }
}

private actor EventCollector {
    private(set) var events: [CallCoordinatorEvent] = []

    func append(_ event: CallCoordinatorEvent) {
        events.append(event)
    }
}

private func collect(
    _ stream: AsyncStream<CallCoordinatorEvent>,
    into collector: EventCollector
) -> Task<Void, Never> {
    Task {
        for await event in stream {
            await collector.append(event)
        }
    }
}

private func eventually(
    timeout: Duration = .seconds(1),
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

private enum TestFailure: Error {
    case dial
    case audio
}
