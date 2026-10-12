//! Exact rational time.
//!
//! Frame rates and timestamps are ratios, never floats. 30000/1001 is not
//! 29.97; a float approximation accumulates drift that is invisible in a
//! ten-second test and obvious three hours into a show — and effectively
//! un-debuggable once it is.

use serde::{Deserialize, Serialize};

/// An exact ratio `numerator / denominator`.
///
/// Always stored in lowest terms with a positive denominator, so equality is
/// value equality: `60/1 == 120/2`.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Hash)]
pub struct Rational {
    num: i64,
    den: i64,
}

impl Rational {
    /// Creates a rational, normalised to lowest terms.
    ///
    /// # Panics
    /// If `den` is zero.
    #[must_use]
    pub fn new(num: i64, den: i64) -> Self {
        assert!(den != 0, "Rational denominator must not be zero");
        let (mut num, mut den) = (num, den);
        if den < 0 {
            num = -num;
            den = -den;
        }
        let g = gcd(num.unsigned_abs(), den.unsigned_abs()) as i64;
        Self {
            num: num / g,
            den: den / g,
        }
    }

    /// The numerator.
    #[must_use]
    pub const fn num(self) -> i64 {
        self.num
    }

    /// The denominator, always positive.
    #[must_use]
    pub const fn den(self) -> i64 {
        self.den
    }

    /// Lossy conversion to `f64`.
    ///
    /// For display and for ratios that genuinely need a float. **Never** for
    /// accumulating time — that is what this type exists to prevent.
    #[must_use]
    pub fn to_f64(self) -> f64 {
        self.num as f64 / self.den as f64
    }

    /// The reciprocal: a rate becomes a period.
    ///
    /// # Panics
    /// If the numerator is zero.
    #[must_use]
    pub fn recip(self) -> Self {
        Self::new(self.den, self.num)
    }

    /// 60 fps.
    pub const FPS_60: Self = Self { num: 60, den: 1 };
    /// 120 fps.
    pub const FPS_120: Self = Self { num: 120, den: 1 };
    /// NTSC 29.97 — exactly 30000/1001.
    pub const FPS_29_97: Self = Self {
        num: 30000,
        den: 1001,
    };
}

const fn gcd(a: u64, b: u64) -> u64 {
    if b == 0 {
        if a == 0 {
            1
        } else {
            a
        }
    } else {
        gcd(b, a % b)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalises_to_lowest_terms() {
        assert_eq!(Rational::new(120, 2), Rational::new(60, 1));
        assert_eq!(Rational::new(-4, -8), Rational::new(1, 2));
    }

    #[test]
    fn negative_denominator_moves_to_numerator() {
        let r = Rational::new(1, -2);
        assert_eq!(r.num(), -1);
        assert_eq!(r.den(), 2);
    }

    #[test]
    fn ntsc_is_exact_not_approximate() {
        let r = Rational::FPS_29_97;
        assert_eq!((r.num(), r.den()), (30000, 1001));
        // The float is not equal to the exact value — the whole point.
        assert!((r.to_f64() - 29.97).abs() > f64::EPSILON);
    }

    #[test]
    fn recip_turns_rate_into_period() {
        assert_eq!(Rational::FPS_60.recip(), Rational::new(1, 60));
    }

    #[test]
    fn zero_numerator_is_allowed_and_normalised() {
        assert_eq!(Rational::new(0, 5), Rational::new(0, 1));
    }

    #[test]
    #[should_panic(expected = "denominator")]
    fn zero_denominator_panics() {
        let _ = Rational::new(1, 0);
    }
}
