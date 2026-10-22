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

    func disconnectAudioDevice() {
        selectAudioDevice(uid: nil)
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
                onSelect: model.selectAudioDevice,
                onDisconnect: model.disconnectAudioDevice
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
                    HFPDeviceRow(
                        devices: devices,
                        connection: connection,
                        canChangeDevices: canChangeDevices,
                        onConnect: onConnect,
                        onDisconnect: onDisconnect
                    )
                }
            }
        } label: {
            Label("HFP Phone", systemImage: "iphone.radiowaves.left.and.right")
        }
    }
}

private struct HFPDeviceRow: View {
    let devices: [HFPDeviceOption]
    let connection: HFPConnectionStatus
    let canChangeDevices: Bool
    let onConnect: (String) -> Void
    let onDisconnect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isConnected ? "iphone.circle.fill" : "iphone.circle")
                .font(.title2)
                .foregroundStyle(isConnected ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                if let displayedDevice {
                    Text(displayedDevice.name)
                    Text(displayAddress(displayedDevice.address))
                        .font(.caption)
                        .monospaced()
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    Text("Choose a phone")
                    Text("No HFP phone connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isConnecting {
                ProgressView()
                    .controlSize(.small)
                Text("Connecting…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if devices.count > 1 {
                Menu {
                    ForEach(devices) { device in
                        Button {
                            onConnect(device.address)
                        } label: {
                            if connection.connectedAddress == device.address {
                                Label {
                                    Text(device.name)
                                } icon: {
                                    Image(systemName: "checkmark")
                                }
                            } else {
                                Text(device.name)
                            }
                        }
                    }
                } label: {
                    Label("Choose", systemImage: "chevron.down")
                }
                .disabled(!canChangeDevices)
            } else if let device = devices.first, !isConnected, !isConnecting {
                Button("Connect") {
                    onConnect(device.address)
                }
                .disabled(!canChangeDevices)
            }
            if isConnected {
                Button("Disconnect", role: .destructive, action: onDisconnect)
                    .disabled(!canChangeDevices)
            }
        }
        .padding(.vertical, 10)
    }

    private var isConnected: Bool {
        connection.connectedAddress != nil
    }

    private var activeDevice: HFPDeviceOption? {
        guard let address = connection.activeAddress else { return nil }
        return devices.first { $0.address == address }
    }

    private var displayedDevice: HFPDeviceOption? {
        activeDevice ?? (devices.count == 1 ? devices.first : nil)
    }

    private func displayAddress(_ address: String) -> String {
        address
            .replacingOccurrences(of: "-", with: ":")
            .uppercased()
    }

    private var isConnecting: Bool {
        connection.isConnecting
    }
}

private struct AudioDeviceSection: View {
    let devices: [AudioDeviceOption]
    let selection: AudioSelectionStatus
    let canChangeDevices: Bool
    let onSelect: (String?) -> Void
    let onDisconnect: () -> Void

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
                    AudioDeviceRow(
                        devices: devices,
                        selectedUID: selection.selectedUID,
                        canChangeDevices: canChangeDevices,
                        onSelect: onSelect,
                        onDisconnect: onDisconnect
                    )
                }
            }
        } label: {
            Label("Audio Interface", systemImage: "waveform")
        }
    }
}

private struct AudioDeviceRow: View {
    let devices: [AudioDeviceOption]
    let selectedUID: String?
    let canChangeDevices: Bool
    let onSelect: (String?) -> Void
    let onDisconnect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.wave.2.circle")
                .font(.title2)
                .foregroundStyle(selectedDevice == nil ? Color.secondary : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                if let displayedDevice {
                    Text(displayedDevice.name)
                    Text(selectedDevice == nil ? "Available for input and output" : "Input and output available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Choose an audio interface")
                    Text("Input and output are required")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if devices.count > 1 {
                Menu {
                    ForEach(devices) { device in
                        Button {
                            onSelect(device.uid)
                        } label: {
                            if selectedUID == device.uid {
                                Label {
                                    Text(device.name)
                                } icon: {
                                    Image(systemName: "checkmark")
                                }
                            } else {
                                Text(device.name)
                            }
                        }
                    }
                } label: {
                    Label("Choose", systemImage: "chevron.down")
                }
                .disabled(!canChangeDevices)
            } else if let device = devices.first, selectedDevice == nil {
                Button("Select") {
                    onSelect(device.uid)
                }
                .disabled(!canChangeDevices)
            }
            if selectedDevice != nil {
                Button("Disconnect", role: .destructive, action: onDisconnect)
                    .disabled(!canChangeDevices)
            }
        }
        .padding(.vertical, 10)
    }

    private var selectedDevice: AudioDeviceOption? {
        guard let selectedUID else { return nil }
        return devices.first { $0.uid == selectedUID }
    }

    private var displayedDevice: AudioDeviceOption? {
        selectedDevice ?? (devices.count == 1 ? devices.first : nil)
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
