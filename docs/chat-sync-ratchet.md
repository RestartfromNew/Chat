# 聊天、信封同步与经典双棘轮

2026-10-16；后端 `53c3954`，以 `docs/backend-api.md` 第 18 节及当前 Dispatcher/Worker 为准。旧 e2ee 设计里的批量 submit、push、sync 等名称不能当作已部署 API。

## 使用

双方更新到此版 iOS，注册各自设备并上传一次性预密钥。登录/回前台会尝试同步；点好友直接进入聊天，可下拉或点击刷新。输入正文后给好友的全部 active 设备分别加密发送。任一目标密钥准备失败时不提交新的发送批次，避免悄悄漏发设备；已加密保存但网络失败的消息可点击重试。成功回执显示“已存储”，不是已送达/已读。

主标签只有好友、申请、我的。设备注册留在“我的”；Token 诊断、连接测试、旧握手报文和加密实验移入“我的 → 开发调试”。未知设备/无法解密的信封保留在本地，在“收信处理状态”可查看。不会显示 S、链密钥、私钥或完整业务帧。

前台已连接时自动接收 `Online_Sync`，校验外层 recipientDeviceId/seq 与内层信封及本机设备一致，再保存、解密显示、ACK。推送与请求回执分别分派，允许插入同步/ACK/发送响应之间。在线包不推进同步游标，避免跳过更早的离线包。原包按 envelope_id 去重，待 ACK 状态可靠保存。

断线后在前台按 1、2、4、8、16、30 秒上限重连，连接成功后从持久化游标补拉。进入后台断开，回前台重新同步；没有后台常驻或 APNs。403 设备拒绝不会不停自动重试，修复注册状态后手动刷新。

## 传输与鉴权

- 根路径 `wss://aittelegramapi.uk/`，GET、Content-Length: 0、Authorization: Bearer、deviceID（本机已注册 UUID）。系统生成标准 Upgrade、随机 Key、Version、帧掩码并校验 Accept。
- 握手 HTTP 401 时走既有 HTTP refresh，一次重试；其他握手错误不循环刷新。
- 每条业务 JSON 仍带小写 authorization。业务鉴权失败单次刷新，超时不自动换消息 ID。
- 正式发送仍用 `chat.newTextMessage`，包含 sender_device_id、recipient_device_id、message_id、protocol_version、packet_base64。
- 同步 `chat.sync.envelope`，device_id + cursors，条目为 peer_device_id / 整数 after_seq；初次 []。
- 确认 `chat.envelopes.ack`，device_id + 1–100 个 envelope_ids，按 acknowledged_ids 集合确认，部分成功仍保留剩余待确认记录。
- 同步、ACK、发送和调试帧共用 WebSocketBusinessRequest 单请求槽，因为失败响应没有 request_id。超时/取消关闭旧连接，防止迟到的无编号失败关联到下一条请求。

分页保存本页全部原始信封后，按各 sender_device_id 的最大 seq 更新游标，并保留其他发送设备游标。seq 可有空洞，发送回执的 seq 不推进收信游标。has_more 时继续；重复 envelope_id 要求内容一致。ACK 在原包可靠保存之后，**不以解密成功为前提**，失败密文不会因 ACK 被丢弃。

## 密码协议与互通格式

`protocol_version = Chat-DR-X25519-HKDF-SHA256-ChaChaPoly-v1`。

