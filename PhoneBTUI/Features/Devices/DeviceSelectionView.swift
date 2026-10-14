//
//  DeviceSelectionView.swift
//  Rufux
//

import Observation
import SwiftUI

@MainActor
@Observable
final class DeviceSelectionModel {
    private(set) var state = DeviceManagementState.empty
    private(set) var operationError: String?

    @ObservationIgnored private let manager: any DeviceManaging
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false

    init(manager: any DeviceManaging) {
        self.manager = manager
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        let events = manager.makeDeviceEventStream()
        eventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                self?.consume(event)
            }
        }

        startupTask = Task { [weak self] in
            guard let self else { return }
            state = await manager.deviceState()
            await manager.refreshDevices()
            state = await manager.deviceState()
        }
    }

    func restorePreferences(hfpAddress: String?, audioUID: String?) {
        start()
        let startupTask = startupTask

        Task { [weak self, manager] in
            await startupTask?.value
            guard let self else { return }

            if let audioUID {
                do {
                    try await manager.selectAudioDevice(uid: audioUID)
                } catch {
                    operationError = error.localizedDescription
                }
            }

            if let hfpAddress,
               state.hfpDevices.contains(where: { $0.address == hfpAddress }) {
                do {
                    try await manager.connectHFPDevice(address: hfpAddress)
                } catch {
                    operationError = error.localizedDescription
                }
            }
        }
    }

    func refresh() {
        operationError = nil
        Task { [weak self] in
            guard let self else { return }
            await manager.refreshDevices()
        }
    }

    func connect(address: String) {
        perform {
            try await $0.connectHFPDevice(address: address)
        }
    }

    func disconnect() {
        perform {
            try await $0.disconnectHFPDevice()
        }
    }

    func selectAudioDevice(uid: String?) {
        perform {
            try await $0.selectAudioDevice(uid: uid)
        }
    }

    func dismissError() {
        operationError = nil
    }

    deinit {
        eventTask?.cancel()
        startupTask?.cancel()
    }

    private func perform(
        _ operation: @escaping @Sendable (any DeviceManaging) async throws -> Void
    ) {
        operationError = nil
        Task { [weak self, manager] in
            do {
                try await operation(manager)
            } catch {
                self?.operationError = error.localizedDescription
            }
        }
    }

    private func consume(_ event: DeviceManagementEvent) {
        switch event {
        case .stateChanged(let state):
            self.state = state
            if state.lastError == nil {
                operationError = nil
            }
        case .operationFailed(_, let message):
            operationError = message
        case .hfpConnectionChanged, .audioDeviceUnavailable:
            break
        }
    }
}

struct DeviceSelectionView: View {
    let model: DeviceSelectionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DeviceSelectionHeader(
                isRefreshing: model.state.isRefreshing,
                canRefresh: !model.state.hfpConnection.isConnecting,
                onRefresh: model.refresh
            )
            HFPDeviceSection(
                devices: model.state.hfpDevices,
                connection: model.state.hfpConnection,
                canChangeDevices: model.state.canChangeDevices,
                onConnect: model.connect,
                onDisconnect: model.disconnect
            )
            AudioDeviceSection(
                devices: model.state.audioDevices,
                selection: model.state.audioSelection,
                canChangeDevices: model.state.canChangeDevices,
                onSelect: model.selectAudioDevice
            )
            DeviceReadinessFooter(
                issues: model.state.readinessIssues,
                isCallInProgress: model.state.callPhase.isCallInProgress
            )
            if let message = model.operationError ?? model.state.lastError {
                DeviceManagementErrorView(
                    message: message,
                    onDismiss: model.dismissError
                )
            }
        }
        .task {
            model.start()
        }
    }
}

private struct DeviceSelectionHeader: View {
    let isRefreshing: Bool
    let canRefresh: Bool
    let onRefresh: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Call Devices")
                    .font(.headline)
                Text("Choose the phone and full-duplex audio interface used for calls.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onRefresh) {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .disabled(!canRefresh || isRefreshing)
        }
    }
}

