//
//  AppModels.swift
//  Rufux
//

import Foundation
import PhoneBTCore

nonisolated enum PhoneNumberValidator {
    static func isValid(_ value: String) -> Bool {
        let normalizedValue = normalized(value)
        let digits = normalizedValue.filter(\.isNumber)
        let allowedCharacters = CharacterSet(charactersIn: "+-(). ").union(.decimalDigits)
        return digits.count >= 5 &&
            normalizedValue.unicodeScalars.allSatisfy(allowedCharacters.contains)
    }

    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

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

nonisolated enum CallWarningKind: Equatable, Sendable {
    case reconnecting
    case pcmOutput
}

nonisolated enum CallActivityEvent: Equatable, Sendable {
    case validationStarted
    case phoneConnecting
    case phoneConnected
    case dialing
    case ringing
    case callActive
    case callEnded
    case phoneDisconnected
    case ending
    case preparingAssistant
    case waitingForCallee
    case calleeSpeaking
    case assistantSpeaking
    case waitingForReasoning
    case conversationInProgress
    case recoveringResult
    case reconnecting(attempt: Int, maximumAttempts: Int)
    case resultRecorded
    case finalizing
    case completed
    case warning(String)
    case failure(String)

    func makeEntry(timestamp: Date = Date()) -> CallActivityEntry {
        CallActivityEntry(
            timestamp: timestamp,
            kind: kind,
            message: message,
            coalescingKey: coalescingKey
        )
    }

    private var kind: CallActivityKind {
        switch self {
        case .phoneConnected, .callActive, .resultRecorded, .completed:
            return .success
        case .reconnecting, .warning:
            return .warning
        case .failure:
            return .failure
        default:
            return .information
        }
    }

    private var message: String {
        switch self {
        case .validationStarted:
            return String(localized: "Validating call settings")
        case .phoneConnecting:
            return String(localized: "Connecting to the HFP phone")
        case .phoneConnected:
            return String(localized: "HFP phone connected")
        case .dialing:
            return String(localized: "Dialing the selected telephone number")
        case .ringing:
            return String(localized: "Phone is ringing")
        case .callActive:
            return String(localized: "Call active · assistant audio started")
        case .callEnded:
            return String(localized: "Telephone call ended")
        case .phoneDisconnected:
            return String(localized: "HFP phone disconnected")
        case .ending:
            return String(localized: "Ending the telephone call")
        case .preparingAssistant:
            return String(localized: "Preparing the call assistant")
        case .waitingForCallee:
            return String(localized: "Waiting for the callee to speak")
        case .calleeSpeaking:
            return String(localized: "Callee speaking")
        case .assistantSpeaking:
            return String(localized: "Assistant speaking")
        case .waitingForReasoning:
            return String(localized: "Waiting for appointment reasoning")
        case .conversationInProgress:
            return String(localized: "Appointment discussion in progress")
        case .recoveringResult:
            return String(localized: "Recovering the final appointment result")
        case .reconnecting(let attempt, let maximumAttempts):
            return String(localized: "Reconnecting the assistant (\(attempt)/\(maximumAttempts))")
        case .resultRecorded:
            return String(localized: "Appointment result recorded")
        case .finalizing:
            return String(localized: "Finalizing the result and restoring audio routing")
        case .completed:
            return String(localized: "Call cleanup completed")
        case .warning(let message), .failure(let message):
            return message
        }
    }

    private var coalescingKey: String {
        switch self {
        case .validationStarted: "validation"
        case .phoneConnecting: "phone-connecting"
        case .phoneConnected: "phone-connected"
        case .dialing: "dialing"
        case .ringing: "ringing"
        case .callActive: "call-active"
        case .callEnded: "call-ended"
        case .phoneDisconnected: "phone-disconnected"
        case .ending: "ending"
        case .preparingAssistant: "assistant-preparing"
        case .waitingForCallee: "waiting-for-callee"
        case .calleeSpeaking: "callee-speaking"
        case .assistantSpeaking: "assistant-speaking"
        case .waitingForReasoning: "waiting-for-reasoning"
        case .conversationInProgress: "conversation-in-progress"
        case .recoveringResult: "recovering-result"
        case .reconnecting: "reconnecting"
        case .resultRecorded: "result-recorded"
        case .finalizing: "finalizing"
        case .completed: "completed"
        case .warning(let message): "warning:\(message)"
        case .failure(let message): "failure:\(message)"
        }
    }
}

nonisolated struct CallActivityEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let kind: CallActivityKind
    let message: String
    let coalescingKey: String
    let occurrenceCount: Int

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        kind: CallActivityKind = .information,
        message: String,
        coalescingKey: String? = nil,
        occurrenceCount: Int = 1
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.message = message
        self.coalescingKey = coalescingKey ?? message
        self.occurrenceCount = occurrenceCount
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

nonisolated enum AppointmentOutcome: Equatable, Sendable {
    case booked
    case notBooked
    case unknown

    init(status: String) {
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "booked":
            self = .booked
        case "not_booked", "not-booked", "not booked":
            self = .notBooked
        default:
            self = .unknown
        }
    }
}

nonisolated enum CallOutputURLBuilder {
    static func resultURL(
        in directory: URL,
        date: Date = Date(),
        identifier: UUID = UUID()
    ) -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: date)
            .replacingOccurrences(of: ":", with: "-")
        let filename = "rufux-\(timestamp)-\(identifier.uuidString.lowercased())-appointment-result.json"
        return directory.appendingPathComponent(filename, isDirectory: false)
    }
}

nonisolated struct CallResult: Equatable, Sendable {
    let appointment: AppointmentResult
    let resultURL: URL
    let inputPCMURL: URL?
    let outputPCMURL: URL?

    var outcome: AppointmentOutcome {
        AppointmentOutcome(status: appointment.status)
    }

    var pcmURLs: [URL] {
        [inputPCMURL, outputPCMURL].compactMap { $0 }
    }
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
    var callStartedAt: Date?
    var callEndedAt: Date?
    var readiness: CallReadiness
    var latestResult: CallResult?
    var warningKind: CallWarningKind?
    var warningMessage: String?
    var errorMessage: String?

    static let prototype = AppViewState(
        caller: .prototype,
        availableHFPDevices: [],
        availableAudioDevices: [],
        selection: DeviceSelection(),
        settings: .empty,
        callPhase: .idle,
        activityEntries: [],
        callStartedAt: nil,
        callEndedAt: nil,
        readiness: .empty,
        latestResult: nil,
        warningKind: nil,
        warningMessage: nil,
        errorMessage: nil
    )
}
