import SwiftUI

struct ConversationView: View {
  @EnvironmentObject private var app: AppModel
    //以下三个从外部传入，共享的协调对象和存储对象
  let friend: ChatUser
  @ObservedObject var model: ChatCoordinator
  @ObservedObject var store: ChatStore
  // 未来从用户资料接口传入 URL；目前 nil 不会发起头像请求。
  var ownAvatarURL: URL? = nil
  var friendAvatarURL: URL? = nil
  @State private var text = ""
  @FocusState private var isComposerFocused: Bool
  @State private var showsAttachmentNotice = false
  @State private var followsInitialBottom = true
  @State private var userIsScrolling = false
  @State private var isAtBottom = false
  @State private var isVisible = false
  @Environment(\.scenePhase) private var scenePhase
  private let bottomAnchor = "conversation-bottom"
  private var ownAvatarName: String {
    guard let login = app.login else { return "" }
    return login.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? login.username : login.displayName
  }
  private var friendAvatarName: String {
    friend.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? friend.username : friend.displayName
  }
  // 手势结束或被取消时自动归零，时间列随之隐藏。
  @GestureState(resetTransaction: Transaction(animation: .easeOut(duration: MessageBubbleViewStyle.restoreDuration)))
  private var timestampReveal: CGFloat = 0
  private var messages: [ChatMessage] {
      //s....value为止为内存中的消息，.filter保留当前好友的消息，.sort进行排序，message得到数组
    store.archive.messages.values.filter { $0.friend == friend.id }.sorted { $0.date < $1.date }
  }
  // 正常等待解密不占布局空间；只有实际失败才显示错误气泡。
  private var failedIncoming: [ChatInboxItem] {
    store.archive.inbox.values.filter {
      !$0.decrypted && $0.error != nil
        && store.archive.peers[$0.envelope.senderDeviceId]?.user == friend.id
    }.sorted {
      if $0.envelope.senderDeviceId == $1.envelope.senderDeviceId {
        return $0.envelope.seq < $1.envelope.seq
      }
      return $0.envelope.senderDeviceId.uuidString < $1.envelope.senderDeviceId.uuidString
    }
  }
    
