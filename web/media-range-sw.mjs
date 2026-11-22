import init, {MediaRangeDecryptor} from './wasm/fqapi_core.js';

const pathPrefix = new URL('__pwa_media__/', self.registration.scope).pathname;
const sessions = new Map();
const probeBytes = 128 * 1024;
const maxMoovBytes = 8 * 1024 * 1024;
let core;

self.addEventListener('install', event => event.waitUntil(self.skipWaiting()));
self.addEventListener('activate', event => event.waitUntil(self.clients.claim()));

self.addEventListener('message', event => {
  const {action, id, url, key, audioOnly} = event.data ?? {};
  if (action === 'close') {
    const session = sessions.get(id);
    if (!session || session.owner !== event.source?.id) return;
    sessions.delete(id);
    session.lifetime.abort();
    session.decryptor?.free();
    return;
  }
  const port = event.ports[0];
  if (action !== 'open' || !port || !event.source?.id) return;
  try {
    const media = new URL(url);
    if (media.protocol !== 'https:' || media.username || media.password ||
        !/^[0-9a-f]{32}$/i.test(key)) throw new Error('invalid media session');
    const session = {
      url: media.href, key, owner: event.source.id, lifetime: new AbortController(),
      mime: audioOnly ? 'audio/mp4' : 'video/mp4',
    };
    session.probeSignal = AbortSignal.any([session.lifetime.signal, AbortSignal.timeout(6000)]);
    event.waitUntil((async () => {
      try {
        await prepare(session);
        session.probeSignal.throwIfAborted();
        const id = crypto.randomUUID();
        sessions.set(id, session);
        port.postMessage({path: pathPrefix + id});
      } catch {
        session.lifetime.abort();
        session.decryptor?.free();
        port.postMessage({error: '媒体分段读取不可用'});
      }
    })());
  } catch {
    port.postMessage({error: '无法创建分段播放会话'});
  }
});

self.addEventListener('fetch', event => {
  const url = new URL(event.request.url);
  if (url.origin !== self.location.origin || !url.pathname.startsWith(pathPrefix)) return;
  event.respondWith((async () => {
    const session = sessions.get(url.pathname.slice(pathPrefix.length));
    if (!session || (event.clientId && session.owner !== event.clientId)) {
      return new Response(null, {status: 404});
    }
    try {
      return await respond(session, event.request);
    } catch (error) {
      if (!session.lifetime.signal.aborted) console.warn('分段媒体请求失败', error.message);
      return new Response(null, {status: 502});
    }
  })());
});

async function fetchRange(session, start, end, signal, length) {
  const response = await fetch(session.url, {
    headers: {Range: 'bytes=' + start + '-' + end},
    credentials: 'omit', referrerPolicy: 'no-referrer', signal,
  });
  const range = /^bytes (\d+)-(\d+)\/(\d+)$/.exec(response.headers.get('Content-Range') ?? '');
  const total = range ? Number(range[3]) : 0;
  if (response.status !== 206 || !response.body || !Number.isSafeInteger(total) ||
      total <= start || (length !== undefined && total !== length) ||
      Number(range[1]) !== start || Number(range[2]) !== Math.min(end, total - 1)) {
    await response.body?.cancel();
    throw new Error('CDN 未返回请求的字节区间');
  }
  return {response, total};
}

async function readRange(session, start, end, length) {
  const {response, total} = await fetchRange(session, start, end, session.probeSignal, length);
  const bytes = new Uint8Array(await response.arrayBuffer());
  if (bytes.length !== Math.min(end + 1, total) - start) throw new Error('媒体索引长度错误');
  return {bytes, total};
}

async function prepare(session) {
  core ??= init().catch(error => { core = null; throw error; });
  const [{bytes: prefix, total}] = await Promise.all([
    readRange(session, 0, probeBytes - 1), core,
  ]);
  for (let offset = 0, boxes = 0; offset + 8 <= total && boxes < 64; boxes++) {
    const headerEnd = Math.min(offset + 16, total);
    const header = headerEnd <= prefix.length
      ? prefix.subarray(offset, headerEnd)
      : (await readRange(session, offset, headerEnd - 1, total)).bytes;
    const view = new DataView(header.buffer, header.byteOffset, header.byteLength);
    const shortSize = view.getUint32(0);
    const size = shortSize === 1 ? Number(view.getBigUint64(8)) : shortSize || total - offset;
    if (!Number.isSafeInteger(size) || size < (shortSize === 1 ? 16 : 8) || size > total - offset) {
      throw new Error('无效的 MP4 box 长度');
    }
    if (view.getUint32(4) === 0x6d6f6f76) {
      if (size > maxMoovBytes) throw new Error('MP4 索引过大');
      const moov = offset + size <= prefix.length
        ? prefix.subarray(offset, offset + size)
        : (await readRange(session, offset, offset + size - 1, total)).bytes;

      session.lifetime.signal.throwIfAborted();
      session.decryptor = new MediaRangeDecryptor(moov, BigInt(offset), BigInt(total), session.key);
      session.prefix = prefix;
      session.length = total;
      return;
    }
    offset += size;
  }
  throw new Error('未找到 MP4 索引');
}

async function respond(session, request) {
  const {length, mime, prefix, lifetime} = session;
  const headers = new Headers({
    'Accept-Ranges': 'bytes', 'Content-Type': mime, 'Cache-Control': 'no-store',
  });
  if (request.method !== 'GET' && request.method !== 'HEAD') return new Response(null, {status: 405});
  const value = request.headers.get('Range');
  let start = 0;
  let end = length - 1;
  if (value) {
    const range = /^bytes=(\d*)-(\d*)$/.exec(value);
    if (range && (range[1] || range[2])) {
      if (range[1]) {
        start = Number(range[1]);
        if (range[2]) end = Math.min(Number(range[2]), end);
      } else {
        start = Math.max(0, length - Number(range[2]));
      }
    } else {
      start = length;
    }
    if (!Number.isSafeInteger(start) || start >= length || end < start) {
      headers.set('Content-Range', 'bytes */' + length);
      return new Response(null, {status: 416, headers});
    }
    headers.set('Content-Range', 'bytes ' + start + '-' + end + '/' + length);
  }
  headers.set('Content-Length', String(end - start + 1));
  const status = value ? 206 : 200;
  if (request.method === 'HEAD') return new Response(null, {status, headers});

  let offset = start;
  let reader;
  const abort = new AbortController();
  const signal = AbortSignal.any([request.signal, lifetime.signal, abort.signal]);
  const body = new ReadableStream({
    async pull(controller) {
      signal.throwIfAborted();
      if (offset > end) {
        controller.close();
        return;
      }
      let bytes;
      if (offset < prefix.length) {
        bytes = prefix.subarray(offset, Math.min(prefix.length, end + 1));
      } else {
        if (!reader) {
          const {response} = await fetchRange(session, offset, end, signal, length);
          reader = response.body.getReader();
        }
        const next = await reader.read();
        if (next.done || next.value.length > end - offset + 1) {
          abort.abort();
          throw new Error('CDN 媒体流长度错误');
        }
        bytes = next.value;
      }
      signal.throwIfAborted();
      controller.enqueue(session.decryptor.decrypt(bytes, BigInt(offset)));
      offset += bytes.length;
      if (offset > end) {
        controller.close();
        void reader?.cancel().catch(() => {});
      }
    },
    cancel() {
      abort.abort();
      return reader?.cancel().catch(() => {});
    },
  });
  return new Response(body, {status, headers});
}
