//
//  SettingsPersistence.swift
//  Rufux
//

import Foundation
import Observation
import Security

enum SettingsPersistenceError: LocalizedError, Equatable {
    case keychain(operation: String, status: OSStatus)
    case missingAPIKey
    case invalidDirectory(URL, reason: String)
    case bookmark(URL, reason: String)

    var errorDescription: String? {
        switch self {
        case .keychain(let operation, let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "Error \(status)"
            return "Could not \(operation) the OpenAI API key. \(detail)"
        case .missingAPIKey:
            return "Enter an OpenAI API key before starting a call."
        case .invalidDirectory(let url, let reason):
            return "The folder “\(url.lastPathComponent)” cannot be used. \(reason)"
        case .bookmark(let url, let reason):
            return "Access to “\(url.lastPathComponent)” could not be saved. \(reason)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .keychain:
            return "Check that Keychain Access is available, then try saving again."
        case .missingAPIKey:
            return "Open Settings and save a valid API key."
        case .invalidDirectory:
            return "Choose an existing folder for which you have write permission."
        case .bookmark:
            return "Choose the folder again to renew access."
        }
    }
}

struct SettingsIssue: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    let recoverySuggestion: String?

    init(title: String, error: any Error) {
        self.title = title
        if let localizedError = error as? any LocalizedError {
            message = localizedError.errorDescription ?? error.localizedDescription
            recoverySuggestion = localizedError.recoverySuggestion
        } else {
            message = error.localizedDescription
            recoverySuggestion = nil
        }
    }
}

struct KeychainStore: @unchecked Sendable {
    private let service: String
    private let account = "openai-api-key"

    nonisolated init(service: String = Bundle.main.bundleIdentifier ?? "Rufux") {
        self.service = service
    }

    nonisolated func apiKey() throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw SettingsPersistenceError.keychain(operation: "read", status: status)
        }
        guard let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
            throw SettingsPersistenceError.keychain(operation: "decode", status: errSecDecode)
        }
        return key
    }

    nonisolated func saveAPIKey(_ key: String) throws {
        let data = Data(key.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw SettingsPersistenceError.keychain(operation: "update", status: updateStatus)
        }

        var newItem = query
        attributes.forEach { newItem[$0.key] = $0.value }
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw SettingsPersistenceError.keychain(operation: "save", status: addStatus)
        }
    }

    nonisolated func removeAPIKey() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SettingsPersistenceError.keychain(operation: "remove", status: status)
        }
    }
}

@MainActor
@Observable
final class SettingsStore {
    static let shared = SettingsStore()

    private(set) var isLoaded = false
    private(set) var hasStoredAPIKey = false
    private(set) var isSavingAPIKey = false
    var apiKeyDraft = ""
    var isPCMOutputEnabled: Bool {
        didSet { defaults.set(isPCMOutputEnabled, forKey: Keys.isPCMOutputEnabled) }
    }
    private(set) var resultOutputDirectory: URL?
    private(set) var pcmOutputDirectory: URL?
    private(set) var preferredHFPDeviceAddress: String?
    private(set) var preferredAudioDeviceUID: String?
    var issue: SettingsIssue?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keychain: KeychainStore
    @ObservationIgnored private var isLoading = false
    @ObservationIgnored private var resultAccessWasStarted = false
    @ObservationIgnored private var pcmAccessWasStarted = false

    init(
        defaults: UserDefaults = .standard,
        keychain: KeychainStore = KeychainStore()
    ) {
        self.defaults = defaults
        self.keychain = keychain
        isPCMOutputEnabled = defaults.object(forKey: Keys.isPCMOutputEnabled) == nil
            ? true
            : defaults.bool(forKey: Keys.isPCMOutputEnabled)
        preferredHFPDeviceAddress = defaults.string(forKey: Keys.preferredHFPDeviceAddress)
        preferredAudioDeviceUID = defaults.string(forKey: Keys.preferredAudioDeviceUID)
    }

    var appSettings: AppSettings {
        AppSettings(
            hasAPIKey: hasStoredAPIKey,
            isPCMOutputEnabled: isPCMOutputEnabled,
            pcmOutputDirectory: pcmOutputDirectory,
            resultOutputDirectory: resultOutputDirectory,
            preferredHFPDeviceAddress: preferredHFPDeviceAddress,
            preferredAudioDeviceUID: preferredAudioDeviceUID
        )
    }

    func load() async {
        guard !isLoaded, !isLoading else { return }
        isLoading = true
        defer {
            isLoading = false
            isLoaded = true
        }

        do {
            let keychain = keychain
            let storedKey = try await Task.detached {
                try keychain.apiKey()
            }.value
            apiKeyDraft = storedKey ?? ""
            hasStoredAPIKey = storedKey?.isEmpty == false
        } catch {
            issue = SettingsIssue(title: "API key unavailable", error: error)
        }

        resultOutputDirectory = restoreDirectory(
            bookmarkKey: Keys.resultOutputBookmark,
            accessWasStarted: &resultAccessWasStarted
        ) ?? prepareDefaultDirectory(named: "Results")
        pcmOutputDirectory = restoreDirectory(
            bookmarkKey: Keys.pcmOutputBookmark,
            accessWasStarted: &pcmAccessWasStarted
        ) ?? prepareDefaultDirectory(named: "Recordings")
    }

    func saveAPIKey() async {
        let trimmedKey = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            issue = SettingsIssue(title: "API key required", error: SettingsPersistenceError.missingAPIKey)
            return
        }

