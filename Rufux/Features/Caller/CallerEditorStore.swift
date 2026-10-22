//
//  CallerEditorStore.swift
//  Rufux
//

import Foundation
import Observation
import PhoneBTCore

nonisolated struct ReferralDraftRow: Identifiable, Equatable, Sendable {
    let id: UUID
    var key: String
    var value: String

    init(id: UUID = UUID(), key: String = "", value: String = "") {
        self.id = id
        self.key = key
        self.value = value
    }
}

nonisolated enum CallerImportState: Equatable, Sendable {
    case idle
    case importing
    case imported
}

nonisolated struct CallerValidationIssue: Identifiable, Equatable, Sendable {
    nonisolated enum Field: String, Sendable {
        case name
        case dateOfBirth
        case insurance
        case additionalDetails
        case telephoneNumber
        case referralDetails
    }

    let field: Field
    let message: String

    var id: Field { field }
}

nonisolated struct CallerConfigurationValidationError: LocalizedError, Equatable, Sendable {
    let issues: [CallerValidationIssue]

    var errorDescription: String? {
        issues.map(\.message).joined(separator: " ")
    }
}

@MainActor
@Observable
final class CallerEditorStore {
    var name: String
    var dateOfBirth: String
    var insurance: String
    var additionalDetails: String
    var gender: VoiceGender?
    var language: String
    var telephoneNumber: String
    var referralRows: [ReferralDraftRow]

    private(set) var sourceURL: URL?
    private(set) var importState: CallerImportState = .idle
    private(set) var importErrorMessage: String?

    @ObservationIgnored private var importTask: Task<Void, Never>?

    init(caller: CallerDraft? = nil, sourceURL: URL? = nil) {
        let caller = caller ?? .prototype
        name = caller.name
        dateOfBirth = caller.dateOfBirth
        insurance = caller.insurance
        additionalDetails = caller.additionalDetails
        gender = caller.gender
        language = caller.language
        telephoneNumber = caller.telephoneNumber
        referralRows = Self.makeReferralRows(from: caller.doctorReferralDetails)
        self.sourceURL = sourceURL
    }

    var sourceFilename: String? {
        sourceURL?.lastPathComponent
    }

    var callerDraft: CallerDraft {
        CallerDraft(
            name: name,
            dateOfBirth: dateOfBirth,
            insurance: insurance,
            additionalDetails: additionalDetails,
            gender: gender,
            language: language,
            telephoneNumber: telephoneNumber,
            doctorReferralDetails: referralDetails
        )
    }

    var validationIssues: [CallerValidationIssue] {
        var issues: [CallerValidationIssue] = []

        if trimmed(name).isEmpty {
            issues.append(CallerValidationIssue(field: .name, message: "Enter the caller's name."))
        }
        if trimmed(dateOfBirth).isEmpty {
            issues.append(CallerValidationIssue(field: .dateOfBirth, message: "Enter the caller's date of birth."))
        }
        if trimmed(insurance).isEmpty {
            issues.append(CallerValidationIssue(field: .insurance, message: "Enter the caller's insurance details."))
        }
        if trimmed(additionalDetails).isEmpty {
            issues.append(CallerValidationIssue(
                field: .additionalDetails,
                message: "Enter the purpose or details of the appointment."
            ))
        }

        let phoneNumber = PhoneNumberValidator.normalized(telephoneNumber)
        if phoneNumber.isEmpty {
            issues.append(CallerValidationIssue(field: .telephoneNumber, message: "Enter a telephone number."))
        } else if !PhoneNumberValidator.isValid(phoneNumber) {
            issues.append(CallerValidationIssue(
                field: .telephoneNumber,
                message: "Use a valid telephone number containing at least five digits."
            ))
        }

        if hasDuplicateReferralKeys {
            issues.append(CallerValidationIssue(
                field: .referralDetails,
                message: "Referral field names must be unique."
            ))
        }

        return issues
    }

    var isValid: Bool {
        validationIssues.isEmpty
    }

    func inputConfiguration() throws -> InputConfiguration {
        let issues = validationIssues
        guard issues.isEmpty else {
            throw CallerConfigurationValidationError(issues: issues)
        }

        return InputConfiguration(
            name: trimmed(name),
            dateOfBirth: trimmed(dateOfBirth),
            insurance: trimmed(insurance),
            additionalDetails: trimmed(additionalDetails),
            gender: gender,
            language: nilIfEmpty(language),
            telephoneNumber: trimmed(telephoneNumber),
            doctorReferralDetails: referralDetails.isEmpty ? nil : referralDetails
        )
    }

