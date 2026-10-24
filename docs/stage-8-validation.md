# Stage 8 Validation

This checklist separates automated coverage from checks that require the actual phone, audio interface, network, macOS privacy database, and user-selected folders.

## Automated validation

- Rufux builds successfully for testing in Xcode.
- The Rufux unit/integration suite contains 23 tests and passes in Xcode.
- Coordinator tests use fake HFP, audio, and agent services to cover:
  - Successful call activation, result delivery, PCM URLs, and one-time cleanup.
  - PCM-disabled output configuration.
  - Audio startup failure and routing restoration.
  - A stalled agent close event and the bounded cleanup fallback.
  - Graceful application shutdown, hangup, audio stop, and HFP disconnect.
- Caller tests cover JSON population, malformed input, trimmed conversion, duplicate referral fields, and telephone-number edge cases.
- Settings tests cover isolated `UserDefaults` persistence and the Keychain service contract without placing secrets in test logs.
- Reducer tests cover readiness, activity coalescing and bounds, privacy filtering, warnings, terminal failures, elapsed time, outcomes, results, and filenames.
- The `RufuxUITests` target contains four XCUIAutomation tests for JSON population, validation/readiness gating, Start/End states, result presentation, and settings persistence.

The UI tests build and are discovered by Xcode. On the validation machine, the runner timed out while enabling macOS Automation mode before any UI test executed. Enable Automation access for Xcode/Xcode Helper in System Settings and rerun the `RufuxUITests` scheme.

The PhoneBTCore scheme builds successfully in Xcode. Its Swift package test targets are not exposed by that scheme in the current workspace. A direct `swift test` attempt was also blocked by the local SwiftPM build service with `Unknown error parsing property list`; rerun those package tests after the local build-service issue is cleared.

## Platform configuration

Verified on the Rufux target:

- App Sandbox: enabled.
- Hardened Runtime: enabled.
- Bluetooth access: enabled.
- Audio input access: enabled.
- Outgoing network connections: enabled.
- User-selected files: read/write.
- Bluetooth usage description: present and names Rufux.
- Microphone usage description: present.
- API keys: stored through the Security framework, not `UserDefaults`.
- Output folders: security-scoped bookmarks are restored and stale bookmarks are refreshed.
- Normal app termination: waits for coordinator cleanup and audio-route restoration.

The app target currently requires macOS 27. The package remains macOS 13 compatible, but lowering the app target to macOS 13 requires replacing its macOS 14+ Observation-based UI state and related SwiftUI APIs. Treat that as a separate compatibility project rather than a Stage 8 hardening change.

## Hardware validation matrix

Complete these checks with Console filtered for Rufux and confirm that no API key, caller transcript, or conversation text appears.

- [ ] Successful booked appointment; displayed result matches the JSON file.
- [ ] Not-booked result; optional fields display correctly.
- [ ] Unanswered call returns to a terminal state without starting assistant audio.
- [ ] Manual hangup restores the previous audio route.
- [ ] Remote hangup restores the previous audio route.
- [ ] Phone disconnect while ringing cleans up once.
- [ ] Phone disconnect during an active call cleans up once.
- [ ] Audio-device removal during a call ends safely and restores routing.
- [ ] GPT-Live transport interruption reconnects without duplicate sessions.
- [ ] Structured-result recovery completes after remote hangup.
- [ ] Unwritable result directory produces an actionable terminal error.
- [ ] Unwritable PCM directory produces a visible nonfatal PCM warning.
- [ ] Relaunch restores the selected phone, audio device, result folder, and PCM folder.
- [ ] Keychain save, relaunch, read, and removal work for the signed app.
- [ ] Quit during ringing and during an active call hangs up and restores routing.
- [ ] Force-quit behavior is documented: the OS does not guarantee an application termination callback, so routing must also recover through device/system teardown.
