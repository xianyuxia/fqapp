#![allow(dead_code)]

extern crate self as url;
pub use form_urlencoded;

#[path = "../../src/config.rs"]
mod config;
#[path = "../../src/crypto.rs"]
mod crypto;
mod device;
#[path = "../../src/device/crypto.rs"]
pub mod device_crypto;
#[path = "../../src/json.rs"]
mod json;
#[path = "../../src/device/registration_wire.rs"]
mod registration_wire;
#[path = "../../src/sign/mod.rs"]
mod sign;

mod timeutil {
    pub fn now_millis() -> i64 {
        unsafe { super::now_ms() }
    }

    pub fn now_secs() -> i64 {
        now_millis() / 1000
    }
}

#[link(wasm_import_module = "browser")]
extern "C" {
    fn random_fill(pointer: *mut u8, length: usize) -> i32;
    fn now_ms() -> i64;
}

fn browser_random(output: &mut [u8]) -> Result<(), getrandom::Error> {
    let status = unsafe { random_fill(output.as_mut_ptr(), output.len()) };
    if status == 0 {
        Ok(())
    } else {
        Err(getrandom::Error::UNSUPPORTED)
    }
}
getrandom::register_custom_getrandom!(browser_random);

use serde::Serialize;
use std::cell::RefCell;

thread_local! {
    static INPUT: RefCell<Vec<u8>> = const { RefCell::new(Vec::new()) };
    static OUTPUT: RefCell<Vec<u8>> = const { RefCell::new(Vec::new()) };
    static DEVICE: RefCell<Option<registration_wire::DevInfo>> = const { RefCell::new(None) };
}

fn emit<T: Serialize>(result: Result<T, &'static str>) -> *const u8 {
    OUTPUT.with(|output| {
        let value = match result {
            Ok(value) => serde_json::to_vec(&value),
            Err(error) => serde_json::to_vec(&serde_json::json!({ "error": error })),
        };
        let mut bytes = output.borrow_mut();
        *bytes = value.expect("serializable registration response");
        bytes.as_ptr()
    })
}

#[no_mangle]
pub extern "C" fn result_len() -> usize {
    OUTPUT.with(|output| output.borrow().len())
}

#[no_mangle]
pub extern "C" fn allocate(size: usize) -> *mut u8 {
    INPUT.with(|input| {
        let mut bytes = input.borrow_mut();
        bytes.resize(size, 0);
        bytes.as_mut_ptr()
    })
}

#[no_mangle]
pub extern "C" fn prepare() -> *const u8 {
    let device = registration_wire::new_dev_info();
    DEVICE.with(|slot| *slot.borrow_mut() = Some(device.clone()));
    emit(
        registration_wire::prepare_registration(&device)
            .map(|request| {
                serde_json::json!({
                    "request": request,
                    "identity": {
                        "cdid": device.cdid,
                        "openudid": device.openudid,
                        "versionCode": device.version_code,
                    },
                })
            })
            .map_err(|_| "could not build registration request"),
    )
}

#[no_mangle]
pub extern "C" fn parse() -> *const u8 {
    let result = INPUT.with(|input| {
        registration_wire::decode_registration(&input.borrow())
            .map(|(device_id, install_id)| serde_json::json!({ "deviceId": device_id, "installId": install_id }))
            .map_err(|_| "missing or invalid registration IDs")
    });
    emit(result)
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct RegistrationIds {
    device_id: String,
    install_id: String,
}

#[no_mangle]
pub extern "C" fn prepare_alert() -> *const u8 {
    let result = INPUT.with(|input| {
        let ids: RegistrationIds =
            serde_json::from_slice(&input.borrow()).map_err(|_| "invalid registration IDs")?;
        let device = DEVICE
            .with(|slot| slot.borrow_mut().take())
            .ok_or("missing registration device")?;
        let query = registration_wire::sorted_query(&device.url_params(&[
            ("device_id".into(), ids.device_id),
            ("iid".into(), ids.install_id),
        ]));
        let mut headers: Vec<(String, String)> = vec![
            (
                "content-type".into(),
                "application/octet-stream;tt-data=a".into(),
            ),
            ("log-encode-type".into(), "gzip".into()),
            ("x-tt-request-tag".into(), "t=0;n=1".into()),
            ("x-ss-req-ticket".into(), timeutil::now_millis().to_string()),
            ("sdk-version".into(), "2".into()),
            ("passport-sdk-version".into(), device.version_code),
            ("x-vc-bdturing-sdk-version".into(), "3.7.4.cn".into()),
            ("user-agent".into(), device.user_agent),
        ];
        for (name, value) in sign::Manager::new().generate_headers(&query, None) {
            headers.retain(|(header, _)| !header.eq_ignore_ascii_case(&name));
            headers.push((name, value));
        }
        Ok(registration_wire::RegistrationRequest {
            url: format!("https://ichannel.snssdk.com/service/2/app_alert_check/?{query}"),
            headers,
            body: Vec::new(),
        })
    });
    emit(result)
}

#[no_mangle]
pub extern "C" fn prepare_key() -> *const u8 {
    let result = INPUT.with(|input| {
        let ids: RegistrationIds =
            serde_json::from_slice(&input.borrow()).map_err(|_| "invalid registration IDs")?;
        let mut signer = sign::Manager::new();
        signer.enable_gorgon = true;
        registration_wire::prepare_key(&signer, &ids.device_id, &ids.install_id)
            .map_err(|_| "could not build key request")
    });
    emit(result)
}

#[no_mangle]
pub extern "C" fn parse_key() -> *const u8 {
    let result = INPUT.with(|input| {
        registration_wire::decode_key(&input.borrow())
            .map(|key| serde_json::json!({ "key": key }))
            .map_err(|_| "invalid key response")
    });
    emit(result)
}
