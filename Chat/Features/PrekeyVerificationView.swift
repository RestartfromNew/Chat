import SwiftUI

struct PrekeyVerificationView: View {
    @EnvironmentObject private var app: AppModel
    let friend: ChatUser
    let device: FriendDevice
    @State private var json = ""
    @State private var envelope: InitialEnvelope?
    @State private var busy = false
    @State private var hasClaim = false
    @State private var result: PrekeyCheckResult?
    @State private var error: String?
    @State private var revealSecret = false

    var body: some View {
        Form {
            Section("领取验证") {
                Label(hasClaim ? "好友 / 设备 ID、OPK 格式已校验" : "尚未领取可用 OPK", systemImage: hasClaim ? "checkmark.circle" : "clock")
                Text("验证目标：\(device.deviceName)")
                Text(device.deviceId.uuidString).font(.caption.monospaced())
            }
            Section("自动获取公钥包") {
                Button("获取 bundle、验证并构造密文报文") { Task { await prepare() } }.disabled(busy)
                if busy { ProgressView() }
                Text("从后端获取 bundle，验证通过后才领取 OPK；已有结果直接复用。").font(.footnote)
            }
            Section("手动导入（可选调试）") {
                Text("请好友在“我的 → 本机设备与密钥”复制注册公钥 JSON，再粘贴到这里。正常流程已自动获取，无需手动粘贴。").font(.footnote)
                TextEditor(text: $json).frame(minHeight: 140).font(.caption.monospaced())
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("prekey.bundle")
                Button("验证签名并计算 S") { verify() }
                    .disabled(!hasClaim || json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("prekey.verify")
                Text("只需要公钥 JSON，请勿粘贴私钥。签名验证通过表示该身份密钥签署了 SPK；联系人的真实身份仍需另外核验。").font(.footnote)
            }
            if let error { Section { NoticeView(text: error) } }
            if let result {
                Section("验证结果") {
                    Label("身份公钥与设备列表一致", systemImage: "checkmark.circle")
                    Label("XEdDSA 签名验证通过", systemImage: "checkmark.shield")
                        .accessibilityIdentifier("prekey.signature.valid")
                    Text("SPK #\(result.signedPrekeyID) · OPK #\(result.prekeyID)")
                    Text("4 次 X25519 + HKDF-SHA256 已完成，S 为 32 字节。")
                    Text("EKa 公钥：\(result.ephemeralPublicHex)").font(.caption.monospaced()).textSelection(.enabled)
                    Text("SHA-256(S)：\(result.secretFingerprint)").font(.caption.monospaced()).textSelection(.enabled)
                        .accessibilityIdentifier("prekey.fingerprint")
                    #if DEBUG
                    Toggle("显示 S 原值（仅调试）", isOn: $revealSecret)
                    if revealSecret {
                        Text(result.secretHex).font(.caption.monospaced()).textSelection(.enabled)
                            .accessibilityIdentifier("prekey.secret")
                        Text("S 是秘密材料，请勿发送给好友或上传日志。发布版不显示原值。").font(.footnote)
                    }
                    #endif
                }
            } else {
                Section("S") { Text(hasClaim ? "未生成：需要有效的 signed prekey 及其签名。" : "未生成：需要先领取好友 OPK。") }
            }
            if let envelope, let text = try? envelope.json() {
                Section("待发送首消息 envelope") {
                    Text("包含密文、nonce、tag、AAD 和接收方派生 S 所需的公钥及编号；存储状态见发送页。") .font(.footnote)
                    Text(text).font(.caption.monospaced()).textSelection(.enabled)
                    ShareLink("导出密文报文", item: text)
                    NavigationLink("通过 WebSocket 发送") {
                        EncryptedMessageView(envelope: envelope, model: app.encryptedMessaging, socket: app.socket)
                    }
                }
            }
            Section("测试范围") {
                Text("使用后端文档教学 KDF：\(PrekeyVerification.info)。这是本端计算结果；尚无对端密钥确认，也未建立真实聊天会话。重复验证复用同一 EKa，不再领取 OPK。").font(.footnote)
            }
        }
        .navigationTitle("Prekey 验证与 S")
        .task { restore() }
        .onChange(of: json) { _, _ in result = nil; error = nil; revealSecret = false }
        .onDisappear { revealSecret = false; result = nil }
    }
    @MainActor private func restore() {
        do {
            let scope = try app.deviceScope()
            let cached = try app.devices.cachedClaim(scope: scope, friend: friend.id, device: device)
            hasClaim = cached != nil; envelope = cached?.envelope
            result = try app.devices.verificationResult(scope: scope, friend: friend.id, device: device)
        } catch { self.error = error.localizedDescription }
    }
    @MainActor private func prepare() async {
        guard !busy else { return }; busy = true; error = nil; defer { busy = false }
        do {
            let scope = try app.deviceScope(), repository = app.deviceRepository
            guard let sender = app.login?.id else { throw ClientError(message: "请先登录。") }
            envelope = try await app.devices.prepareEnvelope(scope: scope, sender: sender, friend: friend.id, device: device,
                fetchBundle: { try await app.authorized { try await repository.bundle(friend: friend.id, device: device.id, token: $0) } },
                claim: { try await app.authorized { try await repository.claim(friend: friend.id, device: device.id, token: $0) } })
            restore()
        } catch { self.error = error.localizedDescription }
    }
    @MainActor private func verify() {
        result = nil; error = nil; revealSecret = false
        do { result = try app.devices.verifyPrekey(scope: app.deviceScope(), friend: friend.id, device: device, json: json) }
        catch { self.error = error.localizedDescription }
    }
}
