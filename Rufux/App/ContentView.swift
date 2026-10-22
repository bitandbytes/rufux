//
//  ContentView.swift
//  Rufux
//
//  Created by Hasini Suchetha Jayathilaka on 10.10.26.
//

import AppKit
import PhoneBTCore
import SwiftUI

struct ContentView: View {
    @Environment(SettingsStore.self) private var settingsStore
    @State private var store: AppStore
    @State private var callerEditor: CallerEditorStore
    @State private var deviceModel: DeviceSelectionModel

    init<Coordinator>(coordinator: Coordinator) where Coordinator: CallCoordinating & DeviceManaging {
        _store = State(initialValue: AppStore(coordinator: coordinator))
        _callerEditor = State(initialValue: CallerEditorStore())
        _deviceModel = State(initialValue: DeviceSelectionModel(manager: coordinator))
    }

    var body: some View {
        CallWorkspaceView(
            store: store,
            callerEditor: callerEditor,
            deviceModel: deviceModel,
            settingsStore: settingsStore
        )
            .frame(minWidth: 1_100, minHeight: 720)
            .task {
                store.start()
                await settingsStore.load()
                deviceModel.restorePreferences(
                    hfpAddress: settingsStore.appSettings.preferredHFPDeviceAddress,
                    audioUID: settingsStore.appSettings.preferredAudioDeviceUID
                )
            }
            .onChange(of: callerEditor.callerDraft, initial: true) { _, caller in
                store.send(.setCaller(caller))
            }
            .onChange(of: settingsStore.appSettings, initial: true) { _, settings in
                store.send(.setSettings(settings))
            }
            .onChange(of: deviceModel.state.hfpConnection.connectedAddress) { _, address in
                if let address {
                    settingsStore.setPreferredHFPDeviceAddress(address)
                }
            }
            .onChange(of: deviceModel.state.audioSelection.requestedUID) { _, uid in
                settingsStore.setPreferredAudioDeviceUID(uid)
            }
    }
}

private struct CallWorkspaceView: View {
    let store: AppStore
    @Bindable var callerEditor: CallerEditorStore
    let deviceModel: DeviceSelectionModel
    let settingsStore: SettingsStore
    @State private var destinationPhoneNumber = ""

    private var isReady: Bool {
        callerEditor.isValid &&
            PhoneNumberValidator.isValid(destinationPhoneNumber) &&
            deviceModel.state.isReady &&
            settingsStore.appSettings.hasAPIKey &&
            settingsStore.appSettings.hasValidOutputConfiguration &&
            !store.state.callPhase.isCallInProgress
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader(
                callPhase: store.state.callPhase,
                isReady: isReady,
                callStartedAt: store.state.callStartedAt,
                callEndedAt: store.state.callEndedAt
            )

        Divider()

            HSplitView {
                CallerEditorPane(editor: callerEditor)
                    .frame(minWidth: 600)

                CallOperationsPane(
                    store: store,
                    destinationPhoneNumber: $destinationPhoneNumber,
                    callerEditor: callerEditor,
                    deviceModel: deviceModel,
                    settingsStore: settingsStore,
                    canStartCall: isReady,
                    callPhase: store.state.callPhase
                )
                .frame(minWidth: 500)
            }
        }
        .background(Color.primary.opacity(0.025))
        .alert(
            "Call could not continue",
            isPresented: Binding(
                get: { store.state.errorMessage != nil },
                set: { isPresented in
                    if !isPresented { store.send(.dismissError) }
                }
            )
        ) {
            Button("OK") { store.send(.dismissError) }
        } message: {
            Text(store.state.errorMessage ?? "An unknown call error occurred.")
        }
    }
}

private struct WorkspaceHeader: View {
    let callPhase: CallPhase
    let isReady: Bool
    let callStartedAt: Date?
    let callEndedAt: Date?

    private var statusTitle: LocalizedStringResource {
        switch callPhase {
        case .validating: return "Validating call"
        case .dialing: return "Dialing"
        case .ringing: return "Ringing"
        case .active: return "Call in progress"
        case .ending: return "Ending call"
        case .finalizing: return "Finalizing result"
        case .completed: return "Call completed"
        case .failed: return "Call failed"
        case .idle: break
        }
        return isReady ? "Ready to call" : "Setup incomplete"
    }

