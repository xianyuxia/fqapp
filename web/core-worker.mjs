import init, { initialize_web_core, web_request } from './wasm/fqapi_core.js';
import { initializeRegistration } from './registration.mjs';

let boot;

async function start(relay) {
  const [session] = await Promise.all([initializeRegistration(relay), init()]);
  initialize_web_core(relay, JSON.stringify({
    device_id: session.deviceId,
    install_id: session.installId,
    secret_key: session.key,
    cdid: session.cdid,
    openudid: session.openudid,
    registered_version_code: session.versionCode,
    platform: 'android',
    status: 'active',
    created_time: '',
    last_used: '',
    use_count: 0,
  }));
}

self.addEventListener('message', async ({data}) => {
  const {id, relay, path, query} = data;
  try {
    boot ??= start(relay).catch(error => {
      boot = undefined;
      throw error;
    });
    await boot;
    if (!path) {
      self.postMessage({id});
      return;
    }

    const response = await web_request(path, query);
    try {
      const body = response.body();
      self.postMessage({id, status:response.status(), contentType:response.content_type(), body}, [body.buffer]);
    } finally {
      response.free();
    }
  } catch (error) {
    self.postMessage({id, error:String(error.message ?? error)});
  }
});
