//! # photon-core
//!
//! Portable engine core for Photon. Consumed by the macOS shell (Swift + Metal)
//! and, later, by a separate Windows shell.
//!
//! ## The one hard rule
//!
//! **This crate contains no platform API and no graphics API.** Not Apple, not
//! Windows, not Metal, not wgpu, not FFmpeg. Platform capabilities are declared
//! here as *traits* ([`platform`]) and implemented in the shells.
//!
//! Enforced by `ci/check-portable.sh`, which checks the resolved dependency
//! graph (including renamed crates), source-level FFI, and a build for a
//! non-Apple target — and which self-tests by injecting a deliberate violation.
//!
//! Breaking this rule turns the Windows port into a rewrite, quietly, months
//! before anyone notices. See `docs/scaffold.md` §4.
//!
//! ## Stage
//!
//! **R0 — contracts and spikes only.** No renderer, no compositor, no I/O
//! adapters, no node graph. Types and traits here define the boundaries that
//! R1+ builds against.

#![forbid(unsafe_code)]
#![warn(missing_docs, clippy::all)]

pub mod beat;
pub mod budget;
pub mod clock;
pub mod codec;
pub mod doc;
pub mod graph;
pub mod ir;
pub mod learn;
pub mod modulation;
pub mod platform;
pub mod protocol;

/// Crate version, surfaced in telemetry and in saved documents.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
