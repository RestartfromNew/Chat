# WebSocket 鉴权更新（2026-10-20）

对接 main a06feb4。密码票据、设备验证/注册、WSS 根路径、Authorization 与 deviceID 握手头不变。公网仍使用 HTTPS/WSS 默认 443；8081 为后端直连端口，不改公网地址。

服务端把已识别业务路由的设备验证移入业务线程，仍可能返回无关联 ID 的公共 type=error。客户端保持单请求串行，发送、同步、ACK、测试帧都处理公共错误，在线推送单独分流。

- invalid_access_token / access_token_expired：保留刷新 Token 后重试一次。
- database_unavailable / retry_later / server_busy：后台退避恢复；待发消息保留原 ID 和密文，再次同步时允许重发，无需重新加密。
- accessToken_do_not_match_session / device_do_not_match_session / session_device_mismatch：结束当前请求并关闭连接，停止本轮自动重连，显示错误；不把它们当作 Token 过期，也不直接认定设备被撤销或删除私钥。
- internal_server_error / invalid_request 及其他业务拒绝：保留错误，不无限自动重试。

WebSocketAuthUpdateTests 覆盖公共错误跨路由解析、故障分类及会话身份错误结束请求并关闭连接。未用真实账号执行线上消息联调。
