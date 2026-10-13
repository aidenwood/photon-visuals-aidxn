// The seam between measured engine timings and the corner readout.
//
// `PhotonUI` must not import Metal or the engine, and the engine must not
// import SwiftUI, so neither can hand the other a value directly. This is the
// one-way drop box between them: the engine-side surface
// (`PhotonRenderSurface`) publishes, and a `WorkspaceProvider` reads. Both
// speak only `TelemetrySnapshot`, which PhotonUI already owns.
//
// It carries **measurements only**. There is no fallback value anywhere in
// this file: no target frame rate, no last-known-good, no zero. When the
// engine is not running, or has not yet measured something, the field is `nil`
// and the readout shows "—". That is the entire point — a telemetry panel that
// invents a number is worse than a blank one, because the blank one is the
// only version that makes someone go and look.

import Foundation
import SwiftUI
import os

/// Latest measured frame timings from the live render surface.
public final class LiveTelemetryBus: Sendable {
    public static let shared = LiveTelemetryBus()

    /// How long a published sample stays valid.
    ///
    /// Comfortably longer than the publisher's own 250 ms cadence, so an
    /// ordinary scheduling hiccup does not blink the readout, and short enough
    /// that a stopped engine goes blank within about a second instead of
    /// leaving a frozen number on screen that still looks live. A stale number
    /// is a lie with a timestamp on it.
    public static let staleAfter: TimeInterval = 1.0

    private struct State {
        var snapshot = TelemetrySnapshot(cpuMilliseconds: nil, gpuMilliseconds: nil, outputFPS: nil)
        var publishedAt: TimeInterval = 0
        /// Which surface is speaking for the program output. One owner, so two
        /// mounted previews cannot interleave their numbers into a single
        /// readout that belongs to neither.
        var owner: ObjectIdentifier?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    private init() {}

    /// Claims the readout for a surface. Returns `false` if another surface
    /// already owns it, in which case the caller must not publish.
    public func claim(_ source: AnyObject) -> Bool {
        // Identity is taken outside every locked region in this file on
        // purpose: `withLock` takes a `@Sendable` closure and a view is not
        // Sendable. `ObjectIdentifier` is, and identity is all the lock needs.
        let id = ObjectIdentifier(source)
        return state.withLock { s in
            if let owner = s.owner, owner != id { return false }
            s.owner = id
            return true
        }
    }

    /// Hands the readout back and blanks it. Call when the surface detaches —
    /// the numbers describe a renderer that is no longer running.
    public func release(_ source: AnyObject) {
        let id = ObjectIdentifier(source)
        state.withLock { s in
            guard s.owner == id else { return }
            s.owner = nil
            s.snapshot = TelemetrySnapshot(cpuMilliseconds: nil, gpuMilliseconds: nil, outputFPS: nil)
            s.publishedAt = 0
        }
    }

    /// Publishes a measured sample. Any field the engine could not measure
    /// must be passed as `nil`; never substitute a value here.
    ///
    /// Called from the owning surface's throttled publisher, **not** from its
    /// display-link callback — this takes a lock, and nothing that takes a
    /// lock belongs on the frame path.
    public func publish(_ snapshot: TelemetrySnapshot, from source: AnyObject) {
        let now = ProcessInfo.processInfo.systemUptime
        let id = ObjectIdentifier(source)
        state.withLock { s in
            guard s.owner == id else { return }
            s.snapshot = snapshot
            s.publishedAt = now
        }
    }

    /// The current measurements, or an all-`nil` snapshot when no live surface
    /// is publishing or the last sample has gone stale.
    public var current: TelemetrySnapshot {
        let now = ProcessInfo.processInfo.systemUptime
        return state.withLock { s in
            guard s.owner != nil, s.publishedAt > 0,
                  now - s.publishedAt <= Self.staleAfter else {
                return TelemetrySnapshot(cpuMilliseconds: nil, gpuMilliseconds: nil, outputFPS: nil)
            }
            return s.snapshot
        }
    }

    /// Whether a live surface is currently publishing measurements. Lets a
    /// diagnostic distinguish "the engine says it cannot measure this" from
    /// "there is no engine attached", which look identical on the readout.
    public var isLive: Bool {
        let now = ProcessInfo.processInfo.systemUptime
        return state.withLock { s in
            s.owner != nil && s.publishedAt > 0 && now - s.publishedAt <= Self.staleAfter
        }
    }
}

public extension View {
    /// Keeps the metrics readout current for as long as this view is on screen.
    ///
    /// `WorkspaceModel.start()` loads every panel exactly once, which is right
    /// for a library or a mapping but wrong for a frame-rate: a metric that is
    /// read once is a screenshot, not telemetry. This re-reads the provider on
    /// a fixed cadence and stops when the view goes away.
    ///
    /// 250 ms matches the engine's own telemetry republish interval. Faster
    /// would re-read numbers the engine has not recalculated; slower would lag
    /// behind a change the operator just made and make cause and effect hard
    /// to connect. The digits themselves are already smoothed by the engine's
    /// rolling average, so this cadence controls freshness, not stability.
    ///
    /// Only the value changes — `TelemetryPanel` keeps showing the previous
    /// reading while a refresh is in flight, so there is no skeleton flicker.
    func liveTelemetryRefresh(
        _ model: WorkspaceModel,
        every interval: Duration = .milliseconds(250)
    ) -> some View {
        task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                if Task.isCancelled { return }
                await model.reloadTelemetry().value
            }
        }
    }
}
