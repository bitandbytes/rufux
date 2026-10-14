//
//  CallServices.swift
//  Rufux
//

import Foundation
import PhoneBTCore

enum CallServiceError: LocalizedError {
    case hfpDeviceNotFound
    case hfpDeviceDoesNotSupportHandsFree
    case hfpDeviceNotConnected
    case audioDeviceNotSelected
    case audioDeviceUnavailable
    case audioRoutingFailed
    case deviceOperationInProgress
    case deviceChangesUnavailableDuringCall
    case callAlreadyInProgress
    case invalidCallerConfiguration
    case invalidPhoneNumber
    case missingAPIKey
    case invalidOutputDirectory(URL)

    var errorDescription: String? {
        switch self {
        case .hfpDeviceNotFound:
            return "The selected HFP phone is no longer available."
        case .hfpDeviceDoesNotSupportHandsFree:
            return "The selected Bluetooth device does not provide the Hands-Free Profile."
        case .hfpDeviceNotConnected:
            return "Connect an HFP phone before starting a call."
        case .audioDeviceNotSelected:
            return "Select a full-duplex call audio interface."
        case .audioDeviceUnavailable:
            return "The selected call audio interface is no longer available."
        case .audioRoutingFailed:
            return "The selected call audio interface could not be routed."
        case .deviceOperationInProgress:
            return "Wait for the current device operation to finish."
        case .deviceChangesUnavailableDuringCall:
            return "Devices cannot be changed while a call is in progress."
        case .callAlreadyInProgress:
            return "A call is already in progress or is still being finalized."
        case .invalidCallerConfiguration:
            return "Complete the required caller information before starting a call."
        case .invalidPhoneNumber:
            return "Enter a valid telephone number before starting a call."
        case .missingAPIKey:
            return "Save an OpenAI API key before starting a call."
        case .invalidOutputDirectory(let url):
            return "Rufux cannot write to the output folder at \(url.path)."
        }
    }
}

nonisolated protocol HFPServicing: Sendable {
    func pairedDevices() async -> [HFPDeviceOption]
    func connect(to address: String) async throws
    func disconnect() async
    func dial(number: String) async throws
    func endCall() async throws
    func makeEventStream() async -> AsyncStream<HFPEvent>
    func connectedDevice() async -> HFPDevice?
}

nonisolated protocol AudioServicing: Sendable {
    func availableDevices() async -> [AudioDeviceOption]
    func selectDevice(uid: String?) async
    func selectedDevice() async -> AudioDeviceOption?
    func startAudioSession() async throws -> AudioSessionManager
    func stopAudioSession() async
}

nonisolated protocol AgentSessionServicing: Sendable {
    func makeEventStream() -> AsyncStream<AgentSessionEvent>
    func prepare()
    func startAudio(using sessionManager: AudioSessionManager) throws
    func close(finalizeOutcome: Bool)
}

nonisolated protocol AgentSessionCreating: Sendable {
    func makeSession(
        apiKey: String,
        configuration: InputConfiguration,
        outputConfiguration: AgentSessionOutputConfiguration,
        hfpService: any HFPServicing
    ) async throws -> any AgentSessionServicing
}

