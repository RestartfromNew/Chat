import SwiftUI

/// 应用内提醒。展示模型只含好友 ID 和名称，不携带正文或密文。
struct IncomingMessageBannerPresenter: View {
  @ObservedObject var model: ChatCoordinator
  @ObservedObject var store: ChatStore
  let onOpen: (UUID) -> Void
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var seenIDs: Set<UUID> = []
  @State private var observedScope: String?
  @State private var banner: Banner?

  private struct Banner: Identifiable {
    let id = UUID()
    let friend: UUID
    let name: String
  }

  var body: some View {
    Group {
      if let banner {
        HStack(spacing: IncomingMessageBannerStyle.spacing) {
          Button {
            onOpen(banner.friend)
            self.banner = nil
          } label: {
            HStack(spacing: IncomingMessageBannerStyle.spacing) {
              ChatAvatarView(name: banner.name)
              VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: banner.name)
                  .font(IncomingMessageBannerStyle.titleFont)
                  .lineLimit(1)
                Text("你有未读消息")
                  .font(IncomingMessageBannerStyle.subtitleFont)
                  .foregroundStyle(.secondary)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          Button {
            self.banner = nil
          } label: {
            Image(systemName: "xmark")
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(.secondary)
              .frame(width: 44, height: 44)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("关闭提醒")
        }
        .padding(IncomingMessageBannerStyle.contentInset)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: IncomingMessageBannerStyle.cornerRadius))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .padding(.horizontal, IncomingMessageBannerStyle.horizontalInset)
        .padding(.top, 8)
        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
      }
    }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: banner?.id)
    .task(id: banner?.id) {
      guard let id = banner?.id else { return }
      do { try await Task.sleep(for: IncomingMessageBannerStyle.duration) }
      catch { return }
      if banner?.id == id { banner = nil }
    }
    .onReceive(store.$archive) { archive in
      let ids = Set(archive.messages.keys)
      defer { seenIDs = ids; observedScope = store.scope }
      // 账号切换和本地历史加载不弹窗，只提醒之后新增的未读消息。
      guard observedScope == store.scope, store.scope != nil, scenePhase == .active else { return }
      let incoming = archive.messages.values.filter {
        !seenIDs.contains($0.id) && !$0.outgoing && !store.readState.ids.contains($0.id)
          && $0.friend != store.visibleConversation
      }.max { $0.date < $1.date }
      guard let incoming,
            let friend = model.friends.first(where: { $0.id == incoming.friend }) else { return }
      let name = friend.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
      banner = Banner(friend: friend.id, name: name.isEmpty ? friend.username : name)
    }
    .onChange(of: store.visibleConversation) { _, visible in
      if banner?.friend == visible { banner = nil }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase != .active { banner = nil }
    }
    .onReceive(store.$readState) { readState in
      if let banner,
         readState.unreadCounts(in: Array(store.archive.messages.values))[banner.friend, default: 0] == 0 {
        self.banner = nil
      }
    }
  }
}
