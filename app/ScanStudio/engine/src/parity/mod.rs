//! Corpus-independent core of the Rust parity harness (PAR-01): shared
//! report/status types (`types`), 16-bit-safe TIFF/PNG image I/O
//! (`image_io`), and the per-module scoring functions (`scoring`). Plan
//! 13-02 adds `corpus` (corpus discovery/loading) and wires everything into
//! a CLI. Plan 14-02 adds `candidates` (candidate-generation glue for the
//! color module).

pub mod candidates;
pub mod corpus;
pub mod image_io;
pub mod scoring;
pub mod types;

pub use candidates::*;
pub use corpus::*;
pub use scoring::*;
pub use types::*;
