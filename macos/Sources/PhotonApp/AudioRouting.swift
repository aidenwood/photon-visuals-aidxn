// Joins the engine's analyser to the core's modulation.
//
// The direction matters: **the core decides which bands exist.** They come from
// whatever the operator has bound, so a composition with nothing audio-reactive
// runs no filter bank at all, and one bound to a single bass band runs exactly
// one. The shell does not get to pick a fixed set and hope it covers things.
//
// And the shell pushes **raw** energy. Attack and release live with the binding
// in the core, where the Windows shell shares them. Smoothing on both sides is
// not twice as smooth — it is laggy and mushy, and it gets blamed on the audio
// interface rather than on the code.

import PhotonCoreBridge
import PhotonRender

extension PhotonCoreSession {
    /// Reconfigures the analyser to exactly the bands the core needs.
    ///
    /// Call after any change to audio bindings. Returns true if the band set
    /// actually changed, so the caller can avoid resetting envelopes — a reset
    /// mid-show drops every audio-reactive parameter to zero for a frame.
    @discardableResult
    func syncAnalyser(_ analyser: AudioAnalyser) -> Bool {
        let wanted = audioBands
        let have = analyser.bandRanges
        guard wanted.count != have.count
                || zip(wanted, have).contains(where: { $0.low != $1.low || $0.high != $1.high })
        else { return false }

        analyser.setBands(wanted.enumerated().map { index, range in
            // Attack and release are the core's, so the analyser's own
            // smoothing is set out of the way rather than fighting it. It still
            // runs, because `levels` is what a meter should show.
            AudioBand(name: "Band \(index + 1)", lowHz: range.low, highHz: range.high,
                      attackMs: 5, releaseMs: 80)
        })
        return true
    }

    /// Pushes this frame's analysis into the core.
    ///
    /// Takes `rawLevels`, never `levels` — see the note at the top of this file.
    func pushAudio(_ snapshot: AudioSnapshot) {
        setAudioBands(snapshot.rawLevels)
    }
}
