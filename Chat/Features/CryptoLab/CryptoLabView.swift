import SwiftUI

struct CryptoLabView: View {
    @StateObject private var model = CryptoLabModel()
    @State private var confirmReset = false
    var body: some View {
        List {
            Section {
                Label("双端本地实验 · 无需服务器", systemImage: "lock.bubble")
                    .font(.headline)
                Text("真实加解密，模拟 A/B 两台设备。独立 Ed25519 验签 + 四次 X25519 + ChaCha20-Poly1305；不是完整 Signal 协议，没有 Double Ratchet。密钥仅驻留本页内存，关闭页面后不恢复。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("按顺序测试") {
                Button(model.generated ? "重新生成 A/B 密钥" : "1. 生成 A/B 密钥") {
                    if model.generated { confirmReset = true } else { model.generate() }
                }.accessibilityIdentifier("crypto.generate")
                Button(model.verified ? "2. 验签与身份核验通过" : "2. 验签并核对身份（本机模拟）") { model.verify() }
                    .disabled(!model.generated || model.verified).accessibilityIdentifier("crypto.verify")
                Button(model.ready ? "3. 双方共享秘密一致" : "3. 四次 DH，建立测试会话") { model.establish() }
                    .disabled(!model.verified || model.ready).accessibilityIdentifier("crypto.establish")
                if let error = model.error { NoticeView(text: error) }
            }
            Section("写一条消息") {
                Picker("发送方", selection: $model.sender) {
                    Text("A → B").tag(LabPeer.alice); Text("B → A").tag(LabPeer.bob)
                }.pickerStyle(.segmented)
                TextField("消息正文", text: $model.draft, axis: .vertical)
                    .lineLimit(2...4).accessibilityIdentifier("crypto.draft")
                Button("4. 加密到本地中转区") { model.encrypt() }
                    .disabled(!model.ready).accessibilityIdentifier("crypto.encrypt")
                Button("5. 接收端解密（待收 \(model.pending.count) 条）") { model.decrypt() }
                    .disabled(model.pending.isEmpty).accessibilityIdentifier("crypto.decrypt")
            }
            Section("聊天框 · 仅显示认证通过的消息") {
                if model.messages.isEmpty { Text("解密成功后，消息将显示在这里。")
                    .font(.footnote).foregroundStyle(.secondary) }
                ForEach(model.messages) { message in
                    HStack {
                        if message.from == .alice { Spacer(minLength: 32) }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(message.from.rawValue) → \(message.from.other.rawValue) · 已验证解密")
                                .font(.caption2).foregroundStyle(.secondary)
                            Text(message.text).textSelection(.enabled)
                        }
                        .padding(12)
                        .background(message.from == .alice ? Color.indigo.opacity(0.12) : Color.gray.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 14))
                        if message.from == .bob { Spacer(minLength: 32) }
                    }.listRowSeparator(.hidden)
                }
            }
            Section("负向测试") {
                ForEach(LabAttack.allCases) { attack in
                    Button("测试：\(attack.rawValue)") { model.attack(attack) }
                        .disabled(attack == .signature ? !model.generated : !model.ready)
                        .accessibilityIdentifier("crypto.attack.\(attack.id)")
                }
                Button("测试：重复投递") { model.replay() }.disabled(model.messages.isEmpty)
            }
            Section("查看公开数据") {
                DisclosureGroup("身份指纹（SHA-256）") { code(model.fingerprints) }
                DisclosureGroup("公钥包与签名（Base64）") { code(model.publicDetails) }
                DisclosureGroup("握手公开材料") { code(model.handshakeDetails) }
                DisclosureGroup("模拟服务器能看到的密文信封") { code(model.envelopeDetails) }
            }
            Section("过程记录") {
                ForEach(Array(model.events.enumerated()), id: \.offset) { _, event in
                    Text(event).font(.footnote).textSelection(.enabled)
                }
            }
        }
        .navigationTitle("加密实验")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("重新生成会清空本次密钥、信封和聊天记录。", isPresented: $confirmReset) {
            Button("重新生成", role: .destructive) { model.generate() }
        }
    }
    private func code(_ text: String) -> some View {
        Text(text).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
    }
}
