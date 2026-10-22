# PhoneBTUI Implementation Plan

## Purpose

This document describes the staged implementation of the PhoneBT macOS user interface. The existing SwiftUI screens are currently a presentation-only prototype. The completed application will import caller information, manage HFP and CoreAudio devices, place and end calls, bridge active calls to GPT-Live, display privacy-conscious activity updates, save optional PCM audio, and present structured appointment results.

The implementation should preserve the package's macOS 13 minimum deployment target and use Swift concurrency and `AsyncStream` rather than Combine.

## Proposed Architecture

```text
SwiftUI views
    ↕ actions and view state
App state/reducer (@MainActor)
    ↕ typed async events
Call coordinator
    ├── Bluetooth/HFP adapter
    ├── Audio adapter
    ├── AgentSession adapter
    └── Settings/output services
            ↓
        PhoneBTCore
```

The call coordinator is the single owner of the active HFP device, audio session, agent session, event tasks, and cleanup sequence. SwiftUI views receive narrow state values and bindings rather than directly owning hardware resources.

## Stage 1 — Foundation and Core API Contracts

**Status:** Implemented and validated.

### Goals

- Establish the application state model and dependency boundaries.
- Expose typed data and events required by the UI.
- Make hardware-dependent behavior replaceable with test doubles.

### Work

- Define application models:
  - `CallerDraft`
  - `DeviceSelection`
  - `CallPhase`
  - `CallActivityEntry`
  - `CallReadiness`
  - `CallResult`
  - `AppSettings`
- Add a main-actor app state/reducer that owns the state rendered by SwiftUI.
- Use async event streams between the call coordinator and application state.
- Define app-level protocols around HFP, audio, and agent functionality so unit tests can use fake implementations.
- Extend `PhoneBTCore` with:
  - A public `AppointmentResult` model.
  - Typed `AgentSessionEvent` values instead of requiring the UI to parse diagnostic strings.
  - Configurable result and PCM output locations.
  - A PCM-output enabled flag.
  - Exact audio-device selection by stable CoreAudio UID rather than partial name matching.
- Preserve the existing console client or migrate it to the new core initializers.

### Exit Criteria

- The UI builds against a mock coordinator.
- `PhoneBTCore` and the console client build successfully.
- Existing package tests continue to pass.

### Delivered

- Added the application models, main-actor store/reducer, coordinator event stream, and injected HFP, audio, and agent service boundaries.
- Added live service adapters plus a preview coordinator so the SwiftUI app can start without accessing hardware.
- Exposed public appointment results and typed agent-session activity, result, retry, failure, and closure events from `PhoneBTCore`.
- Added configurable result/PCM output behavior and exact CoreAudio device selection by UID while preserving the console initializer's existing defaults.
- Added contract tests for public result round-tripping, typed events, optional PCM output, and a separate PCM directory.

## Stage 2 — Settings and Secure Persistence

**Status:** Implemented and validated.

### Goals

- Make the dedicated macOS Settings window functional.
- Persist preferences safely across launches.

### Work

- Store the OpenAI API key in macOS Keychain.
- Store non-sensitive preferences in `UserDefaults`:
  - PCM output enabled state.
  - Preferred HFP device address.
  - Preferred audio-device UID.
- Select result and PCM directories with `NSOpenPanel`.
- Store security-scoped bookmarks if the app is sandboxed so selected directories remain accessible after relaunch.
- Provide sensible default result and PCM directories.
- Validate that selected directories exist and are writable.
- Display actionable errors for invalid paths or Keychain failures.
- Ensure the API key is never written to application or call logs.

### Exit Criteria

- Settings survive application relaunch.
- The API key round-trips through Keychain.
- Output-folder permissions are restored after relaunch.
- Invalid folders produce clear UI feedback.

### Delivered

- Added a dedicated macOS Settings scene backed by an observable settings store.
- Stored the OpenAI API key in Keychain and kept non-sensitive preferences in `UserDefaults`.
- Added result and PCM directory pickers, writable-directory validation, default output folders, and security-scoped bookmark restoration.
- Persisted the PCM toggle and preferred HFP/audio identifiers, and surfaced actionable inline persistence errors.

## Stage 3 — JSON Import and Caller Form

**Status:** Implemented and validated.

### Goals

- Replace the prototype caller values with imported and editable configuration data.

### Work

- Support importing JSON through:
  - Drag and drop onto the import card.
  - A standard file importer.
- Decode imported files through `InputConfiguration`.
- Populate:
  - Name.
  - Date of birth.
  - Insurance.
  - Additional appointment details.
  - Gender and voice selection.
  - Call language.
  - Telephone number.
  - Referral key-value pairs.
