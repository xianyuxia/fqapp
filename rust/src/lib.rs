// fqapi_core - the Rust native core for the fqapp Android client.
//
// NOTE: flutter_rust_bridge must be able to find its generated module
// declaration in this file; it is declared explicitly below so code generation
// is a no-op on lib.rs. Keep this file free of inner (`//!`) crate docs: the
// generator inserts its declaration as the first line, and an inner doc comment
// after an item is a compile error (E0753).
//
// Layering:
//   api       - flutter_rust_bridge surface (transport for the Flutter app)
//   dispatch  - the single request dispatcher shared by FFI and loopback HTTP
//   endpoints - route table and business handlers
//   upstream  - signed HTTP access, device rotation, DH/CM key exchange
//   device    - persistent device pool + registration
//   sign      - request signing primitives
//
// See docs/migration/rust-migration-contracts.md for the behaviour contract and
// docs/rust-migration-progress.md for the current verification state.

#[cfg(not(target_arch = "wasm32"))]
pub mod api;
pub mod config;
pub mod core_log;
pub mod crypto;
#[cfg(not(target_arch = "wasm32"))]
pub mod device;
#[cfg(target_arch = "wasm32")]
#[path = "device/web.rs"]
pub mod device;
pub mod dispatch;
pub mod endpoints;
pub mod error;
pub mod filter;
pub mod json;
#[cfg(not(target_arch = "wasm32"))]
mod network;
#[cfg(not(target_arch = "wasm32"))]
pub mod server;
pub mod sign;
#[cfg(not(target_arch = "wasm32"))]
pub mod static_files;
pub mod timeutil;
mod runtime;
pub mod upstream;

#[cfg(not(target_arch = "wasm32"))]
mod frb_generated;

#[cfg(test)]
mod network_proxy_tests;

#[cfg(any(target_os = "windows", target_os = "linux"))]
mod desktop_fetch;
#[cfg(any(target_os = "windows", target_os = "linux"))]
mod desktop_media;

#[cfg(target_arch = "wasm32")]
mod web;
