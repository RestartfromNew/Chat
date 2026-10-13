# WebSocket bad response 排查（2026-10-09）

客户端测试帧已按用户要求改成 chat.newTextMessage_Test，字段仍是 type / id / message。消息类型只有在 HTTP Upgrade 完成后才发送，不能解决握手失败。

对默认线上地址 https://aittelegramapi.uk/ws 发出无登录凭据、没有业务消息的标准 HTTP/1.1 Upgrade 请求，实际返回：

```text
HTTP/1.1 404 Not Found
Server: cloudflare
Content-Type: application/json
{"error":{"code":"route_not_found","message":"Route not found"}}
```

这是该次探测的结果，不是已登录用户真实握手的抓包。正常 WebSocket Upgrade 必须返回 101 Switching Protocols；受保护连接缺少有效凭据时应拒绝鉴权。本次收到 route_not_found 表明请求未完成升级。

应核对部署中的 /ws 是否到达支持 Upgrade 的后端服务，以及反向代理/隧道是否转发 Upgrade 和 Connection、使用可升级的 HTTP 连接。若使用 Nginx，对应 location 通常需要 proxy_http_version 1.1、proxy_set_header Upgrade $http_upgrade、proxy_set_header Connection upgrade；应结合现有配置修改，不能据此假定本服务正在使用 Nginx。不要用关闭 TLS 验证、URL query 携带 Token 或忽略鉴权绕过。

GitHub origin/main e3db582 中，HttpSession 会先判断 Upgrade 再转交 WebsocketWorker；如果请求落入普通 Router，则 /ws 没有普通 HTTP 路由会返回 404。需要检查运行中的二进制版本、代理上游及请求头。WebsocketWorker 对 Sec-WebSocket-Key 仍是大小写敏感查找，后端也应按 HTTP 规则统一处理头字段大小写。本次不修改或部署服务器。

该 GitHub 版本 WebSocketDispatcher 仍判断 chat.newTextMessage；用户要求的新 chat.newTextMessage_Test 已用于 iOS，服务端应确保相同版本已发布。

iOS 现在显示连接目标、URLSession 能提供的 HTTP 状态以及错误域/代码；401/403、404、400/426、5xx 分别显示对应检查点。URLSession 未提供 HTTP 响应时明确提示检查 101 Upgrade，而不伪造状态码。连接/退出时清理错误，失败内容在连接测试页及加密消息入口可见。

No scene exists for identity: com.apple.InputUI.keyboard... 是键盘场景相关的系统日志。仅凭这条日志不能推断 WebSocket 失败；本次网络问题有独立的 HTTP 响应证据。

验证：63 项单元测试通过，包括新测试帧类型和握手错误说明。未用真实账号发送测试消息；线上 WebSocket 连通性尚需服务端修正后用登录设备确认。


## 新版本复核：8bf3d13

该提交只修改 WebSocketDispatcher：type 改为 chat.newTextMessage_Test，且分发前额外读取 device_id 和 receiver_device_id。未修改 HTTP Upgrade。2026-10-09 16:29 America/Toronto 对线上 /ws 再次探测仍为 404 route_not_found；用户设备截图也显示带登录凭据握手返回 404。

iOS 已补齐新必填字段：发送设备来自本机注册记录，目标设备在测试页面输入 UUID；没有本机注册记录时不会伪造 device_id。此改动解决连接成功后的测试帧兼容问题，不声称解决线上 404。

定位代理与进程的方法：在服务器本机对 C++ 监听端口直接做同样 Upgrade 请求，再与公网域名对比。若直连 101、公网 404，检查代理/隧道/upstream；若直连也 404，核对实际运行二进制、监听端口和 HttpSession 收到的 Upgrade/Connection/Sec-WebSocket-Version 头。日志不要输出 Authorization 或 Cookie。若服务有鉴权，应使用受保护方式提供有效凭据，不能为测试关闭鉴权。
