use serde::{Deserialize, Serialize};

/// One registered device in the pool.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Device {
    pub device_id: String,
    pub install_id: String,
    pub secret_key: String,
    pub platform: String,
    pub status: String,
    pub created_time: String,
    pub last_used: String,
    pub use_count: i64,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub cdid: String,
    /// Per-installation OpenUDID, generated at registration. It is a device
    /// scoped identifier, so it must come from this device's own registration
    /// rather than a value baked into the source. `serde(default)` keeps pools
    /// written before this field existed loadable; `device_id` stands in until
    /// the device is registered again.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub openudid: String,
    /// The upstream `version_code` this device was registered with.
    ///
    /// It is what makes a changed identity observable: the pool retires the
    /// devices that were registered under the previous version instead of
    /// handing them out for a version they never claimed. `serde(default)`
    /// keeps pools written before this field existed loadable; those devices
    /// carry an empty value, which is treated as "unknown" and kept (see
    /// `DevicePool::build`).
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub registered_version_code: String,
}
