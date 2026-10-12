//! Stable object identity.

use serde::{Deserialize, Serialize};

/// An opaque, stable identifier for a document object.
///
/// Persisted verbatim. A layer keeps its `Id` across renames, reorders and
/// save/load cycles, so modulation bindings and remote-control references
/// survive editing. Never derive meaning from the value.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Hash, PartialOrd, Ord)]
#[serde(transparent)]
pub struct Id(u64);

impl Id {
    /// Wraps a raw value.
    #[must_use]
    pub const fn new(raw: u64) -> Self {
        Self(raw)
    }

    /// The raw value, for serialisation and FFI.
    #[must_use]
    pub const fn raw(self) -> u64 {
        self.0
    }
}

impl std::fmt::Display for Id {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "#{}", self.0)
    }
}

/// Allocates unique [`Id`]s within one document.
///
/// Monotonic and never reuses a value, so a deleted object's id can't be
/// confused with a new one by a stale binding or a remote client.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(transparent)]
pub struct IdAllocator {
    next: u64,
}

impl IdAllocator {
    /// A fresh allocator. Ids start at 1; 0 is reserved as "none".
    #[must_use]
    pub const fn new() -> Self {
        Self { next: 1 }
    }

    /// Resumes allocation above every id already in use.
    #[must_use]
    pub fn resuming_after(highest_in_use: Id) -> Self {
        Self {
            next: highest_in_use.raw() + 1,
        }
    }

    /// Issues the next unused id.
    pub fn alloc(&mut self) -> Id {
        let id = Id(self.next);
        self.next += 1;
        id
    }
}

impl Default for IdAllocator {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_are_unique_and_monotonic() {
        let mut a = IdAllocator::new();
        let ids: Vec<_> = (0..5).map(|_| a.alloc()).collect();
        let mut sorted = ids.clone();
        sorted.dedup();
        assert_eq!(ids.len(), sorted.len(), "ids must be unique");
        assert!(ids.windows(2).all(|w| w[0] < w[1]), "ids must increase");
    }

    #[test]
    fn zero_is_never_allocated() {
        let mut a = IdAllocator::new();
        assert_ne!(a.alloc().raw(), 0);
    }

    #[test]
    fn resuming_does_not_reissue_existing_ids() {
        // A stale binding referring to #7 must never silently rebind to a new object.
        let mut a = IdAllocator::resuming_after(Id::new(7));
        assert_eq!(a.alloc(), Id::new(8));
    }

    #[test]
    fn id_serialises_transparently() {
        assert_eq!(serde_json::to_string(&Id::new(42)).unwrap(), "42");
    }
}