    private var statusImage: String {
        if callPhase.isCallInProgress { return "waveform" }
        if callPhase == .completed { return "checkmark.circle.fill" }
        if callPhase == .failed { return "xmark.circle.fill" }
        return isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
    }

    private var statusColor: Color {
        if callPhase.isCallInProgress { return .orange }
        if callPhase == .completed { return .green }
        if callPhase == .failed { return .red }
        return isReady ? .green : .secondary
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Rufux Call Assistant")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Review the caller details and devices before starting the call.")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let callStartedAt {
                CallDurationView(startDate: callStartedAt, endDate: callEndedAt)
            }

            Label(statusTitle, systemImage: statusImage)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(statusColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(statusColor.opacity(0.1), in: Capsule())
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(.background)
    }
}

private struct CallerEditorPane: View {
    @Bindable var editor: CallerEditorStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeading(
                    title: "Caller details",
                    subtitle: "Import a JSON file or review the information used during the call."
                )

                CallerFormView(editor: editor)

                Label(
                    "Only provide information you are comfortable sharing during the call.",
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .background(.background)
    }
}

private struct CallerDetailsPane: View {
    @Binding var name: String
    @Binding var dateOfBirth: String
    @Binding var insurance: String
    @Binding var gender: String
    @Binding var language: String
    @Binding var additionalDetails: String
    @Binding var referralDetails: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeading(
                    title: "Caller details",
                    subtitle: "Information the call assistant may use when asked."
                )

                JSONImportCard()

                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        FormField(title: "Full name", text: $name)
                        FormField(title: "Date of birth", text: $dateOfBirth)
                        FormField(title: "Insurance", text: $insurance)

                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Voice")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Picker("Voice", selection: $gender) {
                                    Text("Female · Marin").tag("Female")
                                    Text("Male · Cedar").tag("Male")
                                }
                                .labelsHidden()
                                .frame(maxWidth: .infinity)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Call language")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Picker("Call language", selection: $language) {
                                    Text("English").tag("English")
                                    Text("German").tag("German")
                                    Text("French").tag("French")
                                }
                                .labelsHidden()
                                .frame(maxWidth: .infinity)
                            }
                        }

                        MultilineFormField(
                            title: "Appointment request",
                            text: $additionalDetails,
                            minimumHeight: 72
                        )

                        MultilineFormField(
                            title: "Referral details",
                            text: $referralDetails,
                            minimumHeight: 72
                        )
                    }
                    .padding(4)
                } label: {
                    Label("Personal and medical context", systemImage: "person.text.rectangle")
                        .fontWeight(.semibold)
                }

                Label(
                    "Only provide information you are comfortable sharing during the call.",
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .background(.background)
    }
}

private struct JSONImportCard: View {
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "doc.badge.arrow.up")
                    .font(.title2)
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Drop an input JSON here")
                        .fontWeight(.semibold)

                    Text("The matching fields will be filled automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Choose JSON…") { }
            }

            Divider()

            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)

                Text("appointment.json")
                    .font(.caption)
                    .fontWeight(.medium)

                Text("8 fields imported")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Remove") { }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
        }
    }
}

private struct FormField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField(title, text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

private struct MultilineFormField: View {
    let title: String
    @Binding var text: String
    let minimumHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(7)
                .frame(minHeight: minimumHeight)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25))
                }
        }
    }
}

