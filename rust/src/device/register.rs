//! Network side of device registration.

use serde_json::json;

use crate::device::Device;
use crate::sign::Manager;
use crate::upstream::http::{HttpTransport, API_BODY_LIMIT_BYTES};

use super::registration_wire::{
    body_head, decode_key, decode_registration, prepare_key, prepare_registration,
};
pub use super::registration_wire::{
    current_version_code, dev_info_with, go_query_escape, md5_hex, new_dev_info,
    set_upstream_identity, sorted_query, DevInfo,
};

pub struct Registrar {
    http: HttpTransport,
    sign: Manager,
    /// Offline test seam, see `UpstreamClient::with_mock_origin`.
    mock_origin: Option<String>,
}

impl Registrar {
    pub fn new() -> Result<Self, String> {
        Self::build(None)
    }

    pub fn with_mock_origin(origin: impl Into<String>) -> Result<Self, String> {
        Self::build(Some(origin.into()))
    }

    fn build(mock_origin: Option<String>) -> Result<Self, String> {
        let mut sign = Manager::new();
        // registerKey signs with x-gorgon enabled.
        sign.enable_gorgon = true;
        Ok(Registrar {
            http: HttpTransport::new(30)?,
            sign,
            mock_origin,
        })
    }

    fn target(&self, url: &str) -> String {
        let Some(origin) = self.mock_origin.as_deref() else {
            return url.to_string();
        };
        match url::Url::parse(url) {
            Ok(parsed) => {
                let origin = origin.trim_end_matches('/');
                let mut out = format!("{origin}{}", parsed.path());
                if let Some(q) = parsed.query() {
                    out.push('?');
                    out.push_str(q);
                }
                out
            }
            Err(_) => url.to_string(),
        }
    }

    /// Full registration: device_register -> app_alert_check -> privilege
    /// activation -> registerkey.
    pub async fn register(&self) -> Result<Device, String> {
        let di = new_dev_info();

        let (device_id, install_id) = self
            .device_register(&di)
            .await
            .map_err(|e| format!("device_register: {e}"))?;

        let _ = self.app_alert_check(&di, &device_id, &install_id).await;
        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
        let _ = self
            .activate_premium(&device_id, &install_id, &di.device_type)
            .await;

        let secret_key = match self.register_key(&device_id, &install_id).await {
            Ok(k) => k,
            Err(e) => {
                // The device is still returned, but with an empty key it can
                // decrypt nothing. The reason must reach the log: this used to
                // go to a no-op `log_line`, which made the degradation
                // invisible in `rust.log` and `logcat` alike.
                log::warn!("registerKey failed (secret_key will be empty): {e}");
                String::new()
            }
        };

        let now = crate::timeutil::now_string();
        Ok(Device {
            device_id,
            install_id,
            secret_key,
            platform: "android".into(),
            status: "active".into(),
            created_time: now.clone(),
            last_used: now,
            use_count: 0,
            cdid: di.cdid,
            openudid: di.openudid,
            // The version this device was registered with. A later identity
            // change retires the device instead of handing it out.
            registered_version_code: di.version_code.clone(),
        })
    }

    async fn device_register(&self, di: &DevInfo) -> Result<(String, String), String> {
        let request = prepare_registration(di)?;
        let resp = self
            .http
            .request_with_limit(
                "POST",
                &self.target(&request.url),
                &request.headers,
                Some(request.body),
                None,
                Some(API_BODY_LIMIT_BYTES),
            )
            .await
            .map_err(|e| format!("{e:?}"))?;
        if resp.status != 200 {
            return Err(format!("HTTP {}", resp.status));
        }
        decode_registration(&resp.body)
    }

