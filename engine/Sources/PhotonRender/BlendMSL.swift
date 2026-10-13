// The blend-mode maths, as Metal source, defined exactly once.
//
// Two shaders need it: the compositor, which folds the layer stack, and the
// effect chain, which blends an effect's wet result back over its dry input.
// Before this file the compositor held the only copy, so giving effects a
// blend mode would have meant a second one.
//
// That matters more than it looks. Earlier today the Swift `BlendMode` enum
// had drifted from the Rust `BlendMode` it mirrors — `Subtract` was missing,
// so every mode above it was off by one and `Darken` crashed. A forked copy of
// the *maths* would be the same failure a second time, and harder to see,
// because two shaders can disagree for a long while before anyone notices the
// picture is subtly wrong rather than obviously broken.
//
// The `case` numbers here are `BlendMode.rawValue` and nothing else.
// `PhotonVerify` asserts the enum is contiguous 0...10 with 11 cases.

enum BlendMSL {
    /// `blend_rgb(mode, dst, src)` — `dst` is what is underneath, `src` what is
    /// being drawn over it. Returns the combined colour in **linear light**;
    /// every caller is a linear working target.
    ///
    /// `over` is the `default` branch rather than `case 0` so an out-of-range
    /// mode degrades to plain source rather than to black. A show carrying a
    /// mode this build does not know should look wrong, not disappear.
    static let source = """
    static float3 blend_rgb(int mode, float3 dst, float3 src) {
        switch (mode) {
            case 1:  return dst + src;                                  // add
            case 2:  return dst * src;                                  // multiply
            case 3:  return dst + src - dst * src;                      // screen
            case 4:  return abs(dst - src);                             // difference
            case 5:  return dst * src;                                  // mask (luma of src gates dst)
            case 6:  return select(2.0*dst*src, 1.0-2.0*(1.0-dst)*(1.0-src), dst > 0.5); // overlay
            case 7:  return select(2.0*dst*src, 1.0-2.0*(1.0-dst)*(1.0-src), src > 0.5); // hard light
            case 8:  return max(dst - src, 0.0);                        // subtract
            case 9:  return max(dst, src);                              // lighten
            case 10: return min(dst, src);                              // darken
            default: return src;                                        // over
        }
    }
    """
}
