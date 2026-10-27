import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var app: AppModel
  @State private var requestCount = 0
  @State private var selectedTab = 0
  @State private var conversationPath: [UUID] = []
  @AppStorage("chat.language") private var language = AppLanguage.chinese.rawValue
  @Environment(\.scenePhase) private var scenePhase
  var body: some View {
    Group {
      if app.login != nil {
        TabView(selection: $selectedTab) {
          NavigationStack(path: $conversationPath) {
            FriendsView(model: app.chats)
              .navigationDestination(for: UUID.self) { id in
                if let friend = app.chats.friends.first(where: { $0.id == id }) {
                  ConversationView(friend: friend, model: app.chats, store: app.chats.store)
                }
              }
          }
            .tabItem { Label("好友", systemImage: "person.2.fill") }
            .tag(0)
          NavigationStack { RequestsView(model: app.friendRequests) }
            .tabItem { Label("申请", systemImage: "person.crop.circle.badge.plus") }
            .badge(requestCount)
            .tag(1)
          NavigationStack { AccountView() }
            .tabItem { Label("我的", systemImage: "person.crop.circle") }
            .tag(2)
        }
      } else {
        NavigationStack { AuthView() }
      }
    }
    .overlay(alignment: .top) {
      if app.login != nil {
        IncomingMessageBannerPresenter(model: app.chats, store: app.chats.store) { friendID in
          selectedTab = 0
          conversationPath = [friendID]
        }
        .id(app.identity)
      }
    }
    .onChange(of: app.identity) { _, _ in
      conversationPath = []
      selectedTab = 0
    }
    .background(
      ConnectionStatusPresenter(model: app.chats, signedIn: app.login != nil, language: language)
    )
    .onReceive(app.friendRequests.$requests) { requestCount = $0.count }
    .id(app.identity)
    .task(id: app.identity) { if app.login != nil { await app.chats.start() } }
    .onChange(of: scenePhase) { _, phase in
      if phase == .background { app.chats.suspend() }
      if phase == .active && app.login != nil { Task { await app.chats.start() } }
    }
    .alert(
      "安全存储",
      isPresented: Binding(
        get: { app.startupError != nil }, set: { if !$0 { app.startupError = nil } })
    ) {
      Button("知道了") { app.startupError = nil }
    } message: {
      Text(LocalizedStringKey(app.startupError ?? ""))
    }
    .environment(\.locale, Locale(identifier: language))
  }
}
