# 登录后自动准备首消息（2026-10-09）

后端版本：main `e3db582`（feat: add device bundle and prekey router）。已核对 docs/backend-api.md 第 17 节、src/main.cpp、ChatHandler::getDeviceKeyBundle 和 KeyRepository 查询。

## 行为

登录成功或恢复本地登录后，ContentView 的 identity task 自动执行：

1. 确认本机设备已注册；未注册不生成或领取 OPK，界面提示注册。注册成功后自动继续。
2. fetch_friends → 按好友调用 friend_devices。
3. 对各设备先检查真实会话接口；已有会话跳过。已有待发送 envelope 直接复用。
4. 没有待发送材料时调用 POST /get_device_key_bundle，核对 friend_id / device_id / is_current，结合设备列表的身份公钥和套件验证 XEdDSA 签名。
5. 只有 bundle 合法才调用 get_one_time_prekey。请求前持久化 bundle 和领取中状态。已有 OPK 缓存时不重复领取。
6. 保存 EKa，四次 X25519 和 HKDF 计算 S，从 S 派生首消息密钥，用 ChaCha20-Poly1305 加密固定测试正文。
7. 将 envelope 保存到独立的设备 Keychain。重新登录、重新检查或重启复用同一个 message_id、nonce、密文和 EKa。

入口：「我的 → 自动握手与密文报文」。好友的「设备与会话准备」也可手动重试，进入「验证结果、S 与 envelope」查看摘要、Debug S、报文 JSON，并导出密文报文。正常流程不再需要手动粘贴公钥包；保留手动导入作为可选调试功能。

正文暂固定为「你好，这是首次加密握手测试消息。」。用户此次要求构造报文，后端尚无 envelope 提交/持久化/离线投递路由，因此本次没有发送消息、没有把生成成功当作好友收到或真实会话已建立。

错误隔离到每个好友或设备。空设备列表不拉 bundle、不领取 OPK；签名、归属和版本错误不会消耗 OPK；404 无库存允许补充后重试；超时等未知结果阻止盲目再次领取。退出登录清空进度并取消旧账户流程；密钥和待发送报文保留。每次设备列表刷新后，缓存身份公钥不匹配会停止复用。

## 新接口

POST /get_device_key_bundle，Bearer Access Token，请求 friend_id 和 device_id。
响应 signed_prekey_id 是 JSON 整数，iOS 用 Int64 接收，再转成内部编号字符串。注意：注册请求仍要求字符串，不能混用。is_current 必须 true。响应只包含 SPK 和签名，身份公钥和 protocol_suite 从 friend_devices 补齐；验签成功后才继续。

## 首消息 envelope v1

这是客户端 TEST 套件的新 wire 约定，服务端将来只需保存并转发原报文；接收端必须按同一约定实现，不能作为已经实现的服务端消息协议来使用。

```json
{
  "header": {
    "version": 1,
    "type": "prekey_message",
    "protocol_suite": "TEST-X25519-XEdDSA-HKDF-SHA256-v1",
    "handshake_kdf": "Example-X3DH-Core-v1",
    "message_kdf": "Chat-Initial-Envelope-v1",
    "cipher": "ChaCha20-Poly1305",
    "message_id": "UUID",
    "sender_id": "A账号UUID",
    "sender_device_id": "A设备UUID",
    "recipient_id": "B账号UUID",
    "recipient_device_id": "B设备UUID",
    "sender_identity_public_hex": "64hex",
    "sender_ephemeral_public_hex": "64hex",
    "recipient_identity_public_hex": "64hex",
    "signed_prekey_id": "42",
    "one_time_prekey_id": 1001,
    "salt_hex": "64hex"
  },
  "aad_base64": "上述header编码后的原始UTF-8 JSON字节的Base64",
  "nonce_hex": "24hex",
  "ciphertext_base64": "密文Base64",
  "tag_hex": "32hex"
}
```

S 沿用后端文档教学参数：IKM=0xff×32 || DH1 || DH2 || DH3 || DH4，HKDF-SHA256，salt=0×32，info=Example-X3DH-Core-v1，输出 32 字节。
消息密钥=HKDF-SHA256(S, 随机32字节salt, UTF-8("Chat-Initial-Envelope-v1"), 32字节)。nonce 是随机12字节，tag 为16字节。

AAD 使用 aad_base64 解码后的**原始字节**。B 解析 AAD 后必须确认它与可见 header 完全一致，并核对协议、版本和路由；不要重新序列化 JSON 生成 AAD，不同语言的 JSON 字段排序会不同。所有握手公钥、目标编号、路由、消息 ID、KDF 参数都受认证保护。密文报文不包含 S 或任何私钥。

B 端将来需验证发送者账号/设备及身份公钥，根据 SPK/OPK 编号取本机私钥，组合 A 的 IK/EK 计算 S，然后认证解密。只有认证通过才显示正文，协调持久化会话、消息去重和 OPK 私钥生命周期。这里提供 InitialEnvelope.open 密码学解密函数及 B 端等价计算测试，尚未接入线上收件、重放去重或 Double Ratchet。NoDeviceSessions 是真实会话存储的替换点；待发送报文只算 pending，不算 established。

## 分层与验证

- DeviceRepository.swift：bundle HTTP DTO 与响应语义校验。
- HandshakePreparation.swift：自动好友/设备遍历、顺序控制、缓存恢复、错误隔离。
- PrekeyVerification.swift：公钥校验、XEdDSA 验证、S 派生。
- InitialEnvelope.swift：版本化报文、AAD、消息密钥、AEAD 加解密。
- HandshakePreparationView.swift：进度与每台设备报文结果。

自动流程测试覆盖调用顺序、bundle 在领取前持久化、无效签名不领取、已有会话跳过、跨重启原样复用、未注册设备拦截、单个好友错误隔离、退出账户取消、API 数字编号和 Bearer、B 端推导相同 S 并解密、密文/AAD/错误密钥拒绝。
