// Copyright 2026 Ravindu Kumarasiri.
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

//
//  RufuxApp.swift
//  Rufux
//
//  Created by Ravindu Kumarasiri on 10.10.26.
//

import AVFoundation
import AppKit
import SwiftUI

@MainActor
final class RufuxAppDelegate: NSObject, NSApplicationDelegate {
    var shutdownHandler: (@MainActor () async -> Void)?
    private var isTerminationPending = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let shutdownHandler else { return .terminateNow }
        guard !isTerminationPending else { return .terminateLater }
        isTerminationPending = true

        Task {
            await shutdownHandler()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct RufuxApp: App {
    @NSApplicationDelegateAdaptor(RufuxAppDelegate.self) private var appDelegate
    @State private var settingsStore: SettingsStore
    private let liveCoordinator = CallCoordinator.live()
    private let previewCoordinator: PreviewCallCoordinator
    private let isUITesting: Bool

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let isUITesting = arguments.contains("--ui-testing")
        self.isUITesting = isUITesting
        previewCoordinator = PreviewCallCoordinator(emitsSampleResult: isUITesting)

#if DEBUG
        _settingsStore = State(initialValue: isUITesting
            ? SettingsStore.uiTesting(reset: arguments.contains("--ui-testing-reset"))
            : SettingsStore.shared)
#else
        _settingsStore = State(initialValue: SettingsStore.shared)
#endif

        if isUITesting {
            appDelegate.shutdownHandler = { [previewCoordinator] in
                await previewCoordinator.shutdown()
            }
        } else {
            appDelegate.shutdownHandler = { [liveCoordinator] in
                await liveCoordinator.shutdown()
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if isUITesting {
                    ContentView(coordinator: previewCoordinator)
                } else {
                    ContentView(coordinator: liveCoordinator)
                }
            }
                .task {
                    if !isUITesting {
                        await requestMicrophoneAccessIfNeeded()
                    }
                }
        }
        .environment(settingsStore)

        Settings {
            PersistentSettingsView(store: settingsStore)
        }
        .environment(settingsStore)
    }

    private func requestMicrophoneAccessIfNeeded() async {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
    }
}
