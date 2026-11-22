const encode = new TextEncoder();
const decode = new TextDecoder();
let modulePromise;
let initialization;

function registrationModule() {
  modulePromise ??= (async () => {
    let wasm;
    const imports = {browser: {
      now_ms: () => BigInt(Date.now()),
      random_fill(pointer, length) {
        try {
          crypto.getRandomValues(new Uint8Array(wasm.memory.buffer, pointer, length));
          return 0;
        } catch {
          return 1;
        }
      },
    }};
    const response = await fetch(new URL('./fqapi_web_registration.wasm', import.meta.url));
    if (!response.ok) throw Error('注册模块加载失败');
    const {instance} = await WebAssembly.instantiate(await response.arrayBuffer(), imports);
    wasm = instance.exports;
    return wasm;
  })().catch(error => {
    modulePromise = undefined;
    throw error;
  });
  return modulePromise;
}

function invoke(wasm, name, input) {
  if (input) {
    const address = wasm.allocate(input.byteLength);
    new Uint8Array(wasm.memory.buffer, address, input.byteLength).set(input);
  }
  const address = wasm[name]();
  const result = JSON.parse(decode.decode(new Uint8Array(wasm.memory.buffer, address, wasm.result_len())));
  if (result.error) throw Error(result.error);
  return result;
}

export async function forwardRequest(relay, request, timeoutMs = 25000) {
  let binary = '';
  const body = request.body ?? [];
  for (let start = 0; start < body.length; start += 8192) {
    binary += String.fromCharCode(...body.slice(start, start + 8192));
  }
  const response = await fetch(relay, {
    method:'POST', credentials:'same-origin', redirect:'error',
    headers:{'Content-Type':'application/json'},
    body:JSON.stringify({...request, body:btoa(binary)}),
    signal:AbortSignal.timeout(timeoutMs),
  });
  const status = Number(response.headers.get('X-Relay-Upstream-Status'));
  if (!response.ok || status < 100 || status > 599) throw Error('代理请求失败（' + response.status + '）');
  const headers = {};
  for (const [name, value] of response.headers) {
    if (name.startsWith('x-relay-upstream-') && name !== 'x-relay-upstream-status') {
      headers[name.slice('x-relay-upstream-'.length)] = value;
    }
  }
  return {status, headers, body:new Uint8Array(await response.arrayBuffer())};
}

async function openDatabase() {
  return new Promise((resolve, reject) => {
    const open = indexedDB.open('shijinpu-web', 1);
    open.onupgradeneeded = () => open.result.createObjectStore('registration');
    open.onsuccess = () => resolve(open.result);
    open.onerror = () => reject(open.error);
  });
}

function storedSession(database, state) {
  return new Promise((resolve, reject) => {
    const transaction = database.transaction('registration', state ? 'readwrite' : 'readonly');
    const store = transaction.objectStore('registration');
    const request = state ? store.put(state, 'current') : store.get('current');
    transaction.oncomplete = () => resolve(request.result);
    transaction.onabort = () => reject(transaction.error);
  });
}

async function bootstrap(relay) {
  const database = await openDatabase();
  try {
    const saved = await storedSession(database);
    if (saved?.deviceId && saved?.installId && saved?.key && saved.cdid && saved.openudid) return saved;

    const wasm = await registrationModule();
    const step = async (request, parse) => {
      const response = await forwardRequest(relay, {...request, method:'POST'});
      if (response.status !== 200) throw Error('上游注册请求失败（' + response.status + '）');
      return invoke(wasm, parse, response.body);
    };
    const registration = invoke(wasm, 'prepare');
    const ids = await step(registration.request, 'parse');
    const input = encode.encode(JSON.stringify(ids));
    try {
      const alert = invoke(wasm, 'prepare_alert', input);
      await forwardRequest(relay, {...alert, method:'GET'}, 3000);
    } catch {
      // The alert check is optional. Continue to register the media key.
    }
    const keyRequest = invoke(wasm, 'prepare_key', input);
    const key = await step(keyRequest, 'parse_key');
    const session = {...ids, ...key, ...registration.identity};
    await storedSession(database, session);
    return session;
  } finally {
    database.close();
  }
}

export function initializeRegistration(relay) {
  initialization ??= (navigator.locks
    ? navigator.locks.request('shijinpu-registration', () => bootstrap(relay))
    : bootstrap(relay)
  ).catch(error => {
    initialization = undefined;
    throw error;
  });
  return initialization;
}