这是使用 CryptoKit 和现有 XEdDSA 验签的经典 Double Ratchet 实现，不是 Signal/libsignal 线格式，未经过独立密码学审计；后端仅存储不透明字节。其他客户端必须实现此版本才可解密。参考 [Double Ratchet §3](https://signal.org/docs/specifications/doubleratchet/)。已有 TEST X3DH 的四次 DH 及 `Example-X3DH-Core-v1` KDF 保持兼容。

packet 是 sorted-keys、snake_case UTF-8 JSON；Data 由 Codable 编码为标准 Base64。外层 packet_base64 对整个 JSON 再编码。packet 有：

- header：version、session_id、message_id、sender_id、sender_device_id、recipient_id、recipient_device_id、dh（32 字节公钥）、pn、n，以及可选 bootstrap。
- bootstrap：identity_hex、ephemeral_hex、signed_prekey_id、one_time_prekey_id。初始化临时密钥与发送棘轮密钥独立。
- aad：发送端序列化 header 的**原始字节**，接收方先核对解析后的 header 相等，再直接用于 AEAD，不能自行重排 JSON 作为 AAD。
- sealed：CryptoKit ChaChaPoly combined = 12 字节随机 nonce + ciphertext + 16 字节 tag。

Root KDF：HKDF-SHA256，IKM=DH 输出，salt=当前 RK，info=`Chat-DR-X25519-HKDF-SHA256-ChaChaPoly-v1/root`，输出前 32 字节 RK，后 32 字节 CK。Chain KDF：MK=HMAC-SHA256(CK, 0x01)，next CK=HMAC-SHA256(CK, 0x02)。每条消息只使用一个 MK。

Alice 以 X3DH S 和 Bob 的 SPK 公钥初始化，生成独立棘轮私钥。Bob 用自己的 SPK 私钥及 S 初始化；收到新 DH 公钥后按经典算法更新接收链，再生成新的本机 DH 密钥更新发送链。PN/N 使用非负整数，不超过 UInt32 上限；每会话最多缓存 200 个跳过密钥，跨链迟到消息可解密。旧 DH 重放/超过上限失败时不提交试算状态。会话总数和历史 DH 也有限制，触顶明确报错，不静默丢弃状态。

首消息引导头会随初始化发送链重复携带，直至对端经认证的回复，支持首包延迟。并发发起时保留两套 session_id，以 UUID 字符串排序选择后续发送会话，不覆盖仍有在途消息的另一会话。

身份先与经过鉴权的好友设备目录匹配，并固定在本地；后续变化停止发送。这是首次使用信任，尚无带外安全码验证。不能把服务器提供的身份自动等同于人工核验。

旧 `Chat-Initial-Envelope-JSON-v1` 仅做只读解密兼容，不会建立双棘轮会话；仍需保有对应旧私钥。它不享有双棘轮性质。未知版本保留密文和错误，不降级为明文。

## 状态与崩溃恢复

`ChatStore` 按服务器、账号、设备隔离，以一个 Keychain 项内的单次更新原子提交：会话、消息、待发包、收件原包、ACK 状态和游标。明文历史同样受 WhenUnlockedThisDeviceOnly 保护。这个实现适合当前小型客户端；后续可通过存储边界迁移到加密数据库，避免历史增长后整包更新。

发送：先生成更新后的棘轮和密文副本，原子保存后才写网络。断线/重启重试原密文，不重新加密或再次推进棘轮。同一逻辑消息发给多设备，各自独立棘轮/密文、共享 message_id；分别记录服务端结果。

接收：原包/游标先保存；在状态副本认证解密，认证成功才保存新棘轮和正文。篡改、未知身份、缺少预密钥、重放不推进状态。ACK 只标记服务端已确认收到，不标记已读。

首消息认证并保存后，清除本机已消费 OPK 的私钥，保留 ID 墓碑避免再次上传同号；发送会话保存后清除缓存的 X3DH 临时私钥材料。设备密钥库与聊天存储是两个 Keychain 项，因此清理在聊天原子提交之后执行，并在恢复时重试。Swift/CryptoKit/Keychain 不提供本项目可验证的物理安全擦除保证。删除后旧测试消息若尚未解密且依赖该 OPK，会显示缺少密钥，不伪造恢复。

退出登录仅清内存和 Token，不删除设备密钥与聊天历史。旧异步请求有账号/操作代数检查，不能写入新账号的聊天状态。

## 分层

- DoubleRatchet.swift：无 I/O 的值类型密码状态机、版本化包、X3DH 接收端计算。
- ChatStore.swift：原子状态提交、身份固定、发件箱、收件去重、原包/正文存储与清理标记。
- EnvelopeAPI.swift：真实后端 DTO、请求构造、分页与 ACK 验证。
- WebSocketBusinessRequest / SocketConsole：串行收发、回执分派、断线与超时。
- ChatCoordinator.swift：好友设备目录、会话准备、分页、ACK、发送重试及在线推送接收。
- ConversationView.swift：正文气泡、发送、刷新、失败重试；诊断在独立模块。

## 验证范围

测试覆盖 A/B 初始化及多轮 DH 更新、同链/跨链乱序、篡改回滚、重放拒绝、缓存上限、重启恢复、原包重试、持久化失败不推进棘轮、多设备独立加密、跨账号/服务器隔离、OPK 清理与拒绝复用、原包先落盘、部分 ACK 保留、推送不越过离线游标、握手 Token 头与 401。尚未使用真实双账户向公网发送聊天消息，也未验证其他客户端实现的互通。

最终验证：Xcode 27 / iPhone 17 模拟器，101 项测试通过；Release 模拟器构建成功；git diff --check 通过。附加覆盖延迟的设备库写入不能恢复已清理秘密、清理后的 OPK 编号不会复用，以及同步/ACK 与发送回执的串行隔离。上游 XEdDSA C 源码仍有整数缩窄编译警告，未修改第三方密码实现。


## 启动与在线处理性能

ChatArchiveIO 用独立串行队列读取、解码和写入 Keychain 档案，缓存完整档案，不再在每次提交前读取并解码整份历史。ChatStore 首次 bind 异步恢复；同一绑定直接复用。双棘轮收信解密在 utility 任务批量处理，认证成功才修改试算状态，整批一次提交。取消/退出后旧任务不能发布到新账号。

在线事件用 25ms 短窗口合并，最多积压 256 包/8MiB；超限断开后用同步恢复。仅遇到未知发送设备才查询好友目录，每次最多并发 4 个设备请求，并合并一次保存。启动/回前台合并重复同步，已连接且两秒内刚同步不重复拉取。

测试新增覆盖后端混合大小写字段、目标/序号不匹配拒绝、队列上限/去重、握手 deviceID，以及三条在线密文批量解密后同步重放不推进棘轮、单批只写一次、存储不访问主线程。没有真实设备启动耗时基准；大规模聊天历史仍需后续迁移加密数据库。


同账号设备使用同一双棘轮协议，但发给本人设备的正文是加密的 `chat.sent-copy.v1` 结构，包含 conversationId、messageId、text。仅在通过身份固定验证的同账号会话中解释为同步副本。详见 [设备同步与撤销](device-sync-revocation.md)。
