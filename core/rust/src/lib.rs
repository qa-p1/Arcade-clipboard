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
#[cfg(not(target_os = "ios"))]
mod discovery;
#[cfg(not(any(target_os = "android", target_os = "ios")))]
mod link;
#[cfg(not(any(target_os = "android", target_os = "ios")))]
mod link_consumer;
#[cfg(target_os = "linux")]
mod linux_login;
#[cfg(any(target_os = "macos", all(test, unix)))]
mod macos_install;
mod model;
mod payload;
#[cfg(not(any(target_os = "android", target_os = "ios")))]
mod portable_settings;
mod profile_lock;
mod relay_transport;
mod secret;
mod store;
mod transport;
#[cfg(any(target_os = "windows", test))]
mod windows_login;

pub use core::Core;

pub(crate) const VERSION: &str = match option_env!("ARCADE_RELEASE_VERSION") {
    Some(version) if !version.is_empty() => version,
    _ => env!("CARGO_PKG_VERSION"),
};

#[cfg(test)]
mod integration_tests;
