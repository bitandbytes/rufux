//
//  RufuxApp.swift
//  Rufux
//
//  Created by Hasini Suchetha Jayathilaka on 10.10.26.
//

import SwiftUI

@main
struct RufuxApp: App {
    @State private var settingsStore = SettingsStore.shared
    private let coordinator = CallCoordinator.live()

    var body: some Scene {
        WindowGroup {
            ContentView(coordinator: coordinator)
        }
        .environment(settingsStore)

        Settings {
            PersistentSettingsView(store: settingsStore)
        }
        .environment(settingsStore)
    }
}
