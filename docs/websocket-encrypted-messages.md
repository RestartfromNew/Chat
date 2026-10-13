# WebSocket 新消息存储接口（2026-10-12）

对齐后端 main `ca09c7067e8dfbaa678fe1fe1b36b3982965442b` 的 `docs/backend-api.md` 第 18 节、Dispatcher 与提供的 C++ 示例。设计文档里的 `chat.envelopes.submit/push/ack/sync` 尚未实现，不调用。

## 操作入口

登录并注册设备 →「我的 → 自动握手与密文报文」→ 目标好友设备 →「通过 WebSocket 发送」。可以发送已准备的首消息，也可以输入正文，点击「加密并保存新报文」，再连接、发送。列表可选择之前保存的报文重试。每条新消息生成新的 UUID、salt、nonce，发送失败的重试则保持原 UUID 和密文字节。

默认地址按用户最新 PowerShell 示例改为 `wss://aittelegramapi.uk/`，显式添加 `Content-Length: 0`。已有该域名的 `/ws`、`/websocket-test` 设置在启动时自动迁移，保留登录状态；其他自定义地址/路径不改。原生 URLSession 自动生成 Upgrade、Connection、随机 Sec-WebSocket-Key 和 Version 13；不手写固定 Key。URLSession 完成标准 HTTP/1.1 Upgrade、101/Accept 校验、TLS、掩码和 Ping/Pong；不把普通 HTTP 200 或业务 success 当作连接成功。握手头保留 Bearer，但当前后端的实际业务鉴权在每条 JSON 的 authorization 字段。

## 分层

- `InitialEnvelope`：现有 X3DH TEST 教学方案，认证加密正文和解密所需公钥头，不序列化 S 或私钥。
- `StoredMessageProtocol`：将真实 envelope JSON 的 UTF-8 字节作为 packet_base64，构造新版请求并解析回执。
- `WebSocketBusinessRequest`：所有正式消息、测试消息共用单个请求槽。失败回执没有 ID，禁止并发业务请求；超时/取消/发送失败关闭旧连接，避免迟到错误关联到下一条消息。
- `StoredMessageOutbox`：Keychain 保存原始密文包、发送状态和回执；先落盘再发送。重启将中断的 sending 恢复为 uncertain。按服务器、账号、设备隔离；退出只清内存，不删除可重试密文。
- `SocketConsole`：唯一 receive 循环，将回执交给请求槽，保留 incomingFrames 扩展入口。日志只记录帧大小和状态，不打印 token 或正文。
- `AppModel`：使用当前 token；只有明确鉴权失败才通过 HTTP 刷新并原样重试一次。
- `EncryptedMessageView`：输入、加密、选择历史报文、连接、发送及持久化结果显示。

旧 `EncryptedMessaging`/`EncryptedMessageCodec` 为尚未接入的推送设计保留；当前生产调用方已使用 `StoredMessageOutbox`，不会把假设的 accepted/delivered 当作实际后端回执。

## 实际请求

```json
{
  "type": "chat.newTextMessage",
  "authorization": "Bearer ACCESS_TOKEN",
  "sender_device_id": "发送设备 UUID",
  "message_id": "消息 UUID",
  "recipient_device_id": "好友设备 UUID",
  "protocol_version": "Chat-Initial-Envelope-JSON-v1",
  "packet_base64": "标准 Base64 编码的 InitialEnvelope JSON"
}
```

packet 解码后限制 1–65536 字节。客户端正文限制 1–16384 UTF-8 字节。无 header/payload 外包装，无 request_id，无假造 envelope 批量接口。`protocol_version` 标识客户端现有 JSON 格式，服务器只做不透明存储；不是设计中的二进制 E2EE envelope 协议，也不是生产 Signal/Double Ratchet。

成功 `newTextMessage.result` 包含 `success=true,message_id,envelope_id,seq,duplicate`。界面显示 seq、envelope_id、duplicate；只表示服务器持久化，绝不标记好友已收到或已读。设备对内 seq 不用于推断全局消息顺序。

失败兼容 `type=error,error.code` 和 `newTextMessage.result,success=false,error.code`。模糊网络/数据库结果保留 uncertain，手动重连后重发同一包；`envelope_conflict` 阻止重试，不能换编号绕过。鉴权/权限拒绝不代表历史请求一定未保存。

测试台仍使用 `chat.newTextMessage_Test`，字段只有 type、authorization、id、message；它不存储消息。

## 当前边界与线上排查

当前后端未实现接收设备推送、离线收件、ACK、历史同步和连接设备绑定。已有本地 B 侧密钥派生与认证解密测试，但此轮不能验证真实好友收件。没有自动发送、自动重连或 APNs。教学首消息方案复用准备好的 S；后续需补会话持久化和 Double Ratchet。

2026-10-12 对公网 `/ws` 和 `/websocket-test` 发标准 Upgrade，均收到 HTTP 404 `route_not_found`，没有到达 101。C++ 示例连接本机 `127.0.0.1:8082`，没有覆盖公网 TLS/代理链路。请在部署端确认 HTTP Upgrade 判断 → forward_connections → acceptingSessions，及反向代理对 Upgrade/Connection 的转发。无需添加返回普通 JSON 的 WebSocket GET 路由，也不能靠改变消息 type 修复这个阶段。

后端文档说明 Worker 会打印包含 authorization 的原始业务 JSON；服务端需脱敏。客户端不会记录完整发送帧。

## 验证记录

Xcode 27 / iPhone 17 模拟器：76 项单元与集成测试通过；Release 模拟器构建成功。随后将真实 socket 测试包提高到 40,000 字节（二次 Base64 后 JSON 约 54 KiB），5 项连接测试再次通过，确认本环境下发送的是 FIN=1、有掩码的完整文本帧。测试覆盖回执解析、未关联错误串行处理、超时关连接、重启后原包重试、重复回执、迟到发送错误不取消同 ID 的新请求、账号/设备隔离及自定义正文认证解密。

Release 仍有上游 XEdDSA C 源码整数缩窄警告及 Xcode AppIntents 元数据提示，不是此次消息代码的编译错误。未使用真实用户 token 向公网发送消息；完整 C++ 后端、数据库及公网代理仍需部署环境联调。

补充：用户提供的 Windows 根路径 `/` 握手同样收到 HTTP 404。响应含 `Upgrade: websocket` 不能替代成功状态 101，也不足以判断故障一定来自 Cloudflare 或源站中的哪一层。

## 公网恢复（2026-10-12 22:26 UTC 后复测）

公网根路径现已返回 HTTP 101。使用项目 `WebSocketConnection.swift` 编译的原生 URLSession 探针，didOpen 与 Ping/Pong 均成功；未发送业务消息或账号凭据。上文 404 为修复前的历史结果。iOS 保留根路径及 Content-Length: 0，取消握手前额外 HTTP verify 调用；登录后直接握手，每条业务帧仍带 token，鉴权失败时 HTTP 刷新一次。连接测试页显示实际 WSS 地址。完整存储发送仍需用户登录后实测。