private struct CallOperationsPane: View {
    let store: AppStore
    @Binding var destinationPhoneNumber: String
    let callerEditor: CallerEditorStore
    let deviceModel: DeviceSelectionModel
    let settingsStore: SettingsStore
    let canStartCall: Bool
    let callPhase: CallPhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DeviceSelectionView(model: deviceModel)
                CallControlCard(
                    phoneNumber: $destinationPhoneNumber,
                    canStartCall: canStartCall,
                    callPhase: callPhase,
                    onStart: startCall,
                    onEnd: endCall
                )
                ActivityLogCard(
                    entries: store.state.activityEntries,
                    callPhase: callPhase,
                    warningMessage: store.state.warningMessage,
                    onDismissWarning: { store.send(.dismissWarning) }
                )
                CallResultCard(result: store.state.latestResult)
            }
            .padding(20)
        }
    }

    private func startCall() {
        Task { @MainActor in
            do {
                let configuration = try callerEditor.inputConfiguration()
                let apiKey = try await settingsStore.openAIAPIKey()
                guard let resultOutputDirectory = settingsStore.resultOutputDirectory else {
                    throw SettingsPersistenceError.invalidDirectory(
                        URL(filePath: "Results"),
                        reason: "Choose a result folder in Settings."
                    )
                }
                let request = CallStartRequest(
                    apiKey: apiKey,
                    configuration: configuration,
                    phoneNumber: PhoneNumberValidator.normalized(destinationPhoneNumber),
                    resultOutputDirectory: resultOutputDirectory,
                    isPCMOutputEnabled: settingsStore.isPCMOutputEnabled,
                    pcmOutputDirectory: settingsStore.pcmOutputDirectory
                )
                await store.startCall(request)
            } catch {
                store.presentCallFailure(error)
            }
        }
    }

    private func endCall() {
        Task {
            await store.endCall()
        }
    }
}

private struct DeviceReadinessCard: View {
    @Binding var hfpDevice: String
    @Binding var audioDevice: String

    var body: some View {
        GroupBox {
            VStack(spacing: 14) {
                DevicePickerRow(
                    icon: "iphone.gen3",
                    title: "HFP phone",
                    status: "Connected",
                    selection: $hfpDevice,
                    options: ["iPhone 17", "iPhone SE"]
                )

                Divider()

                DevicePickerRow(
                    icon: "waveform.circle",
                    title: "Call audio interface",
                    status: "Input + output",
                    selection: $audioDevice,
                    options: ["USB Advanced Audio Device", "AUX Device"]
                )
            }
            .padding(4)
        } label: {
            HStack {
                Label("Device readiness", systemImage: "checkmark.circle")
                    .fontWeight(.semibold)

                Spacer()

                Text("2 of 2 ready")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
    }
}

private struct DevicePickerRow: View {
    let icon: String
    let title: String
    let status: String
    @Binding var selection: String
    let options: [String]

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Label(status, systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .symbolRenderingMode(.monochrome)
            }

            Spacer()

            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .labelsHidden()
            .frame(width: 245)
        }
    }
}

private struct CallControlCard: View {
    @Binding var phoneNumber: String
    let canStartCall: Bool
    let callPhase: CallPhase
    let onStart: () -> Void
    let onEnd: () -> Void

    private var canEndCall: Bool {
        switch callPhase {
        case .validating, .dialing, .ringing, .active:
            return true
        case .idle, .ending, .finalizing, .completed, .failed:
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Number to call")
                        .font(.headline)

                    Text("GPT-Live starts only after the call is answered.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if callPhase.isCallInProgress {
                    Label(callPhase.statusLabel, systemImage: "waveform")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.orange)
                }
            }

            HStack(spacing: 10) {
                TextField("+49 123 456 7890", text: $phoneNumber)
                    .textContentType(.telephoneNumber)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3.monospacedDigit())
                    .disabled(callPhase.isCallInProgress)

                Button(action: onStart) {
                    Label("Call", systemImage: "phone.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(!canStartCall)

                Button(role: .destructive, action: onEnd) {
                    Label("End", systemImage: "phone.down.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canEndCall)
            }
            .controlSize(.large)
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.2))
        }
    }
}

private extension CallPhase {
    var statusLabel: LocalizedStringResource {
        switch self {
        case .idle: "Idle"
        case .validating: "Validating"
        case .dialing: "Dialing"
        case .ringing: "Ringing"
        case .active: "Active"
        case .ending: "Ending"
        case .finalizing: "Finalizing"
        case .completed: "Completed"
        case .failed: "Failed"
        }
    }
}

private struct ActivityLogCard: View {
    let entries: [CallActivityEntry]
    let callPhase: CallPhase
    let warningMessage: String?
    let onDismissWarning: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let warningMessage {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)

                    Text(warningMessage)
                        .font(.subheadline)

                    Spacer()

