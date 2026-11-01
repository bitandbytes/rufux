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
//  RufuxUITests.swift
//  RufuxUITests
//

import Foundation
import XCTest

@MainActor
final class RufuxUITests: XCTestCase {
    private let bundleIdentifier = "com.bitandbytes.rufux"

    override func setUp() {
        continueAfterFailure = false
    }

    func testJSONImportPopulatesTheCallerForm() throws {
        let fixtureURL = FileManager.default.temporaryDirectory
            .appending(path: "rufux-ui-caller-\(UUID().uuidString).json")
        let json = #"{"name":"UI Test Caller","dateOfBirth":"1985-04-12","insurance":"UI Health","additionalDetails":"Afternoon appointment","gender":"female","language":"German","telephoneNumber":"+49 555 12345","doctorReferralDetails":{"Referral":"Radiology"}}"#
        try Data(json.utf8).write(to: fixtureURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let app = launch(reset: true, importURL: fixtureURL)

        XCTAssertTrue(app.staticTexts[fixtureURL.lastPathComponent].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["caller-name"].value as? String, "UI Test Caller")
        XCTAssertEqual(app.textFields["caller-date-of-birth"].value as? String, "1985-04-12")
        XCTAssertEqual(app.textFields["caller-insurance"].value as? String, "UI Health")
        XCTAssertEqual(app.textFields["caller-phone-number"].value as? String, "+49 555 12345")
        XCTAssertEqual(app.textFields["caller-language"].value as? String, "German")
    }

    func testValidationAndReadinessGateTheCallButton() {
        let app = launch(reset: true)
        let phoneNumber = app.textFields["destination-phone-number"]
        let callButton = app.buttons["start-call"]
        scrollCallControlsIntoView(in: app)

        XCTAssertTrue(phoneNumber.waitForExistence(timeout: 5))
        XCTAssertFalse(callButton.isEnabled)
        phoneNumber.click()
        phoneNumber.typeText("+49 555 12345")
        XCTAssertTrue(waitUntilEnabled(callButton))

        let nameField = app.textFields["caller-name"]
        nameField.click()
        nameField.typeKey("a", modifierFlags: .command)
        nameField.typeKey(.delete, modifierFlags: [])

        XCTAssertTrue(app.staticTexts["Enter the caller's name."].waitForExistence(timeout: 3))
        XCTAssertFalse(callButton.isEnabled)
    }

    func testStartEndAndResultPresentation() {
        let app = launch(reset: true)
        scrollCallControlsIntoView(in: app)
        let phoneNumber = app.textFields["destination-phone-number"]
        let callButton = app.buttons["start-call"]
        let endButton = app.buttons["end-call"]

        XCTAssertTrue(phoneNumber.waitForExistence(timeout: 5))
        phoneNumber.click()
        phoneNumber.typeText("+49 555 12345")
        XCTAssertTrue(waitUntilEnabled(callButton))
        callButton.click()

        XCTAssertTrue(waitUntilEnabled(endButton))
        XCTAssertFalse(phoneNumber.isEnabled)
        endButton.click()

        XCTAssertTrue(app.staticTexts["Appointment booked"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["UI Test Practice"].exists)
    }

    func testSettingsPersistenceAcrossRelaunch() {
        var app = launch(reset: true)
        openSettings(in: app)
        var toggle = app.switches["save-pcm-audio"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.click()
        XCTAssertEqual(toggle.value as? String, "1")
        app.terminate()

        app = launch(reset: false)
        openSettings(in: app)
        toggle = app.switches["save-pcm-audio"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1")
    }

    private func launch(reset: Bool, importURL: URL? = nil) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: bundleIdentifier)
        app.launchArguments = ["--ui-testing"]
        if reset {
            app.launchArguments.append("--ui-testing-reset")
        }
        if let importURL {
            app.launchArguments.append("--ui-testing-import=\(importURL.path)")
        }
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        return app
    }

    private func scrollCallControlsIntoView(in app: XCUIApplication) {
        let phoneNumber = app.textFields["destination-phone-number"]
        guard !phoneNumber.isHittable else { return }
        let operationsScrollView = app.scrollViews.element(boundBy: 1)
        for _ in 0..<3 where !phoneNumber.isHittable {
            operationsScrollView.swipeUp()
        }
    }

    private func waitUntilEnabled(_ element: XCUIElement) -> Bool {
        let predicate = NSPredicate(format: "enabled == true")
        return XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: predicate, object: element)],
            timeout: 5
        ) == .completed
    }

    private func openSettings(in app: XCUIApplication) {
        app.typeKey(",", modifierFlags: .command)
    }
}
