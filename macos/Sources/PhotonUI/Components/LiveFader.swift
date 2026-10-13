import SwiftUI

/// Local drag state; emits at most one pending update and flushes on release.
/// This is a control-event cadence, never the engine's presentation clock.
struct LiveFader: View {
    let value: Double
    let label: String
    let change: (Double) -> Void
    @State private var draft: Double
    @State private var editing = false
    @State private var pending: Task<Void, Never>?
    /// Set only while this view is writing an acknowledged value back into
    /// `draft`. Without it that write looks identical to an operator edit and
    /// gets echoed straight back to the provider.
    @State private var adopting = false

    init(value: Double, label: String, change: @escaping (Double) -> Void) {
        self.value = value; self.label = label; self.change = change
        _draft = State(initialValue: value)
    }

    var body: some View {
        HStack(spacing: 4) {
            Slider(value: $draft, in: 0...1) { active in
                editing = active
                if !active { flush() }
            }
            .controlSize(.mini).tint(PhotonTheme.accent).accessibilityLabel(label)
            Text(draft.formatted(.percent.precision(.fractionLength(0))))
                .font(.system(size: 10)).monospacedDigit().frame(width: 35, alignment: .trailing)
        }
        // Not gated on `editing`. A keyboard arrow press and a VoiceOver value
        // change both move `draft` without ever calling `onEditingChanged`, so
        // gating here meant those two input paths silently reached nothing —
        // the fader animated and the output did not move.
        .onChange(of: draft) { _, _ in
            if adopting { adopting = false; return }
            guard pending == nil else { return }
            pending = Task {
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                change(draft)
                pending = nil
            }
        }
        .onChange(of: value) { _, updated in
            guard !editing, updated != draft else { return }
            adopting = true
            draft = updated
        }
        .onDisappear {
            // A coalesced update still in flight is a real edit that has not
            // landed yet. Cancelling it without flushing loses the last value
            // of a keyboard edit, which never sets `editing` at all.
            let unflushed = pending != nil
            pending?.cancel()
            pending = nil
            if editing || unflushed { change(draft) }
        }
    }

    private func flush() {
        pending?.cancel()
        pending = nil
        change(draft)
    }
}
