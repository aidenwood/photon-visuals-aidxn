import Foundation
import PhotonUI

// One canonical set of checks: Swift Testing and the CLT runner call these same cases.
enum UIRecoveryCase: String, CaseIterable, Sendable {
    case independentFailure, retainedData, staleSuccess, staleError, cancellation, timeout, retry
    case previewDimensions, duplicateIDs, controlValues, unknownTelemetry, malformedTelemetry, unknownID
    case gridSlots, commandCoalescing, commandLifetime, rapidBlackout
    case deckPlayback, clipInstances
    case effectDropReachesRenderer, effectDropSelectsScope, effectDropRejectsUnknownKind
    case effectClipChainOrder, effectRemovalClearsRenderer

    @MainActor func run() async throws {
        let panels = PanelModelTests()
        let data = SnapshotValidationTests()
        let controls = WorkspaceControlTests()
        let effects = EffectDropTests()
        switch self {
        case .independentFailure: try await panels.oneFailureDoesNotReplaceAnotherPanelsData()
        case .retainedData: try await panels.refreshAndFailureRetainLastGoodData()
        case .staleSuccess: try await panels.oldSuccessCannotOverwriteANewerRequest()
        case .staleError: try await panels.oldErrorCannotFailANewerRequest()
        case .cancellation: try await panels.cancellationKeepsReadyDataAndDiscardsLateCompletion()
        case .timeout: try await panels.hungRequestTimesOutLocallyAndLateCompletionIsDiscarded()
        case .retry: try await panels.retryRecoversOnlyTheFailedPanel()
        case .previewDimensions: try data.invalidPreviewDimensionsBecomePanelErrors()
        case .duplicateIDs: try data.duplicateIDsBecomePanelErrors()
        case .controlValues: try data.nonFiniteControlValuesBecomePanelErrors()
        case .unknownTelemetry: try data.unknownTelemetryRemainsUnknown()
        case .malformedTelemetry: try data.malformedTelemetryBecomesAPanelError()
        case .unknownID: try await data.previewProviderRejectsUnknownIDs()
        case .gridSlots: try data.malformedGridSlotsBecomePanelErrors()
        case .commandCoalescing: try await controls.continuousControlsCoalesceWithoutCrossingTriggers()
        case .commandLifetime: try await controls.cancellingMetadataDoesNotCancelAnAcceptedControl()
        case .rapidBlackout: try await controls.rapidBlackoutPressesUseTheLatestRequestedState()
        case .deckPlayback: try await controls.browsingAnEmptyDeckKeepsPlayingClips()
        case .clipInstances: try await controls.clipInstancesHaveIndependentControlsForASharedAsset()
        case .effectDropReachesRenderer: try await effects.aDropOnALayerReachesTheChainTheRendererReads()
        case .effectDropSelectsScope: try await effects.aDropSelectsTheScopeItLandedIn()
        case .effectDropRejectsUnknownKind: try await effects.anEffectTheEngineNeverPublishedIsRefused()
        case .effectClipChainOrder: try await effects.clipEffectsRunBeforeTheLayersOwn()
        case .effectRemovalClearsRenderer: try await effects.removingTheLastEffectClearsTheRenderersChain()
        }
    }
}

struct CheckFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

@MainActor
func require(
    _ condition: @autoclosure () -> Bool,
    file: StaticString = #fileID, line: UInt = #line
) throws {
    guard condition() else { throw CheckFailure(message: "Check failed at \(file):\(line)") }
}

@MainActor
func requirePanelIssue(_ operation: () throws -> Void) throws {
    do {
        try operation()
        throw CheckFailure(message: "Expected a recoverable PanelIssue.")
    } catch is PanelIssue {}
}
