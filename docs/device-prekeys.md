> 更新：2026-10-09 已接入 bundle 接口及登录自动准备，当前行为见 [自动握手说明](automatic-handshake.md)。下文保留早期手动联调记录。

# iOS 设备注册和 prekey 接入

对应后端 main `eddbcf9`（feat: add device registration），依据 docs/backend-api.md 第 13–16 节、src/main.cpp 及 Handler/Service 实现。

## 使用

1. 登录，在「我的 → 本机设备与密钥」查看本机生成的公钥材料，点击「注册本机设备」。
2. 注册成功后点击「生成并上传 5 个一次性 prekey」。未注册设备的 OPK 数量始终为零。两位用户分别完成这些操作。
3. 「好友 → 好友资料 → 设备与会话准备」拉取好友设备。未注册的好友显示空列表，不生成虚构设备或 prekey。
4. 针对目标设备点击「准备会话 / 获取 prekey」。已有协议会话直接跳过；否则优先复用缓存，没有缓存才领取一个 OPK。重复点击和重启不重复领取。

设备注册不自动上传 OPK。界面所示数量是本机保留的私钥/已确认上传条数，不是后端 available 库存。服务器可能已把部分公钥交给好友；私钥仍须保留以处理离线首消息。

## 分层

- Core/DeviceKeys.swift：X25519 密钥、XEdDSA 签名、公钥格式检查、Keychain 存储。与旧 CryptoLab 教学密钥完全独立。
- Core/DeviceRepository.swift：请求/响应 DTO 和四个受保护 POST 接口。
- Core/DeviceCoordinator.swift：注册、上传、领取状态机；提供 DeviceSessionLookup 供将来真实会话存储接入。
- Features/DeviceViews.swift：设备操作入口及公钥、状态、错误显示。
- Core/AppModel.swift：登录附带已登记 device_id、账户隔离、统一 access token 刷新。

注册 signed_prekey_id 使用 JSON 字符串 "42"（初始版本）；上传 prekey_id 使用 JSON 整数，每批 5 条，从 1001 递增，不复用已有编号。公钥 raw 32 字节转 64 位 hex；签名 64 字节转 128 位 hex。签名消息采用原始 32 字节 signed-prekey 公钥，不添加 Signal 0x05 前缀。该编码是本客户端 TEST 套件约定；后端将来验签应采用相同编码。

密钥先保存再发请求，仅公钥上网和展示。独立 Keychain service 使用 WhenUnlockedThisDeviceOnly，以 HTTPS 服务器和账号 UUID 隔离，退出登录不删除。登录邮箱索引用于下次带上 device_id；旧版本已登录用户无索引时，下一次登录先识别账号，再携带已有设备 ID 登录。

注册、上传、领取都没有后端幂等键。发送前持久化进行中状态；超时、断网、5xx、响应不匹配或上次进程中断视为结果不确定，不自动重试。界面会要求核实后端。注册和上传结果不确定时保留所有私钥；领取结果不确定时阻止继续消耗 OPK。确认未执行的 4xx 可重试；上传 409 保守保留为不确定。Access Token 401 只经统一鉴权刷新重试一次。404 prekey_unavailable 显示暂无库存，允许好友补充后手动重试。

## 当前边界

friend_devices 只有身份公钥，没有 signed-prekey 公钥、编号和签名。领取 OPK 只缓存握手材料，不建立或伪造会话。当前默认 NoDeviceSessions 返回 false；未来实现真正握手与 ratchet 持久化后替换该接口，已有会话便不再请求 OPK。首次返回的身份公钥尚未通过带外安全码核验；已缓存设备身份发生变化会阻止继续使用。

后端 UserHandler.cpp 当前对 optional<bool> 使用 `verified ? ...`，判断的是 optional 是否有值，false 也可能返回 verified；客户端不将该字段视为密码学身份验证。后端应改成判断 `*verified`，同时保留 nullopt 分支。

本次没有向线上账号发送注册或领取操作；网络行为通过注入传输层和模拟接口验证，实际联调使用上述按钮。

## 依赖和验证

CryptoKit 用于 X25519。XEdDSA 使用 Vendor/XEdDSA 中原始 Signal libsignal-protocol-c 曲线实现，源提交 3a83a4f4ed2302ff6e68ab569c88793b50c22d28，本地 Swift Package，无网络安装依赖。上游已归档，GPLv3 许可证，详见 Vendor/XEdDSA/LICENSE 与 NOTICE.md；发布产品前需要评估维护方案与许可证兼容性。它仅提供签名原语，不代表集成了完整 Signal 协议。

测试包含上游确定性 XEdDSA 测试向量及 CryptoKit 公钥互通、签名篡改、JSON 类型和鉴权头、未注册 OPK 拦截、上传前私钥存储、ID 唯一、会话跳过、跨重启缓存、身份变更、404、超时不重复请求及账号隔离。


## 领取后的验签与 S（2026-10-08）

在好友设备下进入「验证结果与 S」。获取 OPK 后，设备 ID、好友 ID、OPK 编号及公钥检查结果直接显示；缺少 signed-prekey bundle 时不生成 S。

目前后端没有返回好友 SPK 的路由。好友可在「我的 → 本机设备与密钥 → 分享公钥 JSON」分享注册时的公钥材料；将它粘贴进验证页，点击「验证签名并计算 S」。不用发送私钥。导入材料必须与设备列表的身份公钥和协议套件一致，SPK 编号、公钥、XEdDSA 签名全部验证通过才计算。

计算公式与 docs/database.md 教学参数相同：D1=DH(IKa,SPKb)，D2=DH(EKa,IKb)，D3=DH(EKa,SPKb)，D4=DH(EKa,OPKb)；S=HKDF-SHA256(0xff×32 || D1 || D2 || D3 || D4)，salt=0×32，info=Example-X3DH-Core-v1，输出 32 字节。此 info 是教学约定，尚未作为正式线上协议完成协商。

临时私钥 EKa 与经验证的 SPK 绑定到已领取 OPK，一同保存在 Keychain；重新验证/重启不会重新生成 EKa，也不会再次调用领取接口。旧版本无 check 字段的缓存仍可读取。保存的握手材料不允许换成另一份 SPK。

界面默认显示 SHA-256(S)。Debug 版本可开启「显示 S 原值（仅调试）」；Release 没有原值字段和显示开关。S 不写入控制台，不作为分享内容。这里仅验证签名和本地派生成功，未证明远端持有相同 S，也未建立 Double Ratchet 会话。

新增测试覆盖文档已知 S 向量、实际 XEdDSA 公钥包验签、双方四次 DH 派生一致、错误签名/其他身份拒绝、缺少 OPK 不计算、跨重启复用、旧缓存兼容、并发设备写操作保护。49 项单元测试通过。

Release 模拟器构建通过；Release 主可执行文件中未发现调试 S 开关文本或 prekey.secret 元素标识。
