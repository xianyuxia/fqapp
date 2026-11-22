use std::sync::Arc;

#[path = "crypto.rs"]
pub mod crypto;
#[path = "identity.rs"]
mod identity;
pub use identity::Device;

/// Session furnished by the browser's IndexedDB registration.
pub struct DevicePool {
    device: Device,
}

impl DevicePool {
    pub fn from_session(device: Device) -> Result<Arc<Self>, String> {
        if device.device_id.is_empty()
            || device.install_id.is_empty()
            || device.secret_key.is_empty()
        {
            return Err("browser session is incomplete".into());
        }
        Ok(Arc::new(Self { device }))
    }

    pub async fn get(&self) -> Result<Device, String> {
        Ok(self.device.clone())
    }

    pub async fn get_by_id(&self, device_id: &str) -> Result<Device, String> {
        if device_id == self.device.device_id {
            return self.get().await;
        }
        Err("device is not in the browser session".into())
    }

    pub async fn replace_failed(&self, _device_id: &str) -> Result<Device, String> {
        Err("browser session must be renewed by the browser".into())
    }

    pub async fn count(&self) -> usize {
        1
    }
}
