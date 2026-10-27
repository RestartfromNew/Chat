import SwiftUI

struct AuthView: View {
  @EnvironmentObject private var app: AppModel
  @State private var registration = false
  @State private var email = ""
  @State private var password = ""
  @State private var username = ""
  @State private var displayName = ""
  @State private var busy = false
  @State private var error: String?
  @State private var notice: String?
  @State private var settings = false

  var body: some View {
    Form {
      Section {
        AuthIntroductionView()
        Picker("账户操作", selection: $registration) {
          Text("登录").tag(false)
          Text("注册").tag(true)
        }.pickerStyle(AuthViewStyle.pickerStyle)
      }
      Section(LocalizedStringKey(registration ? "创建账户" : "欢迎回来")) {
        TextField("邮箱", text: $email).keyboardType(.emailAddress)
          .textContentType(.emailAddress).textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        SecureField("密码", text: $password).textContentType(registration ? .newPassword : .password)
        if registration {
          TextField("用户名，例如 alice_chat", text: $username)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
          TextField("显示名称，例如 Alice", text: $displayName).autocorrectionDisabled()
        }
      }
      if registration {
        Section {
          Text("用户名：3–30 位小写字母、数字、下划线或点。显示名称：3–20 位英文字母、数字或下划线。密码：6–20 位，包含大小写字母、数字和特殊字符，不含空格。")
            .font(AuthViewStyle.footnoteFont).foregroundStyle(AuthViewStyle.secondaryColor)
        }
      }
      Section {
        if let error { NoticeView(text: error) }
        if let notice { NoticeView(text: notice, isError: false) }
        Button {
          Task { await submit() }
        } label: {
          HStack {
            Spacer()
            if busy { ProgressView() }
            Text(LocalizedStringKey(registration ? "创建账户" : "登录")).fontWeight(
              AuthViewStyle.buttonWeight)
            Spacer()
          }
        }.disabled(
          busy || email.isEmpty || password.isEmpty
            || (registration && (username.isEmpty || displayName.isEmpty)))
      }
      Section {
        LanguagePicker()
        Label(app.configuration.baseURL, systemImage: "server.rack").font(
          AuthViewStyle.footnoteFont)
        Button("服务器设置") { settings = true }
        NavigationLink("本地加密实验（无需登录）") { CryptoLabView() }
      } footer: {
        Text("登录后自动连接并准备加密会话。")
      }
    }
    .disabled(busy)
    .background(OperationStatusPresenter(title: busy ? (registration ? "正在创建账户…" : "正在登录…") : nil))
    .navigationTitle("Chat")
    .sheet(isPresented: $settings) {
      NavigationStack { ServerSettingsView(configuration: app.configuration) }
    }
  }
  @MainActor private func submit() async {
    busy = true
    error = nil
    notice = nil
    defer { busy = false }
    do {
      let mail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if registration {
        _ = try await app.auth.register(
          email: mail, password: password,
          username: username.trimmingCharacters(in: .whitespacesAndNewlines),
          displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines))
        registration = false
        notice = "注册成功，请使用刚创建的账户登录。"
      } else {
        try await app.signIn(email: mail, password: password)
      }
      password = ""
    } catch { self.error = error.localizedDescription }
  }
}

struct ServerSettingsView: View {
  @EnvironmentObject private var app: AppModel
  @Environment(\.dismiss) private var dismiss
  @State var configuration: ServerConfiguration
  @State private var error: String?
  var body: some View {
    Form {
      Section {
        TextField("HTTPS 地址", text: $configuration.baseURL)
          .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
        TextField("WebSocket 路径", text: $configuration.webSocketPath)
          .textInputAutocapitalization(.never).autocorrectionDisabled()
      } header: {
        Text("服务器")
      } footer: {
        Text("默认根路径 /。HTTPS 使用系统证书校验。修改配置会退出当前账户。")
      }
      Section {
        Toggle("使用当前 GET + JSON Body 接口", isOn: $configuration.legacyGETBodies)
      } header: {
        Text("后端兼容")
      } footer: {
        Text("适用于用户搜索和 Token 刷新。仅当后端已将这两个接口改为 POST 时关闭。")
      }
      if let error { Section { NoticeView(text: error) } }
    }
    .navigationTitle("服务器设置")
    .toolbar {
      ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
      ToolbarItem(placement: .confirmationAction) {
        Button("保存") {
          do {
            try app.saveConfiguration(configuration)
            dismiss()
          } catch { self.error = error.localizedDescription }
        }
      }
    }
  }
}