        isSavingAPIKey = true
        defer { isSavingAPIKey = false }
        do {
            let keychain = keychain
            try await Task.detached {
                try keychain.saveAPIKey(trimmedKey)
            }.value
            apiKeyDraft = trimmedKey
            hasStoredAPIKey = true
        } catch {
            issue = SettingsIssue(title: "API key not saved", error: error)
        }
    }

    func removeAPIKey() async {
        isSavingAPIKey = true
        defer { isSavingAPIKey = false }
        do {
            let keychain = keychain
            try await Task.detached {
                try keychain.removeAPIKey()
            }.value
            apiKeyDraft = ""
            hasStoredAPIKey = false
        } catch {
            issue = SettingsIssue(title: "API key not removed", error: error)
        }
    }

    func openAIAPIKey() async throws -> String {
        let keychain = keychain
        let key = try await Task.detached {
            try keychain.apiKey()
        }.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key, !key.isEmpty else {
            throw SettingsPersistenceError.missingAPIKey
        }
        return key
    }

    func chooseResultDirectory() async {
        guard let url = await DirectoryPicker.choose(
            title: "Choose Result Folder",
            message: "Rufux will save call result JSON files in this folder."
        ) else { return }
        setDirectory(
            url,
            bookmarkKey: Keys.resultOutputBookmark,
            currentAccessWasStarted: &resultAccessWasStarted,
            assign: { resultOutputDirectory = $0 },
            errorTitle: "Result folder unavailable"
        )
    }

    func choosePCMDirectory() async {
        guard let url = await DirectoryPicker.choose(
            title: "Choose Recording Folder",
            message: "Rufux will save PCM input and output files in this folder."
        ) else { return }
        setDirectory(
            url,
            bookmarkKey: Keys.pcmOutputBookmark,
            currentAccessWasStarted: &pcmAccessWasStarted,
            assign: { pcmOutputDirectory = $0 },
            errorTitle: "Recording folder unavailable"
        )
    }

    func setPreferredHFPDeviceAddress(_ address: String?) {
        preferredHFPDeviceAddress = normalizedPreference(address)
        defaults.set(preferredHFPDeviceAddress, forKey: Keys.preferredHFPDeviceAddress)
    }

    func setPreferredAudioDeviceUID(_ uid: String?) {
        preferredAudioDeviceUID = normalizedPreference(uid)
        defaults.set(preferredAudioDeviceUID, forKey: Keys.preferredAudioDeviceUID)
    }

    func dismissIssue() {
        issue = nil
    }

    private func prepareDefaultDirectory(named name: String) -> URL? {
        do {
            let baseURL = try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let url = baseURL.appending(path: "Rufux", directoryHint: .isDirectory)
                .appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try validateDirectory(url)
            return url
        } catch {
            issue = SettingsIssue(title: "Default output folder unavailable", error: error)
            return nil
        }
    }

    private func restoreDirectory(
        bookmarkKey: String,
        accessWasStarted: inout Bool
    ) -> URL? {
        guard let data = defaults.data(forKey: bookmarkKey) else { return nil }
        do {
            var bookmarkIsStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &bookmarkIsStale
            )
            accessWasStarted = url.startAccessingSecurityScopedResource()
            try validateDirectory(url)
            if bookmarkIsStale {
                try saveBookmark(for: url, key: bookmarkKey)
            }
            return url
        } catch {
            defaults.removeObject(forKey: bookmarkKey)
            issue = SettingsIssue(title: "Saved folder access expired", error: error)
            return nil
        }
    }

    private func setDirectory(
        _ url: URL,
        bookmarkKey: String,
        currentAccessWasStarted: inout Bool,
        assign: (URL) -> Void,
        errorTitle: String
    ) {
        do {
            let newAccessWasStarted = url.startAccessingSecurityScopedResource()
            do {
                try validateDirectory(url)
                try saveBookmark(for: url, key: bookmarkKey)
            } catch {
                if newAccessWasStarted {
                    url.stopAccessingSecurityScopedResource()
                }
                throw error
            }

            if currentAccessWasStarted {
                if bookmarkKey == Keys.resultOutputBookmark {
                    resultOutputDirectory?.stopAccessingSecurityScopedResource()
                } else {
                    pcmOutputDirectory?.stopAccessingSecurityScopedResource()
                }
            }
            currentAccessWasStarted = newAccessWasStarted
            assign(url)
        } catch {
            issue = SettingsIssue(title: errorTitle, error: error)
        }
    }

    private func saveBookmark(for url: URL, key: String) throws {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: [.isDirectoryKey],
                relativeTo: nil
            )
            defaults.set(data, forKey: key)
        } catch {
            throw SettingsPersistenceError.bookmark(url, reason: error.localizedDescription)
        }
    }

    private func validateDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw SettingsPersistenceError.invalidDirectory(url, reason: "The folder no longer exists.")
        }
        guard isDirectory.boolValue else {
            throw SettingsPersistenceError.invalidDirectory(url, reason: "The selected item is not a folder.")
        }
        guard FileManager.default.isWritableFile(atPath: url.path) else {
            throw SettingsPersistenceError.invalidDirectory(url, reason: "Rufux does not have permission to write there.")
        }
    }

    private func normalizedPreference(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private enum Keys {
        static let isPCMOutputEnabled = "settings.pcmOutputEnabled"
        static let resultOutputBookmark = "settings.resultOutputBookmark"
        static let pcmOutputBookmark = "settings.pcmOutputBookmark"
        static let preferredHFPDeviceAddress = "settings.preferredHFPDeviceAddress"
        static let preferredAudioDeviceUID = "settings.preferredAudioDeviceUID"
    }
}
