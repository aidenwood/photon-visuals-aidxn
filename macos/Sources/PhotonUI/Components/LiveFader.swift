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

    init(value: Double, label: String, change: @escaping (Double) -> Void) {
        self.value = value; self.label = label; self.change = change
        _draft = State(initialValue: value)
    }

    var body: some View {
        HStack(spacing: 8) {
            Slider(value: $draft, in: 0...1) { active in
                editing = active
                if !active { flush() }
            }
            .controlSize(.mini).tint(PhotonTheme.accent).accessibilityLabel(label)
            Text(draft.formatted(.percent.precision(.fractionLength(0))))
                .font(.system(size: 10)).monospacedDigit().frame(width: 35, alignment: .trailing)
        }
        .onChange(of: draft) { _, _ in
            guard editing, pending == nil else { return }
            pending = Task {
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                change(draft)
                pending = nil
            }
        }
        .onChange(of: value) { _, updated in if !editing { draft = updated } }
        .onDisappear {
            pending?.cancel()
            pending = nil
            if editing { change(draft) }
        }
    }

    private func flush() {
        pending?.cancel()
        pending = nil
        change(draft)
    }
}
