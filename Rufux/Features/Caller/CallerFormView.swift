//
//  CallerFormView.swift
//  Rufux
//

import PhoneBTCore
import SwiftUI
import UniformTypeIdentifiers

struct CallerFormView: View {
    @Bindable var editor: CallerEditorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            CallerJSONImportCard(
                sourceFilename: editor.sourceFilename,
                importState: editor.importState,
                errorMessage: editor.importErrorMessage,
                validationIssues: editor.validationIssues,
                importFile: editor.importFile
            )

            CallerIdentitySection(
                name: $editor.name,
                dateOfBirth: $editor.dateOfBirth,
                insurance: $editor.insurance
            )

            CallerAppointmentSection(
                additionalDetails: $editor.additionalDetails,
                gender: $editor.gender,
                language: $editor.language,
                telephoneNumber: $editor.telephoneNumber
            )

            CallerReferralSection(
                rows: $editor.referralRows,
                addRow: editor.addReferralRow,
                removeRow: editor.removeReferralRow
            )
        }
    }
}

private struct CallerJSONImportCard: View {
    let sourceFilename: String?
    let importState: CallerImportState
    let errorMessage: String?
    let validationIssues: [CallerValidationIssue]
    let importFile: @MainActor (URL) -> Void

    @State private var isFileImporterPresented = false
    @State private var isDropTargeted = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: statusIcon)
                        .font(.title2)
                        .foregroundStyle(statusColor)
                        .frame(width: 32)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(statusTitle)
                            .font(.headline)

                        Text(statusDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if importState == .importing {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Button("Choose JSON…") {
                        isFileImporterPresented = true
                    }
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                } else if !validationIssues.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(validationIssues) { issue in
                            Label(issue.message, systemImage: "exclamationmark.circle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Caller JSON", systemImage: "doc.badge.plus")
                .fontWeight(.semibold)
        }
        .background(
            isDropTargeted ? Color.accentColor.opacity(0.10) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            importFile(url)
            return true
        } isTargeted: { isTargeted in
            isDropTargeted = isTargeted
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    importFile(url)
                }
            case .failure:
                break
            }
        }
        .help("Drop a caller JSON file here or choose one from Finder.")
    }

    private var statusIcon: String {
        switch importState {
        case .idle:
            return "arrow.down.doc"
        case .importing:
            return "arrow.triangle.2.circlepath"
        case .imported:
            return "checkmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch importState {
        case .idle, .importing:
            return .accentColor
        case .imported:
            return .green
        }
    }

    private var statusTitle: String {
        switch importState {
        case .idle:
            return "Drop caller JSON here"
        case .importing:
            return "Importing caller information…"
        case .imported:
            return sourceFilename ?? "Caller JSON imported"
        }
    }

    private var statusDetail: String {
        if let sourceFilename, importState != .imported {
            return "Current source: \(sourceFilename)"
        }
        return "The imported values remain editable below."
    }
}

private struct CallerIdentitySection: View {
    @Binding var name: String
    @Binding var dateOfBirth: String
    @Binding var insurance: String

    var body: some View {
        GroupBox("Caller") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                CallerTextFieldRow(label: "Name", prompt: "Full name", text: $name)
                CallerTextFieldRow(label: "Date of birth", prompt: "YYYY-MM-DD", text: $dateOfBirth)
                CallerTextFieldRow(label: "Insurance", prompt: "Provider and member number", text: $insurance)
            }
            .padding(6)
        }
    }
}

private struct CallerAppointmentSection: View {
    @Binding var additionalDetails: String
    @Binding var gender: VoiceGender?
    @Binding var language: String
    @Binding var telephoneNumber: String

    var body: some View {
        GroupBox("Call details") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                CallerTextFieldRow(
                    label: "Phone number",
                    prompt: "+49 123 456 7890",
                    text: $telephoneNumber
                )

                GridRow(alignment: .firstTextBaseline) {
                    Text("Voice")
                        .foregroundStyle(.secondary)

                    Picker("Voice", selection: $gender) {
                        Text("Automatic · Marin").tag(nil as VoiceGender?)
                        Text("Female · Marin").tag(VoiceGender.female as VoiceGender?)
                        Text("Male · Cedar").tag(VoiceGender.male as VoiceGender?)
                    }
                    .labelsHidden()
                }

                CallerTextFieldRow(label: "Language", prompt: "English", text: $language)

                GridRow(alignment: .top) {
                    Text("Appointment details")
                        .foregroundStyle(.secondary)
                        .padding(.top, 5)

                    TextField(
                        "Reason, preferences, and useful context",
                        text: $additionalDetails,
                        axis: .vertical
                    )
                    .lineLimit(3...7)
                    .textFieldStyle(.roundedBorder)
                }
            }
            .padding(6)
        }
    }
}

private struct CallerTextFieldRow: View {
    let label: LocalizedStringKey
    let prompt: LocalizedStringKey
    @Binding var text: String

    var body: some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)

            TextField(prompt, text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

private struct CallerReferralSection: View {
    @Binding var rows: [ReferralDraftRow]
    let addRow: @MainActor () -> Void
    let removeRow: @MainActor (ReferralDraftRow.ID) -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if rows.isEmpty {
                    Text("No referral details")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach($rows) { $row in
                        ReferralFieldRow(row: $row) {
                            removeRow(row.id)
                        }
                    }
                }

                Button(action: addRow) {
                    Label("Add referral field", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
            .padding(6)
        } label: {
            Label("Doctor referral", systemImage: "cross.case")
                .fontWeight(.semibold)
        }
    }
}

private struct ReferralFieldRow: View {
    @Binding var row: ReferralDraftRow
    let remove: @MainActor () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            TextField("Field name", text: $row.key)
                .frame(minWidth: 160)

            TextField("Value", text: $row.value)
                .frame(minWidth: 260)

            Button(role: .destructive, action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove referral field")
        }
        .textFieldStyle(.roundedBorder)
    }
}

#Preview("Caller Form") {
    ScrollView {
        CallerFormView(editor: CallerEditorStore())
            .frame(maxWidth: 760)
            .padding(24)
    }
    .frame(width: 820, height: 820)
}
