import SwiftUI

struct TransportControls: View {
    let snapshot: TransportSnapshot
    let busy: Bool
    let toggle: () -> Void
    let setBPM: (Double) -> Void
    let tap: () -> Void

    /// What the operator has typed, before it is committed.
    ///
    /// Kept locally so a half-typed "1" on the way to "128" is never sent to
    /// the engine, where it would be rejected as out of range and look like
    /// the field had broken.
    @State private var draft = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 8) {
            IconButton(
                symbol: snapshot.isPlaying ? "pause.fill" : "play.fill",
                label: snapshot.isPlaying ? "Pause composition" : "Play composition",
                action: toggle
            )
            .disabled(busy)
            Text("00:00:00").font(.system(size: 12, weight: .medium, design: .monospaced))
            Spacer()
            Button(action: tap) {
                Image(systemName: "metronome").foregroundStyle(PhotonTheme.accent)
            }
            .buttonStyle(.plain).disabled(busy)
            .help("Tap tempo")
            .accessibilityLabel("Tap tempo")
            // In a raised well like every other editable control in the app.
            // Styled as a bare label it read as a readout, which is the same
            // lie in reverse — a control nobody knows they can use.
            TextField("", text: $draft)
                .textFieldStyle(.plain).multilineTextAlignment(.trailing)
                .monospacedDigit().font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 5).frame(width: 46, height: PhotonTheme.controlHeight)
                .background(PhotonTheme.raised, in: Rectangle())
                .contentShape(Rectangle())
                .focused($editing).disabled(busy)
                .onSubmit(commit)
                // A field left focused keeps showing the draft; a field the
                // operator has moved away from must show what the engine took.
                .onChange(of: editing) { _, focused in if !focused { commit() } }
                .onChange(of: snapshot.bpm) { _, _ in if !editing { draft = formatted } }
                .onAppear { draft = formatted }
                .accessibilityLabel("Tempo in BPM")
            Text("BPM").font(.system(size: 9)).foregroundStyle(PhotonTheme.faint)
        }
        .padding(.horizontal, PhotonTheme.contentInset)
    }

    private var formatted: String {
        snapshot.bpm.formatted(.number.precision(.fractionLength(0...1)))
    }

    /// Commits the draft, or puts the committed value back.
    ///
    /// An unparsable or out-of-range entry **reverts visibly** rather than
    /// being clamped. Clamping would leave the field reading 300 after a
    /// fat-fingered 3000 and the operator believing that is the tempo.
    private func commit() {
        guard let value = Double(draft.trimmingCharacters(in: .whitespaces)),
              value.isFinite, (20...300).contains(value) else {
            draft = formatted
            return
        }
        // Show the accepted number straight away. The snapshot that confirms
        // it arrives a round-trip later, and while the field still has focus
        // the `snapshot.bpm` observer deliberately will not overwrite a draft.
        draft = value.formatted(.number.precision(.fractionLength(0...1)))
        guard value != snapshot.bpm else { return }
        setBPM(value)
    }
}
