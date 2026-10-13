import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Group {
            if app.login != nil {
                TabView {
                    NavigationStack { FriendsView() }
                        .tabItem { Label("好友", systemImage: "person.2.fill") }
                    NavigationStack { RequestsView() }
                        .tabItem { Label("申请", systemImage: "person.crop.circle.badge.plus") }
                    NavigationStack { AccountView() }
                        .tabItem { Label("我的", systemImage: "person.crop.circle") }
                }
            } else {
                NavigationStack { AuthView() }
            }
        }
        .id(app.identity)
        .task(id: app.identity) { if app.login != nil { await app.chats.start() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { app.socket.disconnect() }
            if phase == .active && app.login != nil { Task { await app.chats.start() } }
        }
        .alert("安全存储", isPresented: Binding(get: { app.startupError != nil }, set: { if !$0 { app.startupError = nil } })) {
            Button("知道了") { app.startupError = nil }
        } message: { Text(app.startupError ?? "") }
    }
}

struct NoticeView: View {
    let text: String
    var isError = true
    var body: some View {
        Label(text, systemImage: isError ? "exclamationmark.circle" : "checkmark.circle")
            .font(.footnote).foregroundStyle(isError ? .red : .green)
            .textSelection(.enabled)
    }
}

struct PersonRow: View {
    let name: String
    let username: String
    var body: some View {
        HStack(spacing: 12) {
            Text(String(name.prefix(1)).uppercased()).font(.headline)
                .frame(width: 44, height: 44)
                .background(.indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 15))
                .foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.headline)
                Text("@\(username)").font(.subheadline).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
    }
}
