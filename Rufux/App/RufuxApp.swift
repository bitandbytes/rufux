//
//  RufuxApp.swift
//  Rufux
//
//  Created by Hasini Suchetha Jayathilaka on 10.10.26.
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
