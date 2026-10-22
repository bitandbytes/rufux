//
//  RufuxApp.swift
//  Rufux
//
//  Created by Hasini Suchetha Jayathilaka on 10.10.26.
//

import AVFoundation
import SwiftUI

@main
struct RufuxApp: App {
    @State private var settingsStore = SettingsStore.shared
    private let coordinator = CallCoordinator.live()

    var body: some Scene {
        WindowGroup {
            ContentView(coordinator: coordinator)
                .task {
                    await requestMicrophoneAccessIfNeeded()
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
