//
//  AppModels.swift
//  Rufux
//

import Foundation
import PhoneBTCore

nonisolated struct CallerDraft: Equatable, Sendable {
    var name: String
    var dateOfBirth: String
    var insurance: String
    var additionalDetails: String
    var gender: VoiceGender?
    var language: String
    var telephoneNumber: String
    var doctorReferralDetails: [String: String]

    var hasRequiredInformation: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !dateOfBirth.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !insurance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !additionalDetails.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !telephoneNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func inputConfiguration() -> InputConfiguration {
        InputConfiguration(
            name: name,
            dateOfBirth: dateOfBirth,
            insurance: insurance,
            additionalDetails: additionalDetails,
            gender: gender,
            language: language,
            telephoneNumber: telephoneNumber,
            doctorReferralDetails: doctorReferralDetails.isEmpty ? nil : doctorReferralDetails
        )
    }

    static let prototype = CallerDraft(
        name: "Max Mustermann",
        dateOfBirth: "1990-05-20",
        insurance: "Example Health, member 123456",
        additionalDetails: "Request a routine appointment, preferably in the morning.",
        gender: .male,
        language: "German",
        telephoneNumber: "+49 123 456 7890",
        doctorReferralDetails: [
            "Referral": "Radiology",
            "Request": "MammaSono bilateral, mammography if required",
        ]
    )
}

nonisolated struct HFPDeviceOption: Identifiable, Equatable, Sendable {
    let name: String
    let address: String
    let supportsHandsFreeGateway: Bool

    var id: String { address }
}

nonisolated struct AudioDeviceOption: Identifiable, Equatable, Sendable {
    let name: String
    let uid: String
    let hasInput: Bool
    let hasOutput: Bool

    var id: String { uid }
    var isFullDuplex: Bool { hasInput && hasOutput }
}

nonisolated struct DeviceSelection: Equatable, Sendable {
    var hfpDeviceAddress: String?
    var audioDeviceUID: String?
}

nonisolated struct CallStartRequest: Equatable, Sendable {
    let apiKey: String
    let configuration: InputConfiguration
    let phoneNumber: String
    let resultOutputDirectory: URL
    let isPCMOutputEnabled: Bool
    let pcmOutputDirectory: URL?
}

nonisolated enum CallPhase: String, Equatable, Sendable {
    case idle
    case validating
    case dialing
    case ringing
    case active
    case ending
    case finalizing
    case completed
    case failed

    var isCallInProgress: Bool {
        switch self {
        case .validating, .dialing, .ringing, .active, .ending, .finalizing:
            return true
        case .idle, .completed, .failed:
            return false
        }
    }
}

nonisolated enum CallActivityKind: String, Equatable, Sendable {
    case information
    case success
    case warning
    case failure
}

nonisolated struct CallActivityEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let kind: CallActivityKind
    let message: String

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        kind: CallActivityKind = .information,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.message = message
    }
}

nonisolated struct CallReadiness: Equatable, Sendable {
    var hasCallerInformation: Bool
    var hasAPIKey: Bool
    var isHFPConnected: Bool
    var hasFullDuplexAudioDevice: Bool
    var hasValidOutputConfiguration: Bool

    var isReady: Bool {
        hasCallerInformation &&
            hasAPIKey &&
            isHFPConnected &&
            hasFullDuplexAudioDevice &&
            hasValidOutputConfiguration
    }

    static let empty = CallReadiness(
        hasCallerInformation: false,
        hasAPIKey: false,
        isHFPConnected: false,
        hasFullDuplexAudioDevice: false,
        hasValidOutputConfiguration: false
    )
}

nonisolated struct CallResult: Equatable, Sendable {
    let appointment: AppointmentResult
    let resultURL: URL
    let inputPCMURL: URL?
    let outputPCMURL: URL?
}

nonisolated struct AppSettings: Equatable, Sendable {
    var hasAPIKey: Bool
    var isPCMOutputEnabled: Bool
    var pcmOutputDirectory: URL?
    var resultOutputDirectory: URL?
    var preferredHFPDeviceAddress: String?
    var preferredAudioDeviceUID: String?

    var hasValidOutputConfiguration: Bool {
        resultOutputDirectory != nil && (!isPCMOutputEnabled || pcmOutputDirectory != nil)
    }

    static let empty = AppSettings(
        hasAPIKey: false,
        isPCMOutputEnabled: true,
        pcmOutputDirectory: nil,
        resultOutputDirectory: nil,
        preferredHFPDeviceAddress: nil,
        preferredAudioDeviceUID: nil
    )
}

nonisolated struct AppViewState: Equatable, Sendable {
    var caller: CallerDraft
    var availableHFPDevices: [HFPDeviceOption]
    var availableAudioDevices: [AudioDeviceOption]
    var selection: DeviceSelection
    var settings: AppSettings
    var callPhase: CallPhase
    var activityEntries: [CallActivityEntry]
    var readiness: CallReadiness
    var latestResult: CallResult?
    var errorMessage: String?

    static let prototype = AppViewState(
        caller: .prototype,
        availableHFPDevices: [],
        availableAudioDevices: [],
        selection: DeviceSelection(),
        settings: .empty,
        callPhase: .idle,
        activityEntries: [],
        readiness: .empty,
        latestResult: nil,
        errorMessage: nil
    )
}