                    Button(action: onDismissWarning) {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss warning")
                }
                .padding(12)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }

            GroupBox {
                ActivityLogContent(entries: entries)
            } label: {
                HStack {
                    Label("Call activity", systemImage: "text.alignleft")
                        .fontWeight(.semibold)

                    Spacer()

                    Text(callPhase.isCallInProgress ? "Live" : "Most recent")
                        .font(.caption)
                        .foregroundStyle(callPhase.isCallInProgress ? .orange : .secondary)
                }
            }

            Label("Conversation transcripts are not displayed or stored in this log.", systemImage: "lock")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
    }
}

private struct ActivityLogContent: View {
    private static let viewportHeight: CGFloat = 220

    let entries: [CallActivityEntry]

    var body: some View {
        Group {
            if entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.alignleft")
                        .font(.title2)
                        .foregroundStyle(.secondary)

                    Text("No call activity")
                        .font(.headline)

                    Text("Status updates will appear here without conversation transcripts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(entries) { entry in
                                VStack(spacing: 0) {
                                    ActivityLogRow(entry: entry)

                                    if entry.id != latestEntryID {
                                        Divider()
                                            .padding(.leading, 34)
                                    }
                                }
                                .id(entry.id)
                            }
                        }
                        .padding(4)
                    }
                    .onChange(of: latestEntryID, initial: true) { _, entryID in
                        guard let entryID else { return }
                        proxy.scrollTo(entryID, anchor: .bottom)
                    }
                }
            }
        }
        .frame(height: Self.viewportHeight)
    }

    private var latestEntryID: UUID? {
        entries.last?.id
    }
}

private struct ActivityLogRow: View {
    let entry: CallActivityEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: entry.kind.systemImage)
                .foregroundStyle(entry.kind.color)
                .frame(width: 24)

            Text(entry.message)
                .font(.subheadline)

            if entry.occurrenceCount > 1 {
                Text(verbatim: "×\(entry.occurrenceCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(entry.timestamp, format: .dateTime.hour().minute().second())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 9)
    }
}

private extension CallActivityKind {
    var systemImage: String {
        switch self {
        case .information: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failure: "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .information: .blue
        case .success: .green
        case .warning: .orange
        case .failure: .red
        }
    }
}

private struct CallDurationView: View {
    let startDate: Date
    let endDate: Date?