  var body: some View {
    VStack(spacing: ConversationViewStyle.sectionSpacing) {
      ScrollViewReader { reader in
        ScrollView {
          VStack(spacing: 0) {
          LazyVStack(spacing: ConversationViewStyle.messageSpacing) {
            if messages.isEmpty && failedIncoming.isEmpty {
              ContentUnavailableView(
                "你们已经是朋友了，开始聊天吧！", systemImage: "bubble.left.and.bubble.right",
                description: Text("消息将在本机加密后发送。"))
            }
            ForEach(messages) { message in
                //显示气泡
              MessageBubbleView(
                message: message,
                canRetry: message.outgoing
                  && store.archive.outgoing.values.contains(where: {
                    $0.messageId == message.id && $0.receipt == nil
                      && $0.errorCode != "envelope_conflict"
                      // 未收到回执不代表失败；网络异常可能没有业务错误码。
                      && ($0.errorCode != nil || message.status == "发送未完成，点按重试")
                  }),
                isBusy: model.busy,
                timestampReveal: timestampReveal,
                avatarName: message.outgoing ? ownAvatarName : friendAvatarName,
                avatarURL: message.outgoing ? ownAvatarURL : friendAvatarURL,
                onRetry: { Task { await model.retry(message.id) } }
              )
              .id(message.id)
            }
            ForEach(failedIncoming, id: \.envelope.envelopeId) { item in
              IncomingMessageErrorBubbleView(
                detail: item.error ?? "",
                avatarName: friendAvatarName,
                avatarURL: friendAvatarURL
              )
            }
          }
          .padding(.all, ConversationViewStyle.contentInset)
          .contentShape(Rectangle())
          .simultaneousGesture(
            DragGesture(minimumDistance: MessageBubbleViewStyle.dragThreshold)
              .updating($timestampReveal) { value, reveal, _ in
                let movement = value.translation
                // 只响应以向左为主的拖动，竖向滚动和下拉刷新仍交给 ScrollView。
                guard movement.width < 0,
                  abs(movement.width) > abs(movement.height) * MessageBubbleViewStyle.horizontalDominance else { return }
                reveal = min(-movement.width, MessageBubbleViewStyle.timestampRevealWidth)
              }
          )
          // 独立于懒加载消息的真实列表末尾，包含底部 padding 和错误气泡。
          Color.clear.frame(height: 1)
            .id(bottomAnchor)
            .accessibilityHidden(true)
          }
        }
          // 首次进入直接从底部展示历史，不从第一条消息开始。
          .defaultScrollAnchor(.bottom, for: .initialOffset)
          .defaultScrollAnchor(followsInitialBottom ? .bottom : nil, for: .sizeChanges)
          .onAppear {
            followsInitialBottom = true
            isVisible = true
            store.visibleConversation = friend.id
            markVisibleMessagesRead()
          }
          .onDisappear {
            isVisible = false
            if store.visibleConversation == friend.id { store.visibleConversation = nil }
          }
          .onScrollPhaseChange { _, phase in
            // 用户主动翻阅历史后停止首次定位，避免被拉回底部。
            if phase == .interacting {
              userIsScrolling = true
              followsInitialBottom = false
            } else if phase == .idle {
              userIsScrolling = false
              followsInitialBottom = isAtBottom
              markVisibleMessagesRead()
            }
          }
          .onScrollGeometryChange(for: CGSize.self) { geometry in
            CGSize(width: geometry.containerSize.height, height: geometry.contentSize.height)
          } action: { _, _ in
            // LazyVStack 首次测量和导航过渡会继续改变高度，随布局校正到底。
            if followsInitialBottom {
              scrollToLatest(using: reader)
              markVisibleMessagesRead()
            }
          }
          .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentSize.height - geometry.visibleRect.maxY <= 24
          } action: { _, atBottom in
            isAtBottom = atBottom
            if userIsScrolling { followsInitialBottom = atBottom }
            if atBottom { markVisibleMessagesRead() }
          }
          .scrollDismissesKeyboard(.interactively)
          .padding(.bottom, ConversationViewStyle.composerGap)
          .contentShape(Rectangle())
          .simultaneousGesture(TapGesture().onEnded { isComposerFocused = false })
          .refreshable { await model.sync() }
          .onChange(of: messages.map(\.id), initial: true) { old, current in
            let previous = Set(old)
            let added = messages.filter { !previous.contains($0.id) }
            if followsInitialBottom || added.contains(where: \.outgoing) {
              followsInitialBottom = true
              scrollToLatest(using: reader)
            }
          }
          .onChange(of: scenePhase) { _, phase in
            if phase == .active { markVisibleMessagesRead() }
          }
          .overlay(alignment: .bottomTrailing) {
            if !followsInitialBottom && store.unreadCounts[friend.id, default: 0] > 0 {
              Button {
                followsInitialBottom = true
                scrollToLatest(using: reader)
              } label: {
                Label("新消息", systemImage: "arrow.down")
                  .font(.subheadline.weight(.semibold))
                  .padding(.horizontal, 14)
                  .padding(.vertical, 10)
                  .background(.regularMaterial, in: Capsule())
              }
              .tint(.indigo)
              .padding(.trailing, 16)
              .padding(.bottom, ConversationViewStyle.composerGap + 8)
            }
          }
          .onChange(of: isComposerFocused) { _, focused in
            if focused { followsInitialBottom = true; scrollToLatest(using: reader) }
          }
          // 键盘出现及输入框增高都会缩小可视区域；在新布局中再次定位。
          // 不使用固定延时，避免键盘动画完成后消息才突然跳动。
          .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.height
          } action: { _ in
            if isComposerFocused && followsInitialBottom { scrollToLatest(using: reader) }
          }
      }
      if let error = model.error {
        NoticeView(text: error).padding(.horizontal, ConversationViewStyle.contentInset)
      }
      MessageComposerView(
        text: $text, isBusy: model.busy, inputFocus: $isComposerFocused,
        onAttachment: {
          isComposerFocused = false
          showsAttachmentNotice = true
        }
      ) {
        let draft = text
        Task {
          if await model.send(draft, friend: friend), text == draft { text = "" }
        }
      }
    }
    .alert("添加附件", isPresented: $showsAttachmentNotice) {
      Button("知道了", role: .cancel) {}
    } message: {
      Text("图片和文件发送功能尚未开放。")
    }
    .background(ConversationViewStyle.background)
    .navigationTitle(friend.displayName).navigationBarTitleDisplayMode(
      ConversationViewStyle.titleDisplayMode
    )
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          Task { await model.sync() }
        } label: {
          Image(systemName: "arrow.clockwise")
        }.disabled(model.busy)
      }
      ToolbarItem(placement: .topBarTrailing) {
        NavigationLink {
          FriendDetailView(user: friend)
        } label: {
          Image(systemName: "person.crop.circle")
        }
      }
    }
    .task { await model.start() }
  }

  private func markVisibleMessagesRead() {
    guard isVisible, scenePhase == .active, isAtBottom else { return }
    store.markRead(friend: friend.id)
  }

  private func scrollToLatest(using reader: ScrollViewProxy) {
    guard !messages.isEmpty || !failedIncoming.isEmpty else { return }
    reader.scrollTo(bottomAnchor, anchor: .bottom)
  }
}
