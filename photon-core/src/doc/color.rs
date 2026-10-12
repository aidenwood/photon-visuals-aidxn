//! Colour description.
//!
//! Every source carries a full descriptor; nothing is inferred. Two reasons
//! this is fixed at R0 rather than added later:
//!
//! 1. **Soft-edge blending is only correct in linear light.** Two projectors
//!    overlapping at 50% each should sum to 100% *of light*, and sRGB values
//!    are not proportional to light. Blend in gamma space and the overlap band
//!    reads as a visible stripe — the exact artifact soft edge exists to remove.
//! 2. **Benchmarks against another engine are only fair at matched bit depth
//!    and colour behaviour.** Otherwise we "win" by doing less colour work.

use serde::{Deserialize, Serialize};

/// Complete colour description for a source or frame.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct ColorDescriptor {
    /// Colour primaries.
    pub primaries: Primaries,
    /// Transfer function (what people loosely call "gamma").
    pub transfer: Transfer,
    /// YUV→RGB matrix. Irrelevant for RGB sources.
    pub matrix: MatrixCoefficients,
    /// Full or limited (video) range.
    pub range: Range,
    /// How alpha relates to the colour channels.
    pub alpha: AlphaMode,
}

impl ColorDescriptor {
    /// The common case: sRGB, full range, straight alpha.
    #[must_use]
    pub const fn srgb() -> Self {
        Self {
            primaries: Primaries::Bt709,
            transfer: Transfer::Srgb,
            matrix: MatrixCoefficients::Identity,
            range: Range::Full,
            alpha: AlphaMode::Straight,
        }
    }

    /// Rec.709 video: limited range, BT.709 matrix — typical of camera and
    /// broadcast sources, and a frequent source of "why is black grey".
    #[must_use]
    pub const fn bt709_video() -> Self {
        Self {
            primaries: Primaries::Bt709,
            transfer: Transfer::Bt709,
            matrix: MatrixCoefficients::Bt709,
            range: Range::Limited,
            alpha: AlphaMode::Opaque,
        }
    }

    /// Whether a YUV→RGB conversion is needed when sampling.
    #[must_use]
    pub const fn needs_matrix_conversion(self) -> bool {
        !matches!(self.matrix, MatrixCoefficients::Identity)
    }
}

/// Colour primaries.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
#[allow(missing_docs)]
pub enum Primaries {
    #[default]
    Bt709,
    Bt2020,
    DciP3,
    DisplayP3,
    Bt601Pal,
    Bt601Ntsc,
}

/// Transfer function.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
#[allow(missing_docs)]
pub enum Transfer {
    /// Scene-linear. The compositor's working space.
    Linear,
    #[default]
    Srgb,
    Bt709,
    /// SMPTE ST 2084, HDR.
    Pq,
    /// Hybrid log-gamma, HDR.
    Hlg,
    /// Pure power function.
    Gamma22,
}

/// YUV→RGB matrix coefficients.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
#[allow(missing_docs)]
pub enum MatrixCoefficients {
    /// RGB already; no conversion.
    #[default]
    Identity,
    Bt709,
    Bt601,
    Bt2020Ncl,
    /// DXT5-YCoCg, as used by HapQ.
    YCoCg,
}

/// Signal range.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub enum Range {
    /// 0–255. Computer graphics.
    #[default]
    Full,
    /// 16–235 luma. Video. Treating this as full range crushes blacks and
    /// clips highlights.
    Limited,
}

/// Alpha convention.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub enum AlphaMode {
    /// No alpha channel; fully opaque.
    #[default]
    Opaque,
    /// Alpha is independent of the colour channels.
    Straight,
    /// Colour channels are already multiplied by alpha.
    Premultiplied,
}

impl AlphaMode {
    /// Whether a source may be transparent.
    ///
    /// Used by occlusion culling: a layer only occludes what's beneath it if it
    /// is geometrically covering **and** cannot be transparent. `opacity == 1.0`
    /// alone is not sufficient — the texture itself may carry alpha.
    #[must_use]
    pub const fn may_be_transparent(self) -> bool {
        !matches!(self, Self::Opaque)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rgb_sources_need_no_matrix_conversion() {
        assert!(!ColorDescriptor::srgb().needs_matrix_conversion());
    }

    #[test]
    fn video_sources_need_matrix_conversion() {
        assert!(ColorDescriptor::bt709_video().needs_matrix_conversion());
    }

    #[test]
    fn opacity_alone_does_not_imply_occlusion() {
        // The correction from Codex: a full-opacity layer whose texture carries
        // alpha does NOT occlude what is beneath it.
        assert!(AlphaMode::Straight.may_be_transparent());
        assert!(AlphaMode::Premultiplied.may_be_transparent());
        assert!(!AlphaMode::Opaque.may_be_transparent());
    }

    #[test]
    fn limited_range_is_distinct_from_full() {
        assert_ne!(Range::Limited, Range::Full);
        assert_ne!(ColorDescriptor::srgb(), ColorDescriptor::bt709_video());
    }
}
