import SwiftUI

struct RequestsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var requests: [FriendRequest] = []
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?
    @State private var cancelID = ""
    @State private var confirmCancel = false
    var body: some View {
        List {
            if let error { Section { NoticeView(text: error); Button("重新加载") { Task { await load() } } } }
            if let notice { NoticeView(text: notice, isError: false) }
            Section("收到的申请") {
                if requests.isEmpty && !busy && error == nil { Text("暂无待处理申请").foregroundStyle(.secondary) }
                if busy { ProgressView() }
                ForEach(requests, id: \.requestId) { request in
                    VStack(alignment: .leading, spacing: 12) {
                        PersonRow(name: request.displayName, username: request.username)
                        if !request.message.isEmpty { Text(request.message).font(.subheadline) }
                        HStack {
                            Button("接受") { Task { await process(request.requestId, action: .accepted) } }.buttonStyle(.borderedProminent)
                            Button("拒绝", role: .destructive) { Task { await process(request.requestId, action: .rejected) } }.buttonStyle(.bordered)
                        }
                        Text("申请 ID：\(request.requestId.uuidString.lowercased())")
                            .font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }.padding(.vertical, 6)
                }
            }
            Section {
                TextField("输入申请 request_id", text: $cancelID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("取消这条申请", role: .destructive) { confirmCancel = true }.disabled(UUID(uuidString: cancelID) == nil)
            } header: { Text("取消已发送申请 · 调试") } footer: { Text("当前后端不返回发送申请的 ID，也没有已发送申请列表。此操作需从后端取得 request_id，并且仅允许申请发起者取消。") }
        }
        .disabled(busy)
        .navigationTitle("好友申请")
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog("取消该好友申请？", isPresented: $confirmCancel) {
            Button("取消申请", role: .destructive) {
                if let id = UUID(uuidString: cancelID) { Task { await process(id, action: .cancelled) } }
            }
        }
    }
    @MainActor private func load() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let repo = app.friends
            requests = try await app.authorized { try await repo.requests(token: $0) }
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    @MainActor private func process(_ id: UUID, action: FriendAction) async {
        guard !busy else { return }
        busy = true; error = nil; notice = nil
        defer { busy = false }
        do {
            let repo = app.friends
            try await app.authorized { try await repo.process(requestID: id, action: action, token: $0) }
            requests.removeAll { $0.requestId == id }
            notice = action == .accepted ? "已接受申请，可在好友页下拉刷新。" : action == .rejected ? "已拒绝申请。" : "已取消申请。"
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}
