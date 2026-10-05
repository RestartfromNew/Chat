# 验证记录

2026-10-05，Xcode 16.3，iPhone 16 Pro / iOS 18.4 Simulator。

- 应用及测试 Target 编译通过。
- 18 项 Swift Testing 单元测试全部通过：空响应、好友申请 None/数组兼容、申请 ID 与用户 ID 区分、GET/POST 适配、错误码、HTTP/1.1 分包及 chunked、TLS 地址限制、加密占位拒绝明文、Token 刷新合并、401 重试、离线保留凭据、无效刷新登出、刷新期间退出、切换服务器清除会话。
- 1 项 XCTest UI 测试通过：注册字段切换、空表单禁用提交、服务器设置拒绝 HTTP 地址、返回登录页。
- 已检查实际登录页截图，见 login-preview.png。

测试使用固定响应与注入的服务，未使用真实账户对公网服务执行注册、申请或 WebSocket 发送。完整业务联调按 README 的双账户步骤执行。

执行命令（项目目录内）：

```sh
xcodebuild -project Chat.xcodeproj -scheme Chat -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test -only-testing:ChatTests CODE_SIGNING_ALLOWED=NO
xcodebuild -project Chat.xcodeproj -scheme Chat -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test -only-testing:ChatUITests/ChatUITests/testRegistrationFieldsAndServerValidation CODE_SIGNING_ALLOWED=NO
```

界面测试要求当前模拟器未登录，且不修改现有服务器配置。
