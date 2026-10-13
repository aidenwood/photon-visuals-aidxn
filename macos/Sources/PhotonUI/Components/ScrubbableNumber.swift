import AppKit
import SwiftUI

/// Normalized parameter value: drag digits, arrows to step, double-click to type.
/// Precision/range metadata can replace these defaults when ParamSpec is exposed.
struct ScrubbableNumber: View {
    let value: Double
    let label: String
    let change: (Double) -> Void
    @State private var start: Double?
    @State private var draft: Double?
    @State private var text = ""
    @State private var editing = false
    @FocusState private var textFocused: Bool

    var body: some View {
        Group {
            if editing {
                TextField(label, text: $text)
                    .textFieldStyle(.plain).focused($textFocused)
                    .multilineTextAlignment(.trailing)
                    .onSubmit(commit)
                    .onExitCommand { editing = false; draft = nil }
                    .onChange(of: textFocused) { _, focused in if !focused && editing { commit() } }
            } else {
                Text((draft ?? value).formatted(.number.precision(.fractionLength(2))))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        text = String(value); editing = true; textFocused = true
                    }
                    .gesture(DragGesture(minimumDistance: 2).onChanged { drag in
                        if start == nil { start = value }
                        let step = NSEvent.modifierFlags.contains(.shift) ? 0.001 : 0.01
                        let next = min(1, max(0, (start ?? value) + Double(drag.translation.width) * step))
                        draft = next; change(next)
                    }.onEnded { _ in
                        if let draft { change(draft) }
                        start = nil; draft = nil
                    })
                    .focusable()
                    .onKeyPress(.leftArrow) { step(-1); return .handled }
                    .onKeyPress(.rightArrow) { step(1); return .handled }
                    .accessibilityAdjustableAction { direction in step(direction == .increment ? 1 : -1) }
            }
        }
        .font(.system(size: 10, design: .monospaced)).monospacedDigit()
        .padding(.horizontal, 3).frame(width: 46, height: PhotonTheme.controlHeight)
        .background(PhotonTheme.background)
        .foregroundStyle(PhotonTheme.accent)
        .accessibilityLabel(label).accessibilityValue(String(value))
        .help("Drag to adjust; Shift for fine control; double-click to type")
    }

    private func step(_ direction: Double) {
        let amount = NSEvent.modifierFlags.contains(.shift) ? 0.001 : 0.01
        change(min(1, max(0, value + direction * amount)))
    }
    private func commit() {
        if let number = Double(text), number.isFinite { change(min(1, max(0, number))) }
        editing = false; draft = nil
    }
}
