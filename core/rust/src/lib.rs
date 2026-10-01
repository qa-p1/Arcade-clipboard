/* AUTO INJECTED BY flutter_rust_bridge. This line may not be accurate, and you can change it according to your needs. */
//! Shared systems core for Arcade Clipboard.
//!
//! The Flutter boundary is deliberately small: [`api::call`] accepts one JSON
//! request and returns one JSON object. Clipboard text is encrypted before it
//! crosses a device connection and encrypted again at rest in SQLite.

mod frb_generated;

pub mod api;
mod core;
mod crypto;
mod discovery;
mod model;
mod payload;
mod profile_lock;
mod relay_transport;
mod secret;
mod store;
mod transport;

pub use core::Core;

#[cfg(test)]
mod integration_tests;
