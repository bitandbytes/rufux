//
//  PersistentSettingsView.swift
//  Rufux
//

import AppKit
import SwiftUI

struct PersistentSettingsView: View {
    @Bindable var store: SettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsTitleSection()

                if let issue = store.issue {
                    SettingsIssueBanner(issue: issue) {
                        store.dismissIssue()
                    }
                }

                APIKeySettingsSection(
                    apiKey: $store.apiKeyDraft,
                    isStored: store.hasStoredAPIKey,
                    isSaving: store.isSavingAPIKey,
                    save: {
                        Task { await store.saveAPIKey() }
                    },
                    remove: {
                        Task { await store.removeAPIKey() }
                    }
                )

                OutputSettingsSection(
                    isPCMOutputEnabled: $store.isPCMOutputEnabled,
                    resultDirectory: store.resultOutputDirectory,
                    pcmDirectory: store.pcmOutputDirectory,
                    chooseResultDirectory: {
                        Task { await store.chooseResultDirectory() }
                    },
                    choosePCMDirectory: {
                        Task { await store.choosePCMDirectory() }
                    }
                )

                RememberedDeviceSettingsSection(
                    hfpAddress: store.preferredHFPDeviceAddress,
                    audioUID: store.preferredAudioDeviceUID,
                    forgetHFP: { store.setPreferredHFPDeviceAddress(nil) },
                    forgetAudio: { store.setPreferredAudioDeviceUID(nil) }
                )
            }
            .frame(maxWidth: 720)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color.primary.opacity(0.025))
        .frame(width: 760, height: 640)
        .task {
            await store.load()
        }
    }
}

private struct SettingsTitleSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Settings")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Configure API access and where call artifacts are saved.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct SettingsIssueBanner: View {
    let issue: SettingsIssue
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 4) {
                Text(issue.title)
                    .fontWeight(.semibold)
                Text(issue.message)
                if let recoverySuggestion = issue.recoverySuggestion {
                    Text(recoverySuggestion)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)

            Spacer()

            Button("Dismiss", action: dismiss)
                .buttonStyle(.borderless)
        }
        .padding(14)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

private struct APIKeySettingsSection: View {
    @Binding var apiKey: String
    let isStored: Bool
    let isSaving: Bool
    let save: () -> Void
    let remove: () -> Void

    var body: some View {
        GroupBox("OpenAI") {
            VStack(alignment: .leading, spacing: 12) {
                SecureField("OpenAI API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .privacySensitive()

                HStack {
                    Label(
                        isStored ? "Stored securely in Keychain" : "No API key saved",
                        systemImage: isStored ? "checkmark.shield.fill" : "key"
                    )
                    .font(.caption)
                    .foregroundStyle(isStored ? .green : .secondary)

                    Spacer()

                    if isStored {
                        Button("Remove", role: .destructive, action: remove)
                    }
                    Button("Save API Key", action: save)
                        .buttonStyle(.borderedProminent)
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }

                Text("The key is kept in your macOS Keychain and is never written to call logs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(4)
        }
    }
}

private struct OutputSettingsSection: View {
    @Binding var isPCMOutputEnabled: Bool
    let resultDirectory: URL?
    let pcmDirectory: URL?
    let chooseResultDirectory: () -> Void
    let choosePCMDirectory: () -> Void

    var body: some View {
        GroupBox("Call output") {
            VStack(alignment: .leading, spacing: 14) {
                DirectorySettingRow(
                    title: "Result JSON folder",
                    systemImage: "doc.text",
                    directory: resultDirectory,
                    isEnabled: true,
                    choose: chooseResultDirectory
                )

                Divider()

                Toggle("Save PCM audio", isOn: $isPCMOutputEnabled)

                DirectorySettingRow(
                    title: "PCM recording folder",
                    systemImage: "waveform",
                    directory: pcmDirectory,
                    isEnabled: isPCMOutputEnabled,
                    choose: choosePCMDirectory
                )
            }
            .padding(4)
        }
    }
}

private struct DirectorySettingRow: View {
    let title: LocalizedStringResource
    let systemImage: String
    let directory: URL?
    let isEnabled: Bool
    let choose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .fontWeight(.medium)
                Text(directory?.path(percentEncoded: false) ?? "No folder selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 12)

            Button("Choose…", action: choose)
                .disabled(!isEnabled)
        }
        .opacity(isEnabled ? 1 : 0.55)
    }
}

private struct RememberedDeviceSettingsSection: View {
    let hfpAddress: String?
    let audioUID: String?
    let forgetHFP: () -> Void
    let forgetAudio: () -> Void

    var body: some View {
        GroupBox("Remembered devices") {
            VStack(spacing: 12) {
                RememberedDeviceRow(
                    title: "HFP phone",
                    identifier: hfpAddress,
                    forget: forgetHFP
                )
                Divider()
                RememberedDeviceRow(
                    title: "Audio interface",
                    identifier: audioUID,
                    forget: forgetAudio
                )
            }
            .padding(4)
        }
    }
}

private struct RememberedDeviceRow: View {
    let title: LocalizedStringResource
    let identifier: String?
    let forget: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .fontWeight(.medium)
                Text(identifier ?? "No preferred device")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            if identifier != nil {
                Button("Forget", action: forget)
            }
        }
    }
}

@MainActor
enum DirectoryPicker {
    static func choose(title: String, message: String) async -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        return await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }
}
