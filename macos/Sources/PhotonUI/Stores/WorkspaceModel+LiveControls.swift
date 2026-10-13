import Foundation

// Busking support: continuous controls drive the renderer *during* the drag.
//
// The problem this solves, precisely. Every control writes to the provider and
// the renderer reads the provider's *acknowledged snapshot*, not the command.
// Re-reading that snapshot per drag event would be one provider round-trip per
// 16 ms, so `ControlSnapshotRefresh` debounces it by 80 ms — and it debounces
// by **cancelling and restarting** the timer. A drag emits an event every
// 16 ms, so the timer was restarted before it ever fired and the reload
// happened only ~80 ms after the operator let go. The fader moved, the number
// moved, and the output did not change until release. On stage that is not a
// latency problem, it is a control that cannot be performed with.
//
// The fix is not to remove the debounce — the debounce is correct, metadata
// reconciliation genuinely does not want 60 reads a second. The fix is to stop
// routing the *value* through the reconciliation path at all. A control being
// moved publishes its value here, synchronously, on the main actor;
// `masterPlan` prefers it over the snapshot; the debounced reload still runs
// and the override is dropped once the acknowledged value has landed.
//
// So the snapshot stays the store of record, and the operator still gets the
// value on the output in the same turn they moved the fader.
public extension WorkspaceModel {
    /// Which continuous control an override belongs to.
    enum LiveControl: Hashable, Sendable {
        case clipOpacity(String)
        case layerOpacity(String)
        case masterOpacity
    }

    /// The opacity the renderer should use for a layer right now.
    func resolvedLayerOpacity(_ layer: LayerSnapshot) -> Double {
        liveLayerOpacity[layer.id] ?? layer.opacity
    }

    /// The opacity the renderer should use for a layer's launched clip.
    func resolvedClipOpacity(_ layer: LayerSnapshot) -> Double {
        layer.activeClipID.flatMap { liveClipOpacity[$0] } ?? layer.clipOpacity
    }

    /// The clip inspector's fader position, override included.
    func resolvedClipOpacity(clipID: String, acknowledged: Double) -> Double {
        liveClipOpacity[clipID] ?? acknowledged
    }

    /// The master trim the renderer should use right now.
    var resolvedMasterOpacity: Double {
        liveMasterOpacity ?? master.value?.opacity ?? 1
    }

    /// Opens an override. The returned token identifies *this* edit, so a
    /// later one in the same drag cannot be retired by an earlier
    /// acknowledgement arriving late.
    func beginLiveControl(_ control: LiveControl) -> UInt64 {
        let next = (liveControlRequests[control] ?? 0) &+ 1
        liveControlRequests[control] = next
        return next
    }

    /// Retires an override, but only if nothing newer has been sent since.
    ///
    /// `after` is the reload that carries the acknowledged value. Clearing
    /// before it lands would show the pre-drag value for one frame — a visible
    /// flick back on every fader release.
    func endLiveControl(
        _ control: LiveControl, _ request: UInt64,
        after: Task<Void, Never>? = nil,
        clear: @escaping @MainActor (WorkspaceModel) -> Void
    ) {
        guard liveControlRequests[control] == request else { return }
        guard let after else {
            clear(self)
            return
        }
        Task { @MainActor [weak self] in
            await after.value
            guard let self, self.liveControlRequests[control] == request else { return }
            clear(self)
        }
    }
}
