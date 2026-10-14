// swift-tools-version: 5.9

//
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

import PackageDescription

let package = Package(
    name: "PhoneBT",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PhoneBTCore", targets: ["PhoneBTCore"]),
        .executable(name: "PhoneBTConsole", targets: ["PhoneBTConsole"]),
    ],
    targets: [
        .target(
            name: "PhoneBTCore",
            exclude: [
                "Agent/CLAUDE.md",
                "Audio/CLAUDE.md",
                "HFP/CLAUDE.md",
                "Shared/CLAUDE.md",
            ],
            linkerSettings: [
                .linkedFramework("IOBluetooth"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
            ]
        ),
        .executableTarget(
            name: "PhoneBTConsole",
            dependencies: ["PhoneBTCore"],
            exclude: ["CLAUDE.md"]
        ),
        .testTarget(
            name: "HFPCoreTests",
            dependencies: ["PhoneBTCore"]
        ),
        .testTarget(
            name: "AgentBridgeTests",
            dependencies: ["PhoneBTCore"]
        ),
    ]
)
