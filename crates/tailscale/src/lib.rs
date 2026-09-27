//! Host-testable helpers for the Kindle Tailscale package.
//! LIPC linking and process lifetime stay in `tsctl`.

pub mod lipc;

pub use lipc::*;
