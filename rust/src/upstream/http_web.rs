//! Browser fetch transport. TLS, sockets and HTTP compression are browser-owned.
use std::{
    sync::{Arc, OnceLock},
    time::Duration,
};

use base64::Engine;
use futures::{channel::oneshot, StreamExt};
use serde_json::json;

use super::http::{RawResponse, TransportError, API_BODY_LIMIT_BYTES};

static RELAY: OnceLock<String> = OnceLock::new();

pub fn configure_web_relay(url: String) -> Result<(), String> {
    let parsed = url::Url::parse(&url).map_err(|error| error.to_string())?;
    let loopback = parsed.scheme() == "http"
        && matches!(parsed.host_str(), Some("localhost" | "127.0.0.1" | "[::1]"));
    if (parsed.scheme() != "https" && !loopback)
        || !parsed.username().is_empty()
        || parsed.password().is_some()
        || parsed.fragment().is_some()
    {
        return Err("invalid browser relay URL".into());
    }
    if RELAY.get() == Some(&url) {
        return Ok(());
    }
    RELAY
        .set(url)
        .map_err(|_| "browser relay already configured".into())
}

pub struct HttpTransport {
    timeout: Duration,
}

impl HttpTransport {
    pub fn new(timeout_secs: u64) -> Result<Self, String> {
        Ok(Self {
            timeout: Duration::from_secs(timeout_secs),
        })
    }

    pub async fn request(
        &self,
        method: &str,
        url: &str,
        headers: &[(String, String)],
        body: Option<Vec<u8>>,
        timeout: Option<Duration>,
    ) -> Result<RawResponse, TransportError> {
        self.request_with_limit(method, url, headers, body, timeout, None)
            .await
    }

    pub async fn request_bounded(
        &self,
        method: &str,
        url: &str,
        headers: &[(String, String)],
        max_bytes: usize,
    ) -> Result<RawResponse, TransportError> {
        self.request_with_limit(method, url, headers, None, None, Some(max_bytes))
            .await
    }

    pub async fn request_body_bounded(
        &self,
        method: &str,
        url: &str,
        headers: &[(String, String)],
        body: Vec<u8>,
        max_bytes: usize,
    ) -> Result<RawResponse, TransportError> {
        self.request_with_limit(method, url, headers, Some(body), None, Some(max_bytes))
            .await
    }

    pub async fn request_with_limit(
        &self,
        method: &str,
        url: &str,
        headers: &[(String, String)],
        body: Option<Vec<u8>>,
        timeout: Option<Duration>,
        body_limit: Option<usize>,
    ) -> Result<RawResponse, TransportError> {
        let relay = RELAY
            .get()
            .ok_or_else(|| network("browser relay has not been configured"))?;
        let timeout = super::budget::cap_timeout(timeout.unwrap_or(self.timeout));
        if timeout.is_zero() {
            return Err(network("request deadline exceeded"));
        }
        let limit = body_limit.unwrap_or(API_BODY_LIMIT_BYTES);
        let payload = json!({
            "method": method,
            "url": url,
            "headers": headers,
            "body": body.map(|bytes| base64::engine::general_purpose::STANDARD.encode(bytes)),
        });
        let (mut tx, rx) = oneshot::channel();
        // Await only owned Rust data so shared endpoint futures retain their Send contract.
        wasm_bindgen_futures::spawn_local(async move {
            let future = fetch(relay, payload.to_string(), timeout, limit);
            let result =
                futures::future::select(Box::pin(future), Box::pin(tx.cancellation())).await;
            if let futures::future::Either::Left((response, cancellation)) = result {
                drop(cancellation);
                let _ = tx.send(response);
            }
        });
        rx.await.map_err(|_| network("browser fetch canceled"))?
    }
}

fn network(message: impl Into<String>) -> TransportError {
    TransportError::Network(message.into())
}

async fn fetch(
    relay: &str,
    payload: String,
    timeout: Duration,
    limit: usize,
) -> Result<RawResponse, TransportError> {
    let response = reqwest::Client::new()
        .post(relay)
        .timeout(timeout)
        .header("Content-Type", "application/json")
        .body(payload)
        .send()
        .await
        .map_err(|error| network(error.to_string()))?;
    if !response.status().is_success() {
        return Err(network(format!(
            "browser relay returned {}",
            response.status()
        )));
    }
    let status = response
        .headers()
        .get("x-relay-upstream-status")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse::<u16>().ok())
        .filter(|status| (100..=599).contains(status))
        .ok_or_else(|| network("browser relay omitted upstream status"))?;
    let headers = response
        .headers()
        .iter()
        .filter_map(|(name, value)| {
            let key = name.as_str().strip_prefix("x-relay-upstream-")?;
            if key == "status" {
                return None;
            }
            Some((key.to_owned(), value.to_str().ok()?.to_owned()))
        })
        .collect();
    let mut stream = Box::pin(response.bytes_stream());
    let mut body = Vec::new();
    while let Some(chunk) = stream.next().await {
        let bytes = chunk.map_err(|error| network(error.to_string()))?;
        if bytes.len() > limit.saturating_sub(body.len()) {
            return Err(TransportError::TooLarge(format!(
                "response exceeds {limit} bytes"
            )));
        }
        body.extend_from_slice(&bytes);
    }
    if body.starts_with(&[0x1f, 0x8b]) {
        body = match crate::crypto::gunzip_capped(&body, limit) {
            Ok(decoded) => decoded,
            Err(crate::crypto::GunzipError::OverLimit) => {
                return Err(TransportError::TooLarge(format!(
                    "gunzip output exceeds {limit} bytes"
                )))
            }
            Err(crate::crypto::GunzipError::Corrupt(_)) => body,
        }
    }
    Ok(RawResponse {
        status,
        headers,
        body,
    })
}

// Account cookies never cross the browser relay.
pub fn account_transport() -> Result<Arc<HttpTransport>, String> {
    Err("account transport is unavailable in the browser".into())
}
