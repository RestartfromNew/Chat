import SwiftUI

struct FriendsView: View {
  @EnvironmentObject private var app: AppModel
  @ObservedObject var model: ChatCoordinator
  @ObservedObject private var store: ChatStore
  @State private var search = ""
  @State private var adding = false
  init(model: ChatCoordinator) {
    self.model = model
    self.store = model.store
  }

  // 一次遍历生成每位好友的最新明文摘要；未解密信封不会出现在列表。
  private var latestMessages: [UUID: ChatMessage] {
    store.archive.messages.values.reduce(into: [:]) { latest, message in
      if let previous = latest[message.friend],
         previous.date > message.date || (previous.date == message.date && previous.id.uuidString > message.id.uuidString) {
        return
      }
      latest[message.friend] = message
    }
  }
  private func filtered(latest: [UUID: ChatMessage]) -> [ChatUser] {
    model.friends.filter {
      search.isEmpty || $0.username.localizedCaseInsensitiveContains(search)
        || $0.displayName.localizedCaseInsensitiveContains(search)
    }.sorted {
      let left = latest[$0.id]?.date ?? .distantPast
      let right = latest[$1.id]?.date ?? .distantPast
      if left != right { return left > right }
      let order = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
      return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
    }
  }
  var body: some View {
    let latest = latestMessages
    let users = filtered(latest: latest)
    let unread = store.unreadCounts
    List {
      if model.waitingForNetwork && !model.loadingFriends {
        Label("正在后台连接，网络恢复后自动更新。", systemImage: "wifi")
      }
      if let error = model.error {
        Section {
          NoticeView(text: error)
          Button("重试") { Task { await model.reloadFriends() } }
        }
      }
      if model.loadingFriends && model.friends.isEmpty { ProgressView("正在获取好友…") }
      if !model.loadingFriends && !model.waitingForNetwork && model.friends.isEmpty
        && model.error == nil
      {
        ContentUnavailableView(
          "还没有好友", systemImage: "person.2", description: Text("点击右上角 +，通过用户名发送申请。"))
      }
      Section {
      ForEach(users) { user in
        NavigationLink(value: user.id) {
          ConversationRowView(user: user, latestMessage: latest[user.id], unreadCount: unread[user.id, default: 0])
        }
        .listRowInsets(FriendsViewStyle.rowInsets)
        .listRowSeparator(.hidden, edges: .top)
        .listRowSeparator(user.id == users.last?.id ? .hidden : .visible, edges: .bottom)
        .listRowBackground(
          UnevenRoundedRectangle(
            topLeadingRadius: user.id == users.first?.id ? FriendsViewStyle.listCornerRadius : 0,
            bottomLeadingRadius: user.id == users.last?.id ? FriendsViewStyle.listCornerRadius : 0,
            bottomTrailingRadius: user.id == users.last?.id ? FriendsViewStyle.listCornerRadius : 0,
            topTrailingRadius: user.id == users.first?.id ? FriendsViewStyle.listCornerRadius : 0
          ).fill(FriendsViewStyle.rowBackground)
        )
      }
      }
      .listSectionSeparator(.hidden, edges: .all)
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(FriendsViewStyle.background)
    .contentMargins(.top, 12, for: .scrollContent)
    .contentMargins(.horizontal, FriendsViewStyle.listHorizontalInset, for: .scrollContent)
    .navigationTitle("好友")
    .searchable(text: $search, prompt: "筛选现有好友")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          adding = true
        } label: {
          Image(systemName: "plus")
        }.accessibilityLabel("添加好友")
      }
    }
    .task { await model.start() }
    .refreshable { await model.reloadFriends() }
    .sheet(isPresented: $adding) { NavigationStack { AddFriendView() } }
  }
}

struct FriendDetailView: View {
  let user: ChatUser
  var body: some View {
    Form {
      Section { PersonRow(name: user.displayName, username: user.username) }
      Section { NavigationLink("设备与会话准备") { FriendDevicesView(friend: user) } }
      Section("用户 ID") { CodeText(Text(user.id.uuidString.lowercased())) }
      Section {
        Text("聊天消息加密后发给好友的有效设备。已存储不代表对方已读；下拉聊天页可拉取新消息。")
          .font(FriendsViewStyle.footnoteFont).foregroundStyle(FriendsViewStyle.secondaryColor)
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
        TextField("例如 bob_chat", text: $username).textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .onChange(of: username) { _, _ in
            found = nil
            sent = false
            error = nil
          }
        Button("查找用户") { Task { await search() } }.disabled(
          username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      if let found {
        Section {
          PersonRow(name: found.displayName, username: found.username)
          TextField("申请说明", text: $message, axis: .vertical).lineLimit(FriendsViewStyle.inputLines)
          if sent {
            NoticeView(text: "申请已保存，等待对方处理。", isError: false)
          } else {
            Button("发送好友申请") { Task { await send(found) } }
          }
        } footer: {
          Text("申请说明是服务端可读文本，请勿填写敏感内容。")
        }
      }
      if busy { ProgressView() }
      if let error { NoticeView(text: error) }
    }
    .disabled(busy)
    .navigationTitle("添加好友")
    .toolbar {
      ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.disabled(busy) }
    }
  }
  @MainActor private func search() async {
    busy = true
    error = nil
    found = nil
    sent = false
    defer { busy = false }
    do {
      let repo = app.friends
      found = try await app.authorized {
        try await repo.search(
          username: username.trimmingCharacters(in: .whitespacesAndNewlines), token: $0)
      }
    } catch is CancellationError {} catch { self.error = error.localizedDescription }
  }
  @MainActor private func send(_ user: ChatUser) async {
    busy = true
    error = nil
    defer { busy = false }
    do {
      let repo = app.friends
      try await app.authorized {
        try await repo.request(friendID: user.id, message: message, token: $0)
      }
      sent = true
    } catch is CancellationError {} catch { self.error = error.localizedDescription }
  }
}
