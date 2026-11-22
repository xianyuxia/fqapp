let worker;
let nextRequest = 0;
const pending = new Map();

function connect() {
  if (worker) return worker;
  const connection = new Worker(new URL('./core-worker.mjs', import.meta.url), {type:'module'});
  connection.addEventListener('message', ({data}) => {
    const entry = pending.get(data.id);
    if (!entry) return;
    pending.delete(data.id);
    if (data.error) entry.reject(new Error(data.error));
    else entry.resolve(data);
  });
  connection.addEventListener('error', () => {
    if (worker !== connection) return;
    worker = undefined;
    connection.terminate();
    for (const entry of pending.values()) entry.reject(new Error('浏览器 Rust 内核启动失败'));
    pending.clear();
  });
  worker = connection;
  return worker;
}

globalThis.shijinpuCore = function (relay, path, query) {
  const connection = connect();
  const id = ++nextRequest;
  return new Promise((resolve, reject) => {
    pending.set(id, {resolve, reject});
    connection.postMessage({id, relay:new URL(relay, location.href).href, path, query});
  });
};

globalThis.shijinpuStorage = async function (key, action, value) {
  const database = await new Promise((resolve,reject) => {
    const open = indexedDB.open('shijinpu-local-data', 1);
    open.onupgradeneeded = () => open.result.createObjectStore('keys');
    open.onsuccess = () => resolve(open.result);
    open.onerror = () => reject(open.error);
  });
  try {
    return await new Promise((resolve,reject) => {
      const transaction = database.transaction('keys', action === 'read' ? 'readonly' : 'readwrite');
      const store = transaction.objectStore('keys');
      const request = action === 'read' ? store.get(key)
        : action === 'write' ? store.put(value,key)
        : store.delete(key);
      transaction.oncomplete = () => resolve(action === 'read' ? request.result ?? null : null);
      transaction.onabort = () => reject(transaction.error);
    });
  } finally {
    database.close();
  }
};
