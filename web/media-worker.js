const core = import('./wasm/fqapi_core.js').then(async module => {
  await module.default();
  return module;
});

const maxBytes = 64 * 1024 * 1024;

self.onmessage = async ({data}) => {
  try {
    const [response, {decrypt_media}] = await Promise.all([
      fetch(data.url, {credentials:'omit',referrerPolicy:'no-referrer'}),
      core,
    ]);
    if (!response.ok || !response.body) throw new Error('媒体请求失败（' + response.status + '）');
    const reader = response.body.getReader();
    let total = 0;
    const parts = [];
    for (;;) {
      const {done,value} = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maxBytes) {
        await reader.cancel();
        throw new Error('媒体超过浏览器当前缓冲上限');
      }
      parts.push(value);
    }
    const bytes = new Uint8Array(total);
    let next = 0;
    for (const part of parts) {
      bytes.set(part,next);
      next += part.byteLength;
    }
    const clear = decrypt_media(bytes,data.key);
    const blob = new Blob([clear], {type:data.audioOnly ? 'audio/mp4' : 'video/mp4'});
    self.postMessage({blob});
  } catch (error) {
    self.postMessage({error:String(error.message ?? error)});
  }
};
