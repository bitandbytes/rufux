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

public enum AgentSessionActivity: String, Equatable, Sendable {
    case preparing = "Preparing call assistant"
    case waitingForCallee = "Waiting for the callee"
    case calleeSpeaking = "Callee speaking"
    case assistantSpeaking = "Assistant speaking"
    case waitingForAssistant = "Waiting for call assistant"
    case assistantWorking = "Call assistant working"
    case discussionOngoing = "Discussion ongoing"
    case recoveringOutcome = "Recovering final appointment result"
    case closing = "Closing call assistant"
}

public enum AgentSessionEvent: Equatable, Sendable {
    case activity(AgentSessionActivity)
    case diagnostic(String)
    case resultRecorded(AppointmentResult)
    case resultWritten(AppointmentResult, URL)
    case resultWriteFailed(String)
    case reconnecting(attempt: Int, maximumAttempts: Int, reason: String)
    case failure(String)
    case closed
}

public final class AgentSessionEventStream: @unchecked Sendable {
    private var continuations: [UUID: AsyncStream<AgentSessionEvent>.Continuation] = [:]
    private let lock = NSLock()

    public init() {}

    public func makeStream() -> AsyncStream<AgentSessionEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.lock()
            continuations[id] = continuation
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations.removeValue(forKey: id)
                self.lock.unlock()
            }
        }
    }

    func emit(_ event: AgentSessionEvent) {
        lock.lock()
        let activeContinuations = Array(continuations.values)
        lock.unlock()

        for continuation in activeContinuations {
            continuation.yield(event)
        }
    }

    func finish() {
        lock.lock()
        let activeContinuations = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()

        for continuation in activeContinuations {
            continuation.finish()
        }
    }
}

public struct AgentSessionOutputConfiguration: Equatable, Sendable {
    public let resultURL: URL
    public let isPCMOutputEnabled: Bool
    public let pcmOutputDirectory: URL?

    public init(
        resultURL: URL,
        isPCMOutputEnabled: Bool = true,
        pcmOutputDirectory: URL? = nil
    ) {
        self.resultURL = resultURL
        self.isPCMOutputEnabled = isPCMOutputEnabled
        self.pcmOutputDirectory = pcmOutputDirectory
    }

    public var resolvedPCMOutputDirectory: URL? {
        guard isPCMOutputEnabled else { return nil }
        return pcmOutputDirectory ?? resultURL.deletingLastPathComponent()
    }
}
