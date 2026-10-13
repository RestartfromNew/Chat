# Access Token 请求头兼容修复

已核对 GitHub main ae7d294，并用本机 Swift Foundation 复现：

- `setValue(..., forHTTPHeaderField: "authorization")` 和直接赋值 allHTTPHeaderFields 均会变成 `Authorization`。
- 后端 HttpParse 保留原始头名称；AuthMiddleWare 只查询 `headers.find("authorization")`。
- 所以合法的 Authorization 头会在校验 JWT 之前被拒绝。Windows 手写小写头成功与此一致。代理是否再次改写头仍取决于线上配置，尚未用用户的真实 Token 验证线上服务。

## 已修改 iOS

- HTTP API 默认为受保护，缺失、空或含空白的 Token 在请求发出前报错。
- 登录、注册和 refresh_token 明确标记公开接口，不附带 Access Token；刷新提交 refreshToken。
- 所有受保护 HTTP 请求通过独立 HTTP/1.1 TLS 兼容层发送，强制实际字节为小写 authorization；GET / POST 方法、UTF-8 Content-Length 和 JSON Body 保留。系统证书校验不变。
- WebSocket 握手使用同一 Bearer 构造器；连接前验证 Access Token，401 时统一刷新后重试验证。
- 原生 URLSessionWebSocketTask 会规范化请求头，握手中的 Authorization 大小写仍必须由后端／代理兼容。

## 后端根治（未部署）

在后端仓库根目录执行：

```sh
git apply --check /path/to/backend-auth-header.patch
git apply /path/to/backend-auth-header.patch
```

然后重新构建并部署。补丁只改 AuthMiddleWare 的查找方式为不区分大小写，保留 JWT 验证。不会自动给 WebSocket 握手增加鉴权：当前 GitHub 版 HttpSession 升级分支绕过 Router，后续应在升级前调用鉴权并将身份绑定到连接。

如果暂时只改 Nginx，在实际转发 C++ 的普通 API 和 WebSocket location 中显式加入：

```nginx
proxy_set_header authorization $http_authorization;
```

需结合原有 proxy_pass / Upgrade / Connection 配置使用，并先 `nginx -t` 再 reload。不要把真实 Token 写进配置。这只是代理兼容方案，后端忽略请求头大小写才是根治。

验收：同一个未过期 Token 分别使用 authorization、Authorization、AUTHORIZATION 调用 verify_access_token，修复后应一致成功；缺失、无效、过期 Token 仍应拒绝。不要把 Token 发到第三方回显网站或公开日志。
