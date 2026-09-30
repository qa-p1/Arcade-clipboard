//! Shared systems core for Arcade Clipboard.
//!
//! The Flutter boundary is deliberately small: [`api::call`] accepts one JSON
//! request and returns one JSON object. Clipboard text is encrypted before it
//! crosses a device connection and encrypted again at rest in SQLite.

pub mod api;
mod core;
mod crypto;
mod model;
mod profile_lock;
mod secret;
mod store;
mod transport;

pub use core::Core;

#[cfg(test)]
mod integration_tests;