- Replace the prototype referral text area with editable key-value rows so the original JSON structure is preserved.
- Display decoding and validation errors beside the import card.
- Validate required fields and telephone number before enabling Start Call.
- Keep the imported `telephoneNumber` and the main phone-number control synchronized.
- Preserve the source filename and URL for display and output naming.
- Convert the edited form back into a valid `InputConfiguration` when starting a call.

### Exit Criteria

- Valid fixture files populate every matching form field.
- Malformed and incomplete files show actionable validation messages.
- User edits produce a valid `InputConfiguration`.

### Delivered

- Added JSON drag-and-drop and file-import flows that decode `InputConfiguration` and preserve the source URL and filename.
- Replaced sample caller state with an observable editor covering identity, appointment, voice, language, telephone, and stable referral key-value rows.
- Added required-field and phone validation with inline import/validation feedback.
- Bound the caller form and main call control to the same telephone-number source and exposed validated `InputConfiguration` generation.

## Stage 4 — HFP and Audio-Device Management

**Status:** Implemented and validated.

### Goals

- Replace sample device menus with live Bluetooth and CoreAudio state.
- Make readiness reflect the devices actually available for a call.

### HFP Work

- Load paired phones using `BluetoothManager.getPairedPhones()`.
- Support refreshing the paired-device list and optional active scanning.
- Connect to the selected phone using `HFPDevice.connect()`.
- Consume the device's `HFPEventStream`.
- Display connecting, connected, failed, and disconnected states.
- Disable phone switching during an active call.

### Audio Work

- Load audio devices through `AudioRouter.allDevices()`.
- Only consider devices with both input and output call-ready.
- Persist and restore the selected device by stable CoreAudio UID.
- Detect when the selected device disappears or becomes unavailable.
- Validate audio configuration before dialing.

### Exit Criteria

- Readiness becomes complete only when an HFP phone is connected and a full-duplex audio interface is available.
- Device disconnects and audio-device removal immediately update the UI.

### Delivered

- Added a device-management protocol and typed state/event model shared by live and preview coordinators.
- Enumerated paired HFP phones, implemented connect/disconnect and HFP event consumption, and exposed refresh and failure states in SwiftUI.
- Enumerated full-duplex CoreAudio interfaces, selected them by stable UID, restored preferences, and represented missing selections as unavailable.
- Replaced sample menus with live device sections and readiness feedback; device changes lock for active and cleanup call phases.

## Stage 5 — Complete Call Lifecycle

### Goals

- Port the proven console lifecycle into the application call coordinator.
- Guarantee consistent cleanup across success and failure paths.

### Start Sequence

1. Validate caller data, phone number, API key, HFP connection, audio device, and output directories.
2. Generate the timestamped result URL and create `AgentSession`.
3. Dial through `HFPDevice.dial(number:)`.
4. Remain in the ringing state without starting GPT-Live.
5. When HFP emits `.callActive`:
   - Route system audio.
   - Configure and start `AudioSessionManager`.
   - Call `AgentSession.prepare()`.
   - Call `AgentSession.startAudio(using:)`.

### End and Failure Sequence

- The End button invokes `HFPDevice.endCall()`.
- On `.callEnded`, disconnection, startup failure, or cancellation:
  - Close the agent session.
  - Stop audio capture and playback.
  - Restore previous system audio routing.
  - Cancel event and retry tasks.
  - Finalize the appointment result.
- Make cleanup idempotent so repeated callbacks cannot stop or restore resources more than once.
- Prevent a second call from starting while another call is active or cleaning up.

### Exit Criteria

The following paths all reach the correct terminal state:

- Successful outgoing call.
- Long ringing interval.
- Manual hangup.
- Remote hangup.
- Unanswered call.
- Failed dial.
- HFP disconnect.
- Audio startup failure.
- Agent transport failure and reconnection.

## Stage 6 — Activity Logger and Live Status

**Status:** Implemented and validated.

### Goals

- Drive the header, controls, timer, and logger from typed runtime events.
- Preserve the package's privacy model.

### Work

- Map HFP events to user-facing activity entries:
  - Connecting.
  - Dialing.
  - Ringing.
  - Call active.
  - Call ended.
  - Phone disconnected.
- Map agent events to entries:
  - Preparing the assistant.
  - Callee speaking.
  - Assistant speaking.
  - Waiting for appointment reasoning.
  - Recovering the final result.
  - Reconnecting.
  - Result recorded.
- Maintain elapsed call duration.
- Coalesce repeated speech and activity updates.
- Keep a bounded in-memory activity history.
- Separate recoverable warnings from terminal errors.
- Never display or log transcript text.

### Exit Criteria

- The workspace header, readiness state, buttons, timer, and activity list always agree with the coordinator's call phase.
- Repeated events do not flood the activity list.
- No transcript content appears in logs.