    async fn app_alert_check(
        &self,
        di: &DevInfo,
        device_id: &str,
        install_id: &str,
    ) -> Result<(), String> {
        let params = di.url_params(&[
            ("device_id".to_string(), device_id.to_string()),
            ("iid".to_string(), install_id.to_string()),
        ]);
        let query = sorted_query(&params);
        let req_url = format!("https://ichannel.snssdk.com/service/2/app_alert_check/?{query}");

        let mut headers = vec![
            (
                "content-type".to_string(),
                "application/octet-stream;tt-data=a".to_string(),
            ),
            ("accept-encoding".to_string(), "gzip".to_string()),
            ("log-encode-type".to_string(), "gzip".to_string()),
            ("x-tt-request-tag".to_string(), "t=0;n=1".to_string()),
            (
                "x-ss-req-ticket".to_string(),
                crate::timeutil::now_millis().to_string(),
            ),
            ("sdk-version".to_string(), "2".to_string()),
            ("passport-sdk-version".to_string(), di.version_code.clone()),
            (
                "x-vc-bdturing-sdk-version".to_string(),
                "3.7.4.cn".to_string(),
            ),
            ("user-agent".to_string(), di.user_agent.clone()),
            ("host".to_string(), "ichannel.snssdk.com".to_string()),
            ("connection".to_string(), "Keep-Alive".to_string()),
        ];
        for (k, v) in self.sign.generate_headers(&query, None) {
            headers.retain(|(hk, _)| !hk.eq_ignore_ascii_case(&k));
            headers.push((k, v));
        }

        let _ = self
            .http
            .request_with_limit(
                "GET",
                &self.target(&req_url),
                &headers,
                None,
                None,
                Some(API_BODY_LIMIT_BYTES),
            )
            .await;
        Ok(())
    }

    async fn activate_premium(
        &self,
        device_id: &str,
        install_id: &str,
        device_type: &str,
    ) -> Result<(), String> {
        let mut parts = vec![
            "aid=1967".to_string(),
            "app_name=novelapp".to_string(),
            "channel=0".to_string(),
            format!("device_id={device_id}"),
            "device_platform=android".to_string(),
            format!("device_type={device_type}"),
            format!("iid={install_id}"),
            "os_version=0".to_string(),
            "version_code=61532".to_string(),
            "version_name=6.1.5.32".to_string(),
            "manifest_version_code=61532".to_string(),
            "update_version_code=61532".to_string(),
        ];
        parts.sort();
        let req_url = format!(
            "https://api5-normal-sinfonlinea.fqnovel.com/reading/user/privilege/add/v/?{}",
            parts.join("&")
        );

        let body = json!({
            "add_count_daily": 0,
            "amount": 2592000,
            "privilege_id": 7210376203117531962i64,
            "from": 8,
            "unique_key": crate::timeutil::now_millis().to_string(),
        });
        let body_json = serde_json::to_vec(&body).map_err(|e| e.to_string())?;

        let _ = self
            .http
            .request_with_limit(
                "POST",
                &self.target(&req_url),
                &[],
                Some(body_json),
                None,
                Some(API_BODY_LIMIT_BYTES),
            )
            .await;
        Ok(())
    }

    async fn register_key(&self, device_id: &str, install_id: &str) -> Result<String, String> {
        let request = prepare_key(&self.sign, device_id, install_id)?;
        let mut last_err = String::new();
        for _attempt in 0..3 {
            let resp = match self
                .http
                .request_with_limit(
                    "POST",
                    &self.target(&request.url),
                    &request.headers,
                    Some(request.body.clone()),
                    None,
                    Some(API_BODY_LIMIT_BYTES),
                )
                .await
            {
                Ok(r) => r,
                Err(e) => {
                    last_err = format!("{e:?}");
                    tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                    continue;
                }
            };
            if resp.status != 200 {
                last_err = format!("HTTP {} body={}", resp.status, body_head(&resp.body));
                tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                continue;
            }

            match decode_key(&resp.body) {
                Ok(key) => return Ok(key),
                Err(error) => {
                    last_err = error;
                    tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                }
            }
        }
        Err(last_err)
    }
}