    func importFile(at url: URL) {
        importTask?.cancel()
        importErrorMessage = nil
        importState = .importing

        importTask = Task { [weak self] in
            do {
                let configuration = try await Task.detached(priority: .userInitiated) {
                    try Self.readConfiguration(at: url)
                }.value
                try Task.checkCancellation()
                self?.apply(configuration, sourceURL: url)
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                importState = .idle
                importErrorMessage = Self.actionableMessage(for: error)
            }
        }
    }

    func importJSONData(_ data: Data, sourceURL: URL? = nil) {
        do {
            let configuration = try JSONDecoder().decode(InputConfiguration.self, from: data)
            apply(configuration, sourceURL: sourceURL)
        } catch {
            importState = .idle
            importErrorMessage = Self.actionableMessage(for: error)
        }
    }

    func addReferralRow() {
        referralRows.append(ReferralDraftRow())
    }

    func removeReferralRow(id: ReferralDraftRow.ID) {
        referralRows.removeAll { $0.id == id }
    }

    func dismissImportError() {
        importErrorMessage = nil
    }

    private var referralDetails: [String: String] {
        referralRows.reduce(into: [:]) { details, row in
            let key = trimmed(row.key)
            guard !key.isEmpty else { return }
            details[key] = trimmed(row.value)
        }
    }

    private var hasDuplicateReferralKeys: Bool {
        let keys = referralRows.map { trimmed($0.key) }.filter { !$0.isEmpty }
        return Set(keys).count != keys.count
    }

    private func apply(_ configuration: InputConfiguration, sourceURL: URL?) {
        name = configuration.name
        dateOfBirth = configuration.dateOfBirth
        insurance = configuration.insurance
        additionalDetails = configuration.additionalDetails
        gender = configuration.gender
        language = configuration.language ?? ""
        telephoneNumber = configuration.telephoneNumber ?? ""
        referralRows = Self.makeReferralRows(from: configuration.doctorReferralDetails ?? [:])
        self.sourceURL = sourceURL
        importState = .imported
        importErrorMessage = nil
    }

    private static func makeReferralRows(from details: [String: String]) -> [ReferralDraftRow] {
        details.keys.sorted().map { key in
            ReferralDraftRow(key: key, value: details[key, default: ""])
        }
    }

    nonisolated private static func readConfiguration(at url: URL) throws -> InputConfiguration {
        guard url.pathExtension.lowercased() == "json" else {
            throw CallerImportError.unsupportedFileType
        }

        let didAccessResource = url.startAccessingSecurityScopedResource()
        defer {
            if didAccessResource {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try JSONDecoder().decode(InputConfiguration.self, from: data)
    }

    nonisolated private static func actionableMessage(for error: Error) -> String {
        switch error {
        case CallerImportError.unsupportedFileType:
            return "Choose a JSON file with a .json extension."
        case let DecodingError.keyNotFound(key, context):
            return "The JSON is missing the required \"\(key.stringValue)\" field\(codingPathSuffix(context.codingPath))."
        case let DecodingError.typeMismatch(_, context):
            return "A JSON value has the wrong type\(codingPathSuffix(context.codingPath))."
        case let DecodingError.valueNotFound(_, context):
            return "A required JSON value is null\(codingPathSuffix(context.codingPath))."
        case let DecodingError.dataCorrupted(context):
            return "The file is not valid caller JSON: \(context.debugDescription)"
        case let cocoaError as CocoaError where cocoaError.code == .fileReadNoPermission:
            return "Rufux does not have permission to read this file. Choose it again in the file picker."
        default:
            return "The caller file could not be imported: \(error.localizedDescription)"
        }
    }

    nonisolated private static func codingPathSuffix(_ path: [any CodingKey]) -> String {
        guard !path.isEmpty else { return "" }
        return " at \"\(path.map(\.stringValue).joined(separator: "."))\""
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func nilIfEmpty(_ value: String) -> String? {
        let value = trimmed(value)
        return value.isEmpty ? nil : value
    }
}

private enum CallerImportError: Error {
    case unsupportedFileType
}
