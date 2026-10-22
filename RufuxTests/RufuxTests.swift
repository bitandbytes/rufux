//
//  RufuxTests.swift
//  RufuxTests
//
//  Created by Hasini Suchetha Jayathilaka on 16.10.26.
//

import Foundation
import PhoneBTCore
import Testing
@testable import Rufux

struct RufuxTests {

    @Test func repeatedActivityIsCoalesced() {
        var state = AppViewState.prototype

        state.reduce(.coordinator(.agent(.activity(.assistantSpeaking))))
        state.reduce(.coordinator(.agent(.activity(.assistantSpeaking))))

        #expect(state.activityEntries.count == 1)
        #expect(state.activityEntries.first?.occurrenceCount == 2)
    }

    @Test func activityHistoryIsBounded() {
        var state = AppViewState.prototype

        for index in 0..<105 {
            state.reduce(.coordinator(.activity(.warning("Warning \(index)"))))
        }

        #expect(state.activityEntries.count == 100)
        #expect(state.activityEntries.first?.message == "Warning 5")
    }

    @Test func diagnosticsNeverAppearInActivityHistory() {
        var state = AppViewState.prototype

        state.reduce(.coordinator(.agent(.diagnostic("private transcript text"))))

        #expect(state.activityEntries.isEmpty)
        #expect(state.errorMessage == nil)
        #expect(state.warningMessage == nil)
    }

    @Test func reconnectingIsARecoverableWarning() {
        var state = AppViewState.prototype

        state.reduce(.coordinator(.agent(.reconnecting(
            attempt: 1,
            maximumAttempts: 3,
            reason: "Connection interrupted"
        ))))

        #expect(state.warningMessage != nil)
        #expect(state.errorMessage == nil)
        #expect(state.callPhase != .failed)
        #expect(state.activityEntries.last?.kind == .warning)
    }

    @Test func terminalFailureIsSeparatedFromWarnings() {
        var state = AppViewState.prototype
        state.reduce(.coordinator(.agent(.reconnecting(
            attempt: 1,
            maximumAttempts: 3,
            reason: "Connection interrupted"
        ))))

        state.reduce(.coordinator(.failure("The assistant could not reconnect.")))

        #expect(state.warningMessage == nil)
        #expect(state.errorMessage == "The assistant could not reconnect.")
        #expect(state.callPhase == .failed)
    }

    @Test func elapsedTimeStartsAndStopsWithActiveCall() {
        var state = AppViewState.prototype

        state.reduce(.coordinator(.phaseChanged(.active)))
        #expect(state.callStartedAt != nil)
        #expect(state.callEndedAt == nil)

        state.reduce(.coordinator(.phaseChanged(.finalizing)))
        #expect(state.callEndedAt != nil)
    }

    @Test func appointmentStatusMapsToSupportedOutcomes() {
        #expect(AppointmentOutcome(status: "booked") == .booked)
        #expect(AppointmentOutcome(status: "not_booked") == .notBooked)
        #expect(AppointmentOutcome(status: "unknown") == .unknown)
        #expect(AppointmentOutcome(status: "unexpected-value") == .unknown)
    }

    @Test func completedResultIsRetainedUntilTheNextCallStarts() {
        var state = AppViewState.prototype
        let result = CallResult(
            appointment: AppointmentResult(
                status: "booked",
                appointmentDate: "2026-11-03",
                appointmentTime: "10:30",
                practice: "Example Practice",
                notes: "Bring the referral."
            ),
            resultURL: URL(fileURLWithPath: "/results/call-result.json"),
            inputPCMURL: nil,
            outputPCMURL: nil
        )

        state.reduce(.coordinator(.result(result)))
        state.reduce(.setCaller(.prototype))
        #expect(state.latestResult == result)

        state.reduce(.coordinator(.phaseChanged(.validating)))
        #expect(state.latestResult == nil)
    }

    @Test func pcmOutputFailureIsNonterminalAndVisible() {
        var state = AppViewState.prototype

        state.reduce(.coordinator(.agent(.pcmOutputFailed("The disk is full."))))

        #expect(state.warningKind == .pcmOutput)
        #expect(state.warningMessage?.contains("The disk is full.") == true)
        #expect(state.errorMessage == nil)
        #expect(state.callPhase == .idle)
        #expect(state.activityEntries.last?.kind == .warning)
    }

    @Test func outputFilenamesAreCollisionSafe() throws {
        let directory = URL(fileURLWithPath: "/results", isDirectory: true)
        let date = Date(timeIntervalSince1970: 1_795_027_200)
        let firstIdentifier = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let secondIdentifier = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let first = CallOutputURLBuilder.resultURL(
            in: directory,
            date: date,
            identifier: firstIdentifier
        )
        let second = CallOutputURLBuilder.resultURL(
            in: directory,
            date: date,
            identifier: secondIdentifier
        )

        #expect(first != second)
        #expect(first.pathExtension == "json")
        #expect(first.lastPathComponent.hasSuffix("-appointment-result.json"))
        #expect(!first.lastPathComponent.contains(":"))
    }

    @MainActor
    @Test func callerAndDestinationPhoneNumbersRemainIndependent() throws {
        let profilePhoneNumber = "+49 111 11111"
        let destinationPhoneNumber = "+49 222 22222"
        var caller = CallerDraft.prototype
        caller.telephoneNumber = profilePhoneNumber
        let editor = CallerEditorStore(caller: caller)
        let configuration = try editor.inputConfiguration()
        let request = CallStartRequest(
            apiKey: "test-key",
            configuration: configuration,
            phoneNumber: PhoneNumberValidator.normalized(destinationPhoneNumber),
            resultOutputDirectory: URL(fileURLWithPath: "/results", isDirectory: true),
            isPCMOutputEnabled: false,
            pcmOutputDirectory: nil
        )

        #expect(configuration.telephoneNumber == profilePhoneNumber)
        #expect(request.phoneNumber == destinationPhoneNumber)
        #expect(request.phoneNumber != configuration.telephoneNumber)
        #expect(PhoneNumberValidator.isValid(request.phoneNumber))
    }

}
