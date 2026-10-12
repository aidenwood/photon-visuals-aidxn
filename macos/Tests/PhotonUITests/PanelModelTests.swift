import Foundation
import PhotonUI

@MainActor
struct PanelModelTests {
    func oneFailureDoesNotReplaceAnotherPanelsData() async throws {
        let preview = PanelModel<String>(name: "Preview")
        let inspector = PanelModel<String>(name: "Inspector")
        await preview.load { "last good frame" }.value
        await inspector.load {
            throw PanelIssue(title: "Inspector failed", message: "Try again.")
        }.value

        try require(preview.phase == .ready)
        try require(preview.value == "last good frame")
        try require(inspector.phase.issue != nil)
        try require(inspector.value == nil)
    }

    func refreshAndFailureRetainLastGoodData() async throws {
        let panel = PanelModel<String>(name: "Library")
        await panel.load { "known clips" }.value
        let gate = RequestGate<String>()
        let refresh = panel.load { try await gate.wait() }
        await gate.waitUntilRequested()

        try require(panel.phase == .loading)
        try require(panel.value == "known clips")
        await gate.finish(.failure(PanelIssue(title: "Offline", message: "Retry later.")))
        await refresh.value
        try require(panel.phase.issue != nil)
        try require(panel.value == "known clips")
    }

    func oldSuccessCannotOverwriteANewerRequest() async throws {
        let panel = PanelModel<String>(name: "Preview")
        let gate = RequestGate<String>()
        let old = panel.load { try await gate.wait() }
        await gate.waitUntilRequested()

        await panel.load { "new selection" }.value
        await gate.finish(.success("old selection"))
        await old.value

        try require(panel.phase == .ready)
        try require(panel.value == "new selection")
    }

    func oldErrorCannotFailANewerRequest() async throws {
        let panel = PanelModel<String>(name: "Inspector")
        let gate = RequestGate<String>()
        let old = panel.load { try await gate.wait() }
        await gate.waitUntilRequested()

        await panel.load { "new selection" }.value
        await gate.finish(.failure(PanelIssue(title: "Stale error", message: "Discard me.")))
        await old.value

        try require(panel.phase == .ready)
        try require(panel.value == "new selection")
    }

    func cancellationKeepsReadyDataAndDiscardsLateCompletion() async throws {
        let panel = PanelModel<String>(name: "Preview")
        await panel.load { "last good" }.value
        let gate = RequestGate<String>()
        let refresh = panel.load { try await gate.wait() }
        await gate.waitUntilRequested()

        panel.cancel()
        try require(panel.phase == .ready)
        try require(panel.value == "last good")
        await gate.finish(.success("cancelled result"))
        await refresh.value
        try require(panel.value == "last good")
    }

    func hungRequestTimesOutLocallyAndLateCompletionIsDiscarded() async throws {
        let panel = PanelModel<String>(name: "Preview")
        await panel.load { "last good" }.value
        let gate = RequestGate<String>()
        let request = panel.load(timeout: .milliseconds(25)) { try await gate.wait() }
        await gate.waitUntilRequested()

        let limit = ContinuousClock.now.advanced(by: .seconds(2))
        while panel.phase.isLoading && ContinuousClock.now < limit {
            try? await Task.sleep(for: .milliseconds(5))
        }
        try require(panel.phase.issue != nil)
        try require(panel.value == "last good")

        await gate.finish(.success("too late"))
        await request.value
        try require(panel.phase.issue != nil)
        try require(panel.value == "last good")
    }

    func retryRecoversOnlyTheFailedPanel() async throws {
        let panel = PanelModel<Int>(name: "Outputs")
        await panel.load { throw PanelIssue(title: "Offline", message: "Try again.") }.value
        try require(panel.phase.issue != nil)
        await panel.load { 2 }.value
        try require(panel.phase == .ready)
        try require(panel.value == 2)
    }
}

/// Deliberately ignores cancellation so tests exercise late provider completions.
private actor RequestGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, any Error>?
    private var started: [CheckedContinuation<Void, Never>] = []

    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            started.forEach { $0.resume() }
            started.removeAll()
        }
    }

    func waitUntilRequested() async {
        if continuation != nil { return }
        await withCheckedContinuation { started.append($0) }
    }

    func finish(_ result: Result<Value, any Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
