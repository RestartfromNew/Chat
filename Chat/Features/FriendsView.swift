import SwiftUI

@MainActor
final class FriendsViewModel: ObservableObject {
    @Published var friends: [ChatUser] = []
    @Published var loading = false
    @Published var error: String?
    func load(_ app: AppModel) async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let repository = app.friends
            friends = try await app.authorized { try await repository.friends(token: $0) }
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

struct FriendsView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var model = FriendsViewModel()
    @State private var search = ""
    @State private var adding = false
    private var filtered: [ChatUser] {
        model.friends.filter { search.isEmpty || $0.username.localizedCaseInsensitiveContains(search) || $0.displayName.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        List {
            if let error = model.error { Section { NoticeView(text: error); Button("重试") { Task { await model.load(app) } } } }
            if model.loading && model.friends.isEmpty { ProgressView("正在获取好友…") }
            if !model.loading && model.friends.isEmpty && model.error == nil {
                ContentUnavailableView("还没有好友", systemImage: "person.2", description: Text("点击右上角 +，通过用户名发送申请。"))
            }
            ForEach(filtered) { user in
                NavigationLink { ConversationView(friend: user, model: app.chats, store: app.chats.store) } label: { PersonRow(name: user.displayName, username: user.username) }
            }
        }
        .navigationTitle("好友")
        .searchable(text: $search, prompt: "筛选现有好友")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("添加好友") }
        }
        .task { await model.load(app) }
        .refreshable { await model.load(app) }
        .sheet(isPresented: $adding) { NavigationStack { AddFriendView() } }
    }
}

struct FriendDetailView: View {
    let user: ChatUser
    var body: some View {
        Form {
            Section { PersonRow(name: user.displayName, username: user.username) }
            Section { NavigationLink("设备与会话准备") { FriendDevicesView(friend: user) } }
            Section("用户 ID") { Text(user.id.uuidString.lowercased()).font(.caption.monospaced()).textSelection(.enabled) }
            Section {
                Text("聊天消息加密后发给好友的有效设备。已存储不代表对方已读；下拉聊天页可拉取新消息。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("好友资料")
    }
}

struct AddFriendView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var message = "你好，我想添加你为好友。"
    @State private var found: ChatUser?
    @State private var busy = false
    @State private var error: String?
    @State private var sent = false
    var body: some View {
        Form {
            Section("按用户名精确查找") {
                TextField("例如 bob_chat", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onChange(of: username) { _, _ in found = nil; sent = false; error = nil }
                Button("查找用户") { Task { await search() } }.disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let found {
                Section {
                    PersonRow(name: found.displayName, username: found.username)
                    TextField("申请说明", text: $message, axis: .vertical).lineLimit(2...4)
                    if sent { NoticeView(text: "申请已保存，等待对方处理。", isError: false) }
                    else { Button("发送好友申请") { Task { await send(found) } } }
                } footer: { Text("申请说明是服务端可读文本，请勿填写敏感内容。") }
            }
            if busy { ProgressView() }
            if let error { NoticeView(text: error) }
        }
        .disabled(busy)
        .navigationTitle("添加好友")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.disabled(busy) } }
    }
    @MainActor private func search() async {
        busy = true; error = nil; found = nil; sent = false
        defer { busy = false }
        do {
            let repo = app.friends
            found = try await app.authorized { try await repo.search(username: username.trimmingCharacters(in: .whitespacesAndNewlines), token: $0) }
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    @MainActor private func send(_ user: ChatUser) async {
        busy = true; error = nil
        defer { busy = false }
        do {
            let repo = app.friends
            try await app.authorized { try await repo.request(friendID: user.id, message: message, token: $0) }
            sent = true
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}
