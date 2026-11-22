//! Raw HTTP response contract used by native and browser transports.

/// Response-body cap for JSON/API calls (P2-12). The video download path
/// passes its own per-file bound instead, so API callers all share one cap.
pub const API_BODY_LIMIT_BYTES: usize = 64 * 1024 * 1024;

#[derive(Debug, Clone)]
pub struct RawResponse {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl RawResponse {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }
}

#[derive(Debug, Clone)]
pub enum TransportError {
    /// Connection-level failure (Go: `http.Client.Do` error).
    Network(String),
    /// A *local* size limit was hit (caller cap, gunzip cap). This is not a
    /// transport failure and must not be read as one: callers rotate a pooled
    /// device on `Network`, and a response that is simply too big says nothing
    /// about the device.
    TooLarge(String),
}

#[cfg(not(target_arch = "wasm32"))]
pub use super::http_native::{account_transport, HttpTransport};

#[cfg(target_arch = "wasm32")]
pub use super::http_web::{account_transport, configure_web_relay, HttpTransport};
