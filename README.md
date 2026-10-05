# Chat iOS 客户端

基于后端 `RestartfromNew/cpp_backend_server` 提交 `ae7d294857f84ca30601cbe3293a37c27a25d7d6` 的原生 SwiftUI 客户端。iOS 18.4+ / Xcode 16.3+；不依赖第三方包。

## 运行

打开 `Chat.xcodeproj`，选择 Chat Scheme 和 iPhone 模拟器运行。真机请在 Signing & Capabilities 中选择自己的 Team。
默认 HTTPS 地址为 `https://aittelegramapi.uk`，可在登录页「服务器设置」修改。仅支持有效系统证书的 HTTPS / WSS；本地后端可通过 HTTPS 反向代理连接。WebSocket 默认路径 `/ws` 是可配置的测试入口，需与你的 Nginx 转发配置一致，并不代表后端已实现独立 `/ws` 路由。

配置改变会清除当前登录状态。Token 保存于 Keychain（WhenUnlockedThisDeviceOnly），不写入 UserDefaults、日志或 URL。UserDefaults 只保存服务器配置。退出登录清除本机凭据，不调用尚不存在的服务端撤销接口。

## 已实现

- 注册：邮箱、密码、username、display_name；注册成功后手动登录。
- 登录、恢复本机会话、手动验证和刷新 Token。
- 业务请求收到 401 后合并并发刷新，重试一次。刷新 Token 无效时退出；网络故障不清除凭据。
- 按用户名精确搜索、发送申请、查看收到的申请、接受／拒绝、获取好友列表和本地筛选。
- 取消申请调试：手动提供 request_id。后端发送申请成功体为空，也无已发送列表，因此不能凭空显示发出的申请 ID。
- 好友详情及独立 WebSocket 测试台：连接／断开、Ping、发送 chat.newTextMessage、显示最多 100 条事件，后台自动断开。
- UI 展示后端错误码，兼容空成功响应与 unprocessed_requests="None"。

## 结构与扩展

```
Chat/
  Core/
    Models.swift                API DTO、错误和服务器配置
    HTTPClient.swift            URLSession HTTP、统一错误映射、可注入 transport
    LegacyGETTransport.swift    当前 GET Body 专用 TLS 兼容层
    KeychainStore.swift         CredentialStore / Keychain
    Repositories.swift          Auth / Friends 协议及远端实现；加密协议边界
    AppModel.swift              会话、凭据、合并刷新和账户切换隔离
    SocketConsole.swift         独立 WebSocket 调试状态机
  Features/
    AuthView.swift              登录、注册、服务器设置
    FriendsView.swift           好友列表、搜索、申请、资料
    RequestsView.swift          申请处理
    DiagnosticsViews.swift     WebSocket / 账户诊断
```

视图不拼接 HTTP 请求。HTTPTransport、CredentialStore、AuthRepository、FriendsRepository 均有替换边界。简单表单用本地状态；好友列表单独 ViewModel。后续可将复杂功能按目录拆成独立 Feature 和 ViewModel，无需提前引入大型状态框架。

### GET Body 兼容

当前 `/find_user_by_username` 与 `/refresh_token` 使用 GET JSON Body，URLSession 不支持这种调用。本项目用 Network.framework 的 TLS 连接单独发送 HTTP/1.1，启用系统证书校验；保持 authorization 小写、Content-Length 精确大小写，支持 Content-Length / chunked / Connection-close 响应、20 秒超时、2 MB 上限与取消。兼容层不跟随重定向、不处理压缩，也不使用 HTTP 代理设置；企业代理环境建议优先修改后端为 POST。

其他接口使用 URLSession，不跟随重定向。后端应该统一修复请求头不区分大小写；客户端设置头名称不能保证所有代理转发后仍保留大小写。

后端将两个 GET Body 路由改为 POST 后，关闭设置中的兼容开关；之后可以删除 LegacyGETTransport。不要提前关闭，否则实际后端会返回 404。

### 接入端到端加密

目前**没有实现端到端加密和好友消息投递**。好友详情不开放发送，`UnavailableEncryptionService` 永远抛错，没有明文降级。WebSocket 测试明确使用明文，不用于私人聊天。

后续按以下边界添加：
1. 实现 MessageEncryptionService（如经评估后的 libsignal 适配），另建按账户／设备隔离的安全协议状态存储；不要仅把 AES 工具类当成完整加密协议。
2. 增加 DeviceKeyRepository / MessageRepository，对接后端密钥分发、密文信封、离线拉取和确认接口。
3. 新建 MessageTransport，处理鉴权、重连退避、幂等 message_id、服务端确认与好友送达状态。SocketConsole 是调试工具，不是生产消息队列。
4. 为会话、发件箱、接收去重、身份密钥变化、安全码验证与本地消息存储增加明确状态和测试。

当前 WebSocket 发出的 JSON 是 `{"type":"chat.newTextMessage","id":"UUID","message":"..."}`。header / payload_format / payload 是后端解析器内部包装，客户端不重复包装。服务端返回 success 只表示该业务分支执行，并非好友送达或消息已持久化。

## 手动验收（两个测试账户）

1. 分别注册 Alice 和 Bob，再登录。用户名遵循当前数据库的小写约束。
2. Alice 搜索 Bob 并发送申请；Bob 下拉刷新申请列表并接受。
3. 双方在好友列表下拉刷新，查看对方资料。
4. 测试拒绝申请、重复申请的 409、错误密码、网络断开后的重试。
5. 在「我的」验证 Token、手动刷新；等待过期后刷新好友列表验证自动刷新。
6. 在「连接测试」确认 WSS 路径，连接、Ping、发送无隐私测试文本，观察 newTextMessage.result。
7. 退出／切换服务器，检查登录状态和调试日志清空。

不会自动为公网后端注册账号或发送好友申请。测试由注入 transport 和固定响应验证，不需要真实凭据。已知后端 SQL/schema/时间解析问题应由服务端修复，客户端展示真实错误，不伪造成功。

## 本次验证

Xcode 16.3 / iOS 18.4 模拟器编译成功，18 项单元测试和 1 项界面测试通过。详见 [验证记录](docs/verification.md)，[登录页截图](docs/login-preview.png)。尚未用真实账户完成公网双账户联调。