    var body: some View {
        Group {
            if let endDate {
                durationLabel(at: endDate)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    durationLabel(at: context.date)
                }
            }
        }
        .font(.headline.monospacedDigit())
        .foregroundStyle(.secondary)
        .accessibilityLabel("Elapsed call duration")
    }

    private func durationLabel(at date: Date) -> some View {
        Text(verbatim: formattedDuration(at: date))
    }

    private func formattedDuration(at date: Date) -> String {
        let totalSeconds = max(0, Int(date.timeIntervalSince(startDate)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct CallResultCard: View {
    let result: CallResult?

    var body: some View {
        GroupBox {
            if let result {
                CallResultContent(result: result)
                    .padding(4)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(.secondary)

                    Text("No call result yet")
                        .font(.headline)

                    Text("The structured appointment outcome will appear after a completed call.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 110)
                .padding(4)
            }
        } label: {
            Label("Call result", systemImage: "doc.text.magnifyingglass")
                .fontWeight(.semibold)
        }
    }
}

private struct CallResultContent: View {
    let result: CallResult

    private var outcome: AppointmentOutcome {
        result.outcome
    }

    private var appointmentDate: String? {
        nonempty(result.appointment.appointmentDate)
    }

    private var appointmentTime: String? {
        nonempty(result.appointment.appointmentTime)
    }

    private var practice: String? {
        nonempty(result.appointment.practice)
    }

    private var notes: String? {
        nonempty(result.appointment.notes)
    }

    private var hasDetails: Bool {
        appointmentDate != nil || appointmentTime != nil || practice != nil || notes != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(outcome.color.opacity(0.14))
                        .frame(width: 42, height: 42)

                    Image(systemName: outcome.systemImage)
                        .foregroundStyle(outcome.color)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(outcome.title)
                        .font(.headline)

                    Text("Latest completed call")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(outcome.badge)
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundStyle(outcome.color)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(outcome.color.opacity(0.1), in: Capsule())
            }

            Divider()

            if hasDetails {
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
                    if let appointmentDate {
                        ResultGridRow(label: "Date", value: appointmentDate)
                    }
                    if let appointmentTime {
                        ResultGridRow(label: "Time", value: appointmentTime)
                    }
                    if let practice {
                        ResultGridRow(label: "Practice", value: practice)
                    }
                    if let notes {
                        ResultGridRow(label: "Notes", value: notes)
                    }
                }
            } else {
                Text("No additional appointment details were provided.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Label(result.resultURL.lastPathComponent, systemImage: "doc.text")
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)

                if !result.pcmURLs.isEmpty {
                    Label("PCM audio files saved", systemImage: "waveform")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()

                Button {
                    revealInFinder([result.resultURL])
                } label: {
                    Label("Show result JSON", systemImage: "finder")
                }

                if !result.pcmURLs.isEmpty {
                    Button {
                        revealInFinder(result.pcmURLs)
                    } label: {
                        Label("Show PCM files", systemImage: "finder")
                    }
                }
            }
        }
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func revealInFinder(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

private extension AppointmentOutcome {
    var title: LocalizedStringResource {
        switch self {
        case .booked: "Appointment booked"
        case .notBooked: "Appointment not booked"
        case .unknown: "Appointment outcome unknown"
        }
    }

    var badge: LocalizedStringResource {
        switch self {
        case .booked: "BOOKED"
        case .notBooked: "NOT BOOKED"
        case .unknown: "UNKNOWN"
        }
    }

    var systemImage: String {
        switch self {
        case .booked: "calendar.badge.checkmark"
        case .notBooked: "xmark.circle.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .booked: .green
        case .notBooked: .orange
        case .unknown: .secondary
        }
    }
}

private struct ResultGridRow: View {
    let label: LocalizedStringResource
    let value: String

    var body: some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.subheadline)
                .gridColumnAlignment(.leading)
        }
    }
}

struct SettingsView: View {
    @State private var apiKey = "sk-proj-placeholder-key"
    @State private var savesPCMOutput = true
    @State private var pcmOutputPath = "~/Documents/Rufux/Recordings"
    @State private var jsonOutputPath = "~/Documents/Rufux/Results"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SectionHeading(
                    title: "Settings",
                    subtitle: "Configure API access and where call artifacts are saved."
                )

                SettingsAPIKeyCard(apiKey: $apiKey)
                SettingsPCMCard(isEnabled: $savesPCMOutput, outputPath: $pcmOutputPath)
                SettingsJSONCard(outputPath: $jsonOutputPath)
            }
            .frame(maxWidth: 760)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color.primary.opacity(0.025))
        .frame(width: 760, height: 600)
    }
}

private struct SettingsAPIKeyCard: View {
    @Binding var apiKey: String

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                SecureField("OpenAI API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                Label("Store the key in the macOS Keychain and never write it to call logs.", systemImage: "key.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
        } label: {
            Label("OpenAI API", systemImage: "sparkles")
                .fontWeight(.semibold)
        }
    }
}

private struct SettingsPCMCard: View {
    @Binding var isEnabled: Bool
    @Binding var outputPath: String

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Save PCM audio for each call", isOn: $isEnabled)
                    .fontWeight(.medium)

                Divider()

                PathField(
                    title: "PCM output folder",
                    text: $outputPath,
                    isEnabled: isEnabled
                )

                Label(
                    "Creates separate 24 kHz mono agent-input and agent-output PCM files. Call audio may contain sensitive information.",
                    systemImage: "exclamationmark.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(6)
        } label: {
            Label("PCM audio output", systemImage: "waveform.badge.plus")
                .fontWeight(.semibold)
        }
    }
}

private struct SettingsJSONCard: View {
    @Binding var outputPath: String

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                PathField(title: "Result JSON folder", text: $outputPath, isEnabled: true)

                Text("Each completed call writes a timestamped result with booking status, date, time, practice, and notes when available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
        } label: {
            Label("Result output", systemImage: "doc.badge.gearshape")
                .fontWeight(.semibold)
        }
    }
}

private struct PathField: View {
    let title: String
    @Binding var text: String
    let isEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField(title, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .disabled(!isEnabled)

                Button("Choose…") { }
                    .disabled(!isEnabled)
            }
        }
    }
}

private struct SectionHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2)
                .fontWeight(.semibold)

            Text(subtitle)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ContentView(coordinator: PreviewCallCoordinator())
        .environment(SettingsStore.shared)
}
