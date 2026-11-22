use std::sync::{Arc, OnceLock};

use wasm_bindgen::prelude::*;

use crate::{
    config::Config,
    device::{Device, DevicePool},
    dispatch::{self, Request},
    endpoints::{Ctx, Server},
    filter::FilterManager,
    sign::Manager,
    upstream::{http::configure_web_relay, UpstreamClient},
};

static SERVER: OnceLock<Server> = OnceLock::new();

#[wasm_bindgen]
pub fn initialize_web_core(relay: String, device_json: &str) -> Result<(), JsError> {
    if SERVER.get().is_some() {
        return Ok(());
    }
    let device: Device =
        serde_json::from_str(device_json).map_err(|_| JsError::new("invalid browser session"))?;
    let pool = DevicePool::from_session(device).map_err(|error| JsError::new(&error))?;
    configure_web_relay(relay).map_err(|error| JsError::new(&error))?;
    let up = UpstreamClient::new(Arc::clone(&pool), Manager::new())
        .map_err(|error| JsError::new(&error))?;
    let context = Ctx {
        up: Arc::new(up),
        pool,
        cfg: Arc::new(Config::default()),
        src_dir: String::new(),
        filters: Arc::new(FilterManager::default()),
    };
    SERVER
        .set(Server::new(Arc::new(context)))
        .map_err(|_| JsError::new("browser core already initialized"))
}

#[wasm_bindgen]
pub struct WebResponse {
    status: u16,
    content_type: String,
    body: Vec<u8>,
}

#[wasm_bindgen]
impl WebResponse {
    pub fn status(&self) -> u16 {
        self.status
    }

    pub fn content_type(&self) -> String {
        self.content_type.clone()
    }

    pub fn body(&self) -> Vec<u8> {
        self.body.clone()
    }
}

#[wasm_bindgen]
pub async fn web_request(path: String, query: String) -> Result<WebResponse, JsError> {
    let server = SERVER
        .get()
        .ok_or_else(|| JsError::new("browser core is not initialized"))?;
    if !path.starts_with("/api/v1/") {
        return Err(JsError::new("invalid API path"));
    }
    let request = Request {
        method: "GET".to_owned(),
        path,
        query,
        ..Request::default()
    };
    let response = crate::upstream::budget::within(
        crate::upstream::budget::HTTP_REQUEST_TIMEOUT,
        dispatch::dispatch(server, &request),
    )
    .await
    .map_err(|()| JsError::new("browser request deadline exceeded"))?;
    let status = response.status;
    let content_type = response.content_type.clone();
    let body = response
        .into_bytes()
        .await
        .map_err(|error| JsError::new(&error))?;
    Ok(WebResponse {
        status,
        content_type,
        body,
    })
}

#[wasm_bindgen]
pub fn decrypt_media(mut bytes: Vec<u8>, key: &str) -> Result<Vec<u8>, JsError> {
    let key = hex::decode(key).map_err(|_| JsError::new("invalid media key"))?;
    if key.len() != 16 {
        return Err(JsError::new("invalid media key length"));
    }
    crate::endpoints::video::decrypt_cenc_mp4(&mut bytes, &key)
        .map_err(|error| JsError::new(&error))?;
    Ok(bytes)
}

#[wasm_bindgen]
pub struct MediaRangeDecryptor {
    index: crate::endpoints::video::CencIndex,
    key: Vec<u8>,
    length: u64,
}

#[wasm_bindgen]
impl MediaRangeDecryptor {
    #[wasm_bindgen(constructor)]
    pub fn new(
        moov: &[u8],
        offset: u64,
        length: u64,
        key: &str,
    ) -> Result<MediaRangeDecryptor, JsError> {
        let key = hex::decode(key).map_err(|_| JsError::new("invalid media key"))?;
        if key.len() != 16
            || offset
                .checked_add(moov.len() as u64)
                .is_none_or(|end| end > length)
        {
            return Err(JsError::new("invalid media index inputs"));
        }
        let index = crate::endpoints::video::build_cenc_index(moov, offset, length)
            .map_err(|error| JsError::new(&error))?
            .ok_or_else(|| JsError::new("media has no CENC index"))?;
        Ok(Self { index, key, length })
    }

    pub fn decrypt(&self, mut bytes: Vec<u8>, offset: u64) -> Result<Vec<u8>, JsError> {
        if offset
            .checked_add(bytes.len() as u64)
            .is_none_or(|end| end > self.length)
        {
            return Err(JsError::new("media bytes outside file"));
        }
        crate::endpoints::video::apply_cenc_index(&mut bytes, offset, &self.index, &self.key)
            .map_err(|error| JsError::new(&error))?;
        Ok(bytes)
    }
}
