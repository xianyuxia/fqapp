const workerUrl = new URL('./media-range-sw.mjs', import.meta.url);
let activation;
const openPaths = new Set();

function waitForController() {
  if (navigator.serviceWorker.controller?.scriptURL === workerUrl.href) {
    return Promise.resolve(navigator.serviceWorker.controller);
  }
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      navigator.serviceWorker.removeEventListener('controllerchange', check);
      reject(new Error('媒体 Service Worker 未接管页面'));
    }, 8000);
    function check() {
      const controller = navigator.serviceWorker.controller;
      if (controller?.scriptURL !== workerUrl.href) return;
      clearTimeout(timeout);
      navigator.serviceWorker.removeEventListener('controllerchange', check);
      resolve(controller);
    }
    navigator.serviceWorker.addEventListener('controllerchange', check);
    check();
  });
}

function activate() {
  let timer;
  const deadline = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error('Media service worker activation timed out')), 5000);
  });
  const ready = navigator.serviceWorker.register(workerUrl, {type: 'module'})
    .then(waitForController);
  return Promise.race([ready, deadline]).finally(() => clearTimeout(timer));
}

async function open(url, key, audioOnly) {
  activation ??= activate().catch(error => { activation = null; throw error; });
  const controller = await activation;
  const channel = new MessageChannel();
  try {
    return await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error('分段播放会话未响应')), 7500);
      channel.port1.onmessage = ({data}) => {
        clearTimeout(timeout);
        if (data.path) {
          openPaths.add(data.path);
          resolve(data.path);
        }
        else reject(new Error(data.error));
      };
      controller.postMessage({action: 'open', url, key, audioOnly}, [channel.port2]);
    });
  } finally {
    channel.port1.close();
  }
}

function close(path) {
  if (!openPaths.delete(path)) return;
  navigator.serviceWorker.controller?.postMessage({action: 'close', id: path.split('/').pop()});
}

addEventListener('pagehide', event => {
  if (!event.persisted) for (const path of openPaths) close(path);
});

globalThis.shijinpuOpenMediaRange = open;
globalThis.shijinpuCloseMediaRange = close;