### Delivered

- Replaced the prototype activity list with typed, privacy-safe HFP and agent activity presentations driven by coordinator events.
- Added elapsed active-call timing, phase-consistent header and control status, recoverable warning presentation, and terminal failure alerts.
- Coalesced consecutive repeated updates, capped in-memory history at 100 entries, and kept diagnostic or transcript content out of the UI log.
- Added reducer tests for coalescing, history bounds, privacy filtering, warning/error separation, and timer transitions.

## Stage 7 — PCM Output and Result Presentation

**Status:** Implemented and validated.

### Goals

- Implement the output settings shown in the prototype.
- Present the same structured result that is persisted to disk.

### Work

- Make `AgentSession` audio dumping optional.
- When PCM output is disabled, create no PCM files.
- When enabled, write two timestamped files to the configured PCM directory:
  - `*-agent-input.pcm`
  - `*-agent-output.pcm`
- Write appointment-result JSON to the configured result directory.
- Use collision-safe timestamped filenames.
- Emit a typed completion event containing the result and saved file URLs.
- Display all supported outcomes:
  - `booked`
  - `not_booked`
  - `unknown`
- Display date, time, practice, and notes when available.
- Add actions to reveal result and PCM files in Finder.
- Retain the previous result until the next call starts.
- Treat PCM creation failures as nonfatal while showing a visible warning.

### Exit Criteria

- Every completed call displays the same result that was written to disk.
- PCM files are created only when enabled.
- Output failures do not leave audio routing or call resources active.

### Delivered

- Deferred optional PCM file creation until the call becomes active, emitted confirmed file URLs through typed events, and made PCM setup/write failures nonfatal with visible warnings and partial-file cleanup.
- Persisted the exact appointment result displayed by Rufux using timestamped, UUID-backed collision-safe filenames in the configured result directory.
- Replaced the prototype result card with presentations for `booked`, `not_booked`, and `unknown`, including optional appointment details and Finder reveal actions for confirmed output files.
- Retained completed results until the next call starts and added reducer and filename tests covering Stage 7 behavior.

## Stage 8 — Testing, Permissions, and Hardening

### Automated Tests

Use Swift Testing for unit and integration tests covering:

- JSON decoding, import, and validation.
- Caller-draft conversion to `InputConfiguration`.
- Settings and security-bookmark persistence.
- Output path and filename generation.
- Call-state reducer transitions.
- Readiness rules.
- Idempotent cleanup.
- PCM enabled and disabled behavior.
- Result decoding and presentation mapping.
- Coordinator behavior with fake HFP, audio, and agent adapters.

Use XCUIAutomation for UI tests covering:

- JSON import and form population.
- Validation messages.
- Readiness gating.
- Start and End button states.
- Settings persistence.
- Result presentation.

### Platform Configuration

- Add required Bluetooth and microphone usage descriptions.
- Verify application entitlements and Hardened Runtime configuration.
- Verify sandbox compatibility with IOBluetooth and CoreAudio.
- Verify Keychain access.
- Verify security-scoped output-directory bookmarks.
- Restore audio routing when the application terminates unexpectedly where possible.

### Hardware Validation Matrix

- Successful booked appointment.
- Not-booked result.
- Unanswered call.
- Manual and remote hangup.
- Phone disconnect during ringing and during an active call.
- Audio-device removal during a call.
- GPT-Live transport reconnection.
- Structured-result recovery after remote hangup.
- Unwritable result or PCM directory.
- Relaunch with previously selected phone, audio device, and output folders.

### Exit Criteria

- Automated tests pass in Xcode.
- The hardware matrix is completed without leaked sessions or incorrect audio routing.
- Sensitive values and transcript content do not appear in logs.

## Delivery Order

```text
Stage 1
  ├── Stage 2: Settings
  ├── Stage 3: JSON and form
  └── Stage 4: Devices
          ↓
       Stage 5: Call lifecycle
          ↓
  Stage 6: Activity and status
  Stage 7: Outputs and results
          ↓
       Stage 8: Final validation
```

Stages 2, 3, and 4 can proceed independently after Stage 1. Stage 5 depends on all three. Tests should be added during each stage, with Stage 8 completing hardware integration and release hardening.

## Definition of Complete

The feature set is complete when a user can:

1. Configure an API key and output preferences securely.
2. Import or manually enter caller information.
3. Select and connect an HFP phone.
4. Select a full-duplex audio interface.
5. Start and end an assisted outgoing call.
6. Follow privacy-conscious live call status updates.
7. Receive a structured appointment result.
8. Find the saved result JSON and optional PCM files.
9. Recover cleanly from hardware, network, and call failures without leaving audio routing changed.