actor LiveHFPService: HFPServicing {
    private let manager: BluetoothManager
    private var device: HFPDevice?

    init(manager: BluetoothManager = BluetoothManager()) {
        self.manager = manager
    }

    func pairedDevices() -> [HFPDeviceOption] {
        manager.getPairedPhones()
            .filter(\.isHandsFreeGateway)
            .map {
                HFPDeviceOption(
                    name: $0.name,
                    address: $0.address,
                    supportsHandsFreeGateway: $0.isHandsFreeGateway
                )
            }
            .sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    func connect(to address: String) async throws {
        let pairedPhone = manager.getPairedPhones().first { $0.address == address }
        guard let pairedPhone else {
            throw CallServiceError.hfpDeviceNotFound
        }
        guard pairedPhone.isHandsFreeGateway else {
            throw CallServiceError.hfpDeviceDoesNotSupportHandsFree
        }
        guard let bluetoothDevice = manager.device(forAddress: address),
              let hfpDevice = HFPDevice(bluetoothDevice: bluetoothDevice) else {
            throw CallServiceError.hfpDeviceNotFound
        }
        try await hfpDevice.connect()
        device = hfpDevice
    }

    func disconnect() {
        device?.disconnect()
        device = nil
    }

    func dial(number: String) throws {
        guard let device else { throw CallServiceError.hfpDeviceNotConnected }
        try device.dial(number: number)
    }

    func endCall() throws {
        guard let device else { throw CallServiceError.hfpDeviceNotConnected }
        try device.endCall()
    }

    func makeEventStream() -> AsyncStream<HFPEvent> {
        guard let device else {
            return AsyncStream { $0.finish() }
        }
        return device.eventStream.makeStream()
    }

    func connectedDevice() -> HFPDevice? {
        device
    }
}

actor LiveAudioService: AudioServicing {
    private let router: AudioRouter
    private var sessionManager: AudioSessionManager?
    private var selectedDeviceUID: String?
    private var isCallAudioRouted = false

    init(router: AudioRouter = AudioRouter()) {
        self.router = router
    }

    func availableDevices() -> [AudioDeviceOption] {
        router.allDevices()
            .filter { $0.hasInput && $0.hasOutput }
            .map {
                AudioDeviceOption(
                    name: $0.name,
                    uid: $0.uid,
                    hasInput: $0.hasInput,
                    hasOutput: $0.hasOutput
                )
            }
            .sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    func selectDevice(uid: String?) {
        selectedDeviceUID = uid
        router.setPreferredDeviceUID(uid)
    }

    func selectedDevice() -> AudioDeviceOption? {
        guard let selectedDeviceUID else { return nil }
        return availableDevices().first { $0.uid == selectedDeviceUID }
    }

    func startAudioSession() throws -> AudioSessionManager {
        guard selectedDeviceUID != nil else {
            throw CallServiceError.audioDeviceNotSelected
        }
        guard let selectedDevice = selectedDevice(),
              let device = router.allDevices().first(where: { $0.uid == selectedDevice.uid }) else {
            throw CallServiceError.audioDeviceUnavailable
        }
        guard router.routeToCallAudioDevice() else {
            throw CallServiceError.audioRoutingFailed
        }
        isCallAudioRouted = true

        let manager = AudioSessionManager()
        do {
            try manager.configure(deviceID: device.id)
            try manager.start()
            sessionManager = manager
            return manager
        } catch {
            restoreRoutingIfNeeded()
            throw error
        }
    }

    func stopAudioSession() {
        sessionManager?.stop()
        sessionManager = nil
        restoreRoutingIfNeeded()
    }

    private func restoreRoutingIfNeeded() {
        guard isCallAudioRouted else { return }
        router.restorePreviousRouting()
        isCallAudioRouted = false
    }
}

nonisolated final class LiveAgentSession: AgentSessionServicing, @unchecked Sendable {
    private let session: AgentSession

    init(session: AgentSession) {
        self.session = session
    }

    func makeEventStream() -> AsyncStream<AgentSessionEvent> {
        session.eventStream.makeStream()
    }

    func prepare() {
        session.prepare()
    }

    func startAudio(using sessionManager: AudioSessionManager) throws {
        try session.startAudio(using: sessionManager)
    }

    func close(finalizeOutcome: Bool) {
        session.close(finalizeOutcome: finalizeOutcome)
    }
}

struct LiveAgentSessionFactory: AgentSessionCreating {
    nonisolated init() {}

    func makeSession(
        apiKey: String,
        configuration: InputConfiguration,
        outputConfiguration: AgentSessionOutputConfiguration,
        hfpService: any HFPServicing
    ) async throws -> any AgentSessionServicing {
        guard let device = await hfpService.connectedDevice() else {
            throw CallServiceError.hfpDeviceNotConnected
        }
        return LiveAgentSession(session: AgentSession(
            apiKey: apiKey,
            configuration: configuration,
            outputConfiguration: outputConfiguration,
            device: device
        ))
    }
}
