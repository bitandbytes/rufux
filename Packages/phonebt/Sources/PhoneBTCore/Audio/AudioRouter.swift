// Copyright 2026 ICOA Inc.
// Modifications Copyright 2026 Ravindu Kumarasiri.
// Modified from the original PhoneBT project by Ravindu Kumarasiri in 2026.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation
import CoreAudio

/// Routes system audio to the user-selected call audio device.
public final class AudioRouter: @unchecked Sendable {
    private let deviceManager: AudioDeviceManager
    private var preferredDeviceName: String?
    private var preferredDeviceUID: String?
    private let logger = PhoneBTLogger(category: .audio)
    private let lock = NSLock()

    private var previousOutputDevice: AudioDeviceID?
    private var previousInputDevice: AudioDeviceID?
    private var isRouted = false

    public init(
        deviceManager: AudioDeviceManager = AudioDeviceManager(),
        preferredDeviceName: String? = nil,
        preferredDeviceUID: String? = nil
    ) {
        self.deviceManager = deviceManager
        self.preferredDeviceName = preferredDeviceName
        self.preferredDeviceUID = preferredDeviceUID
    }

    /// Update the fallback preferred device name for call audio routing.
    public func setPreferredDeviceName(_ name: String?) {
        lock.lock()
        defer { lock.unlock() }
        preferredDeviceName = name
    }

    /// Update the preferred device using its stable CoreAudio UID.
    public func setPreferredDeviceUID(_ uid: String?) {
        lock.lock()
        defer { lock.unlock() }
        preferredDeviceUID = uid
    }

    /// The full-duplex device phone-call audio is resolved to, if currently present.
    public func callAudioDevice() -> AudioDeviceInfo? {
        lock.lock()
        let name = preferredDeviceName
        let uid = preferredDeviceUID
        lock.unlock()

        if let uid, !uid.isEmpty,
           let device = deviceManager.getAllDevices().first(where: { $0.uid == uid }),
           device.hasInput, device.hasOutput {
            return device
        }

        return deviceManager.findCallAudioDevice(preferredName: name)
    }

    /// All audio devices currently visible to CoreAudio.
    public func allDevices() -> [AudioDeviceInfo] {
        return deviceManager.getAllDevices()
    }

    /// Route system default input/output to the call audio device.
    public func routeToCallAudioDevice() -> Bool {
        guard let device = callAudioDevice() else {
            lock.lock()
            let name = preferredDeviceName
            let uid = preferredDeviceUID
            lock.unlock()
            logger.error(
                "No call audio device found for routing " +
                "(preferred UID: \(uid ?? "none"), name: \(name ?? "none"))"
            )
            return false
        }

        // Save current defaults for restoration only once per routing session.
        if !isRouted {
            previousOutputDevice = deviceManager.getDefaultOutputDevice()
            previousInputDevice = deviceManager.getDefaultInputDevice()
        }

        logger.info(
            "Routing audio to device: \(device.name) " +
            "[\(device.id), \(device.transportTypeDescription)]"
        )
        let outOK = deviceManager.setDefaultOutputDevice(device.id)
        let inOK = deviceManager.setDefaultInputDevice(device.id)
        isRouted = outOK && inOK

        if isRouted {
            logger.info("Audio routed to \(device.name) successfully")
        } else {
            logger.error("Failed to route audio to \(device.name)")
        }
        return isRouted
    }

    /// Restore previous audio routing when a call ends.
    public func restorePreviousRouting() {
        guard isRouted else { return }

        if let previousOutputDevice {
            logger.info("Restoring previous output device: \(previousOutputDevice)")
            _ = deviceManager.setDefaultOutputDevice(previousOutputDevice)
        }
        if let previousInputDevice {
            logger.info("Restoring previous input device: \(previousInputDevice)")
            _ = deviceManager.setDefaultInputDevice(previousInputDevice)
        }

        previousOutputDevice = nil
        previousInputDevice = nil
        isRouted = false
        logger.info("Audio routing restored")
    }

    /// List all audio devices for diagnostics.
    public func listAudioDevices() -> [AudioDeviceInfo] {
        let devices = deviceManager.getAllDevices()
        for device in devices {
            logger.info(
                "Audio: \(device.name) [id=\(device.id), " +
                "transport=\(device.transportTypeDescription), " +
                "in=\(device.hasInput), out=\(device.hasOutput)]"
            )
        }
        return devices
    }

    /// List available Bluetooth audio devices for diagnostics.
    public func listBluetoothDevices() -> [AudioDeviceInfo] {
        return listAudioDevices().filter { $0.isBluetooth }
    }
}