private struct HFPDeviceSection: View {
    let devices: [HFPDeviceOption]
    let connection: HFPConnectionStatus
    let canChangeDevices: Bool
    let onConnect: (String) -> Void
    let onDisconnect: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                if devices.isEmpty {
                    DeviceEmptyState(
                        systemImage: "iphone.slash",
                        title: "No paired HFP phones",
                        detail: "Pair a phone in System Settings, then refresh this list."
                    )
                } else {
                    ForEach(devices) { device in
                        HFPDeviceRow(
                            name: device.name,
                            address: device.address,
                            connection: connection,
                            canChangeDevices: canChangeDevices,
                            onConnect: { onConnect(device.address) },
                            onDisconnect: onDisconnect
                        )
                        if device.id != devices.last?.id {
                            Divider()
                        }
                    }
                }
            }
        } label: {
            Label("HFP Phone", systemImage: "iphone.radiowaves.left.and.right")
        }
    }
}

private struct HFPDeviceRow: View {
    let name: String
    let address: String
    let connection: HFPConnectionStatus
    let canChangeDevices: Bool
    let onConnect: () -> Void
    let onDisconnect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isConnected ? "iphone.circle.fill" : "iphone.circle")
                .font(.title2)
                .foregroundStyle(isConnected ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(displayAddress)
                    .font(.caption)
                    .monospaced()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            if isConnecting {
                ProgressView()
                    .controlSize(.small)
                Text("Connecting…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isConnected {
                Button("Disconnect", role: .destructive, action: onDisconnect)
                    .disabled(!canChangeDevices)
            } else {
                Button("Connect", action: onConnect)
                    .disabled(!canChangeDevices)
            }
        }
        .padding(.vertical, 10)
    }

    private var isConnected: Bool {
        connection.connectedAddress == address
    }

    private var displayAddress: String {
        address
            .replacingOccurrences(of: "-", with: ":")
            .uppercased()
    }

    private var isConnecting: Bool {
        guard case .connecting(let connectingAddress) = connection else { return false }
        return connectingAddress == address
    }
}

private struct AudioDeviceSection: View {
    let devices: [AudioDeviceOption]
    let selection: AudioSelectionStatus
    let canChangeDevices: Bool
    let onSelect: (String?) -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                if case .unavailable = selection {
                    Label(
                        "The selected audio interface is unavailable. Choose another interface or refresh.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.vertical, 8)
                }

                if devices.isEmpty {
                    DeviceEmptyState(
                        systemImage: "speaker.slash",
                        title: "No full-duplex audio interfaces",
                        detail: "Connect an interface that provides both audio input and output."
                    )
                } else {
                    ForEach(devices) { device in
                        AudioDeviceRow(
                            name: device.name,
                            isSelected: selection.selectedUID == device.uid,
                            canChangeDevices: canChangeDevices,
                            onSelect: { onSelect(device.uid) }
                        )
                        if device.id != devices.last?.id {
                            Divider()
                        }
                    }
                }
            }
        } label: {
            Label("Audio Interface", systemImage: "waveform")
        }
    }
}

private struct AudioDeviceRow: View {
    let name: String
    let isSelected: Bool
    let canChangeDevices: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.wave.2.circle")
                .font(.title2)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text("Input and output available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isSelected {
                Label("Selected", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Button("Select", action: onSelect)
                    .disabled(!canChangeDevices)
            }
        }
        .padding(.vertical, 10)
    }
}

private struct DeviceReadinessFooter: View {
    let issues: [DeviceReadinessIssue]
    let isCallInProgress: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if issues.isEmpty {
                Label("Call devices are ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("Device setup is incomplete", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                ForEach(issues, id: \.self) { issue in
                    Text(issueDescription(issue))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if isCallInProgress {
                Text("Device selection is locked until the current call finishes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func issueDescription(_ issue: DeviceReadinessIssue) -> LocalizedStringResource {
        switch issue {
        case .hfpPhoneNotConnected:
            return "Connect an HFP phone."
        case .audioDeviceNotSelected:
            return "Select a full-duplex audio interface."
        case .audioDeviceUnavailable:
            return "Select an available full-duplex audio interface."
        }
    }
}

private struct DeviceEmptyState: View {
    let systemImage: String
    let title: LocalizedStringResource
    let detail: LocalizedStringResource

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 12)
    }
}

private struct DeviceManagementErrorView: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
            Spacer()
            Button("Dismiss", action: onDismiss)
                .buttonStyle(.link)
        }
        .padding(10)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
