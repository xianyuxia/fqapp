import routes from '../relay-routes.json' with {type: 'json'};

const permittedMethods = new Set(['GET', 'HEAD', 'POST']);
const forwardedHeaders = ['accept', 'content-type', 'content-encoding', 'user-agent', 'y'];
const signatureHeaders = [
  'x-argus', 'x-gorgon', 'x-khronos', 'x-ladon', 'x-ss-stub',
  'x-ss-req-ticket', 'x-helios', 'x-medusa',
];
const responseHeaders = new Set(['content-type', 'content-range', 'retry-after', 'location', 'y', 'c']);
const bodyLimit = 1024 * 1024;

function json(value, status, cors) {
  return Response.json(value, {status, headers: {...cors, 'Cache-Control': 'no-store'}});
}

function matchRoute(method, url) {
  if (!permittedMethods.has(method) || !url.startsWith('https://') ||
      /[\x00-\x20\x7f\\#]/.test(url)) return;
  try {
    const target = new URL(url);
    if (target.protocol !== 'https:' || target.username || target.password || target.port) return;

    // Check the supplied path before URL parsing can remove dot segments.
    const rawPath = /^https:\/\/[^/?#]+([^?#]*)/.exec(url)?.[1] || '/';
    if (/(?:^|\/)\.{1,2}(?:\/|$)|[\x00-\x1f\x7f\\]/.test(decodeURIComponent(rawPath))) return;
    const address = target.origin + rawPath;
    return routes.find(route => {
      if (route.method !== method) return false;
      if (route.url === address) return true;
      if (!route.prefix?.endsWith('/') || !address.startsWith(route.prefix)) return false;
      const suffix = route.numeric_id_suffix;
      if (!suffix) return true;
      const tail = address.slice(route.prefix.length);
      return tail.endsWith(suffix) && /^[0-9]+$/.test(tail.slice(0, -suffix.length));
    });
  } catch {
    return;
  }
}

export default {
  async fetch(request, env) {
    const requestUrl = new URL(request.url);
    if (requestUrl.pathname !== '/relay') {
      return env.ASSETS ? env.ASSETS.fetch(request) : new Response(null, {status: 404});
    }
    const origin = request.headers.get('origin');
    const allowed = origin && (origin === requestUrl.origin || origin === env.PWA_ORIGIN);
    const cors = allowed ? {
      'Access-Control-Allow-Origin': origin,
      'Access-Control-Allow-Headers': 'content-type',
      'Access-Control-Allow-Methods': 'POST, OPTIONS',
      'Vary': 'Origin',
    } : {};
    if (origin && !allowed) return json({error:'origin denied'}, 403, cors);
    if (request.method === 'OPTIONS') return new Response(null, {status: 204, headers:cors});
    if (request.method !== 'POST') return json({error:'POST required'}, 405, cors);

    let payload;
    try {
      const reader = request.body?.getReader();
      if (!reader) return json({error:'request body required'}, 400, cors);
      const decoder = new TextDecoder('utf-8', {fatal:true});
      let contents = '';
      let size = 0;
      for (;;) {
        const {done,value} = await reader.read();
        if (done) break;
        size += value.byteLength;
        if (size > bodyLimit) {
          await reader.cancel();
          return json({error:'request too large'}, 413, cors);
        }
        contents += decoder.decode(value, {stream:true});
      }
      contents += decoder.decode();
      if (!contents) return json({error:'request body required'}, 400, cors);
      payload = JSON.parse(contents);
    } catch {
      return json({error:'invalid request'}, 400, cors);
    }

    if (typeof payload?.method !== 'string' || typeof payload?.url !== 'string') {
      return json({error:'invalid request'}, 400, cors);
    }
    const {method, url} = payload;
    const route = matchRoute(method, url);
    if (!route) return json({error:'target denied'}, 403, cors);

    const headers = payload.headers ?? [];
    if (!Array.isArray(headers)) return json({error:'invalid headers'}, 400, cors);
    const upstreamHeaders = new Headers();
    const allowedHeaders = new Set([...forwardedHeaders, ...signatureHeaders, ...(route.request_headers ?? [])]);
    for (const pair of headers) {
      if (!Array.isArray(pair) || typeof pair[0] !== 'string' || typeof pair[1] !== 'string') {
        return json({error:'invalid headers'}, 400, cors);
      }
      const name = pair[0].toLowerCase();
      if (!allowedHeaders.has(name)) continue;
      if (/[\x00-\x1f\x7f]/.test(pair[1])) return json({error:'invalid header value'}, 400, cors);
      upstreamHeaders.append(name, pair[1]);
    }

    let body = null;
    if (method === 'POST') {
      const encoded = payload.body ?? '';
      if (typeof encoded !== 'string') return json({error:'invalid request body'}, 400, cors);
      try {
        body = Uint8Array.from(atob(encoded), char => char.charCodeAt(0));
      } catch {
        return json({error:'invalid request body'}, 400, cors);
      }
    }

    try {
      const upstream = await fetch(url, {
        method, headers:upstreamHeaders, body,
        redirect:'manual', signal:AbortSignal.timeout(20000),
      });
      const outputHeaders = new Headers({
        ...cors,
        'Cache-Control':'no-store',
        'Content-Type':'application/octet-stream',
        'X-Relay-Upstream-Status':String(upstream.status),
      });
      for (const [name, value] of upstream.headers) {
        if (responseHeaders.has(name)) outputHeaders.set('X-Relay-Upstream-' + name, value);
      }
      const exposed = Array.from(outputHeaders.keys()).filter(name => name.startsWith('x-relay-upstream-'));
      outputHeaders.set('Access-Control-Expose-Headers', exposed.join(', '));
      return new Response(upstream.body, {status:200, headers:outputHeaders});
    } catch {
      return json({error:'relay failed'}, 502, cors);
    }
  },
};
