import SwiftUI

struct RequestsView: View {
  @EnvironmentObject private var app: AppModel
  @ObservedObject var model: FriendRequestsModel
  @State private var cancelID = ""
  @State private var confirmCancel = false
  var body: some View {
    List {
      if let error = model.error {
        Section {
          NoticeView(text: error)
          Button("重新加载") { Task { await model.refresh() } }
        }
      }
      if let notice = model.notice { NoticeView(text: notice, isError: false) }
      Section("收到的申请") {
        if model.requests.isEmpty && !model.loading && model.error == nil {
          Text("暂无待处理申请").foregroundStyle(RequestsViewStyle.secondaryColor)
        }
        if model.loading { ProgressView() }
        ForEach(model.requests, id: \.requestId) { request in
          FriendRequestRow(
            request: request,
            onAccept: { Task { await model.process(request.requestId, action: .accepted) } },
            onReject: { Task { await model.process(request.requestId, action: .rejected) } })
        }
      }
      Section {
        TextField("输入申请 request_id", text: $cancelID)
          .textInputAutocapitalization(.never).autocorrectionDisabled()
        Button("取消这条申请", role: .destructive) { confirmCancel = true }.disabled(
          UUID(uuidString: cancelID) == nil)
      } header: {
        Text("取消已发送申请 · 调试")
      } footer: {
        Text("当前后端不返回发送申请的 ID，也没有已发送申请列表。此操作需从后端取得 request_id，并且仅允许申请发起者取消。")
      }
    }
    .disabled(model.processing)
    .navigationTitle("好友申请")
    .task { await model.refresh() }
    .refreshable { await model.refresh() }
    .confirmationDialog("取消该好友申请？", isPresented: $confirmCancel) {
      Button("取消申请", role: .destructive) {
        if let id = UUID(uuidString: cancelID) {
          Task { await model.process(id, action: .cancelled) }
        }
      }
    }
  }
}
