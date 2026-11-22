# PWA

Flutter 在 Web Worker 中调用 Rust WASM。浏览器内核复用原项目的请求、签名、解析和解密。设备信息保存在 IndexedDB。HTTP 中转只检查目标与请求大小，然后转发。

Windows 构建需要 Flutter、带 `wasm32-unknown-unknown` 目标的 Rust 1.99.1，以及与 `rust/Cargo.lock` 一致的 `wasm-bindgen-cli` 0.2.128。

```powershell
rustup target add --toolchain 1.99.1 wasm32-unknown-unknown
cargo +1.99.1 install wasm-bindgen-cli --version 0.2.128 --locked
pwsh -File scripts/build_pwa.ps1
```

两个站点都发布同一次构建的前端静态目录，使用同源 `/relay`，业务路由统一维护在 `pwa/relay-routes.json`。

- Cloudflare Worker 使用 `pwa/worker/wrangler.jsonc`，从 `build/web` 发布前端，构建时打包共享白名单。
- 宝塔站点由 Nginx 提供相同的前端目录，`/relay` 交给 PHP-FPM 运行 `pwa/php/relay.php`。把 PHP 和站点的 `relay-config.json` 放到站点根目录下的 `private/`，共享 `relay-routes.json` 放到站点根目录，两者都在公开静态目录之外。

如需使用独立的 HTTP 中转，构建时用 `-RelayUrl` 指定 HTTPS 地址，并在中转端允许 PWA 站点的 Origin。

转发接口收到 JSON 格式的 POST，字段为 `method`、`url`、`headers`（名称和值的二元组数组）和 `body`（base64，可空）。转发成功时，接口返回 200，使用 `X-Relay-Upstream-Status` 返回上游状态，使用 `X-Relay-Upstream-*` 返回所需响应头，响应体为解码后的上游字节。上游重定向的目标通过 `X-Relay-Upstream-Location` 回传。中转独立部署时，这些头也需要通过 CORS 暴露。
