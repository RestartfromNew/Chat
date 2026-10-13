# 本地加密实验

按后端提交 `e7491fe135e0ecbbc6ba33a9d0c4234b392f363c` 的 `docs/database.md` 第 7–8 节计算示例及第 4 节业务顺序实现。没有后端依赖，也不使用真实账户密钥。

## 使用

登录页点击「本地加密实验（无需登录）」；已登录时点击「加密实验」标签。

1. 生成 A/B 密钥：两端分别生成随机 X25519 身份、预密钥、OPK 和独立 Ed25519 签名密钥。
2. 验签并核对身份：验证整个公开材料的真实 Ed25519 签名，并与本机模拟对端的指纹比较。
3. 建立测试会话：每个方向分别执行四次 X25519；两端独立计算，检查共享秘密一致。
4. 输入正文并加密：生成新的消息 UUID 和随机 salt，派生消息密钥，使用 ChaCha20-Poly1305 的随机 nonce；模拟中转区仅保存公开上下文与密文。
5. 接收端解密：成功认证后才显示聊天气泡、记录已处理 ID 和消耗该接收端 OPK。可切换 A/B 方向回复，连续发送多条消息。
6. 测试坏签名、改密文、改 AAD、错密钥和重复投递。测试失败不会显示候选明文、推进接收状态或消耗 OPK。

公钥包、签名、指纹、握手公开材料和密文信封可在页面展开查看；不输出私钥、DH 结果、共享秘密或消息密钥。重新生成会先确认，随后清空本次数据。最多缓存 20 条待收信封、100 条消息和 30 条事件。

## 三层

- `Core/CryptoLab/CryptoLabEngine.swift`：CryptoKit 计算、公钥包验证、上下文认证、接收去重；不依赖 UI 或网络。
- `Features/CryptoLab/CryptoLabModel.swift`：操作顺序、本地信封队列、气泡和测试结果；MainActor 串行操作。
- `Features/CryptoLab/CryptoLabView.swift`：按钮、公开数据和聊天气泡。

## 明确的实验边界

`LOCAL-DEMO-4DH-Ed25519-ChaChaPoly-v1` 是单独的教学 suite，**不是标准 X3DH/Signal 实现**。经典 X3DH 要求的 XEdDSA 未实现；本实验额外使用独立 Ed25519 密钥签署公开包，没有把它冒充 XEdDSA。生产加密占位 `UnavailableEncryptionService` 保持拒绝发送；实验引擎没有接入网络 Repository。

- 四次 DH 的 KDF 与文档示例完全对齐：32 字节 ff 前缀、SHA256、32 字节零 salt、info `Example-X3DH-Core-v1`。
- 会话消息部分采用独立教学格式：每条随机 salt + HKDF + ChaCha20-Poly1305；AAD 为 sorted-keys JSON 编码的 Header，绑定 suite/session/conversation/message/from/to/salt。
- 固定示例向量只在测试中使用，核对文档 S、K、ciphertext 和 tag；实际按钮使用新随机材料。
- 双端同进程，建立会话阶段提前算出接收端候选秘密；不是离线握手或跨设备协议实现。
- 没有 Double Ratchet／前向保密、生产设备注册、持久化 outbox、Keychain 身份恢复、独立联系人信任流程。指纹核验仅模拟本机可信对端，不等于真实联系人认证。
- 所有实验状态仅在页面内存中；退出页面／重启后不恢复，不能用于真实聊天。私钥对象释放不等于对所有内存副本进行可证明的清零。

未来应替换为成熟协议库的设备/会话适配，并增加账号隔离的 Keychain 私钥存储、事务状态与 outbox，再对接后端。不要直接把本实验教学协议开放为生产聊天。

## 验证（2026-10-07）

Xcode 27 / iPhone 17 模拟器：31 项单元测试通过，其中 8 项为新增加密测试。固定文档向量逐字节匹配 S、K、ciphertext、tag。另一个 XCTest 界面测试完成全部按钮步骤、聊天气泡和密文篡改检查，控制台报告 1 test / 0 failures。首次并行启动模拟器卡住后，改用已启动的模拟器并关闭并行执行。

```sh
xcodebuild -project Chat.xcodeproj -scheme Chat -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:ChatTests CODE_SIGNING_ALLOWED=NO
xcodebuild -project Chat.xcodeproj -scheme Chat -destination 'platform=iOS Simulator,name=iPhone 17' test -parallel-testing-enabled NO -only-testing:ChatUITests/CryptoLabUITests CODE_SIGNING_ALLOWED=NO
```
