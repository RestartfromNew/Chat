# Chat iOS 客户端

SwiftUI / iOS 18.4+。当前对接 `RestartfromNew/cpp_backend_server` 的 `53c3954`，包括握手 Token 验证、`chat.newTextMessage`、`chat.sync.envelope` 、`chat.envelopes.ack` 与 `Online_Sync` 在线推送。

打开 `Chat.xcodeproj`、选择 Chat scheme 运行；真机配置自己的 Signing Team。默认服务 `https://aittelegramapi.uk`，WebSocket `wss://aittelegramapi.uk/`。旧默认 /ws、/websocket-test 设置自动迁移至根路径。握手携带 Access Token 与 `deviceID`，每条业务帧仍携带 Access Token，明确鉴权失败时刷新一次。

## 使用

1. 两端登录后自动加载好友、注册首次设备并准备密钥、连接 WebSocket 和同步消息。无需手动建立连接。
2. 建立好友关系后点好友进入聊天。正文在本机使用经典双棘轮加密，分别发给好友的有效设备。
3. 登录、回前台、进入聊天和手动刷新会拉取信封、保存、解密并 ACK；前台在线消息自动接收并解密显示，断线重连后补拉。
4. “我的 → 我的设备与撤销”查询本人设备、密码确认撤销，或进入本人设备间聊天；发给好友的新消息也会独立加密给本人的其他 active 设备。
5. 发送失败点击原消息重试，不重新生成密文。已存储表示服务端持久化，ACK 表示接收端可靠收到，均不是已读。

主界面保留好友、申请、我的。Token、WebSocket、旧握手材料和加密实验统一进入“我的 → 开发调试”。不要用旧版实验报文替代正式聊天。

## 实现

- `DoubleRatchet`：CryptoKit X25519、HKDF/HMAC-SHA256、ChaChaPoly，含 DH/对称棘轮与有限乱序缓存。
- `ChatArchiveIO`：后台串行读取/编码/写入并缓存档案，解密在后台按批处理。
- `ChatStore`：按服务/账号/设备隔离的 Keychain 原子会话、聊天记录、发件箱、收件箱、ACK 和游标存储。
- `EnvelopeAPI` / `SocketConsole`：新版同步/ACK 与所有业务请求串行收发。
- `ChatCoordinator`：连接、分页、好友设备验证、加密发送、解密与原包重试；接收在线推送并自动重连补拉。
- `ConversationView`：朋友聊天界面。

使用独立协议版本，不与 Signal 线格式互通，也未经过独立密码学审计；其他客户端需实现相同格式。身份公钥固定采用首次使用信任，尚无安全码核验。协议、崩溃恢复、旧包兼容、限制及测试见 [聊天同步与双棘轮](docs/chat-sync-ratchet.md)。

设备验签使用 `Vendor/XEdDSA` 本地包，许可见其 NOTICE。密钥和聊天记录采用 WhenUnlockedThisDeviceOnly，退出不删除聊天历史。当前存储适合小规模测试，历史增长后应在现有边界迁移到加密数据库。

HTTP 历史兼容层仍用于当前 GET Body / 认证头约定。旧实现与排查记录：[认证兼容](docs/auth-fix.md)、[设备预密钥](docs/device-prekeys.md)、[旧握手流程](docs/automatic-handshake.md)、[旧消息接口记录](docs/websocket-encrypted-messages.md)。这些历史文档如与当前接口冲突，以聊天同步与双棘轮文档为准。

验证：103 项单元/集成测试通过，Release 模拟器构建成功。尚未做真实双账户公网聊天联调。

新版设备查询、同账号副本与撤销流程见 [设备同步与撤销](docs/device-sync-revocation.md)。

自动启动、弱网重连、顶层等待提示与中英文切换见 [自动启动与语言](docs/automatic-startup-language.md)。
