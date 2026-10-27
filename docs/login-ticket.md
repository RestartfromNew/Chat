# 两阶段设备登录

对接后端 main `be6dfe7`，以 backend-api 第 5、13、21 节、main 路由和 LoginTicketResponse 为准。

1. POST /login_by_email 仅发送 email、password，接收 code、login_ticket、expires_in。票据仅驻留本次调用，不作为 Bearer、不持久化。
2. 本机邮箱与服务器索引中已有已注册设备时，POST /device_verification，JSON 为 login_ticket、device_id。保留原设备私钥和 OPK。
3. 无已注册设备时，先把本地身份密钥和 signed prekey 存入 Keychain 的待登录命名空间，再 POST /register_device。请求为 login_ticket 和原有六个公开密钥/名称字段，不携带 Bearer 或私钥。
4. 完成响应必须包含 id、device_id、active device_status、access_token、refresh_token。验证设备/账号匹配，保存设备和邮箱索引，再保存正式会话，最后进入主界面。刷新会话保留 device_id。
5. 主界面继续原来的好友拉取、OPK 上传、WebSocket 和信封流程。注册不再属于主界面的初始化步骤或手动设备按钮。

超时/500/不完整响应等可能已提交：保留私钥，将待注册记录标为 uncertain，阻止再次创建设备。当前后端没有恢复丢失注册响应的接口，需核实服务端记录。已有设备验证失败不自动改成注册；重新登录会取得新票据并仍验证原设备。明确的 4xx 拒绝（除 408/409）允许使用同一组本地密钥再次尝试。

新完成响应不包含 username/display_name，当前个人页暂以登录邮箱展示，不把邮箱伪装成用户名。服务端未提供资料时不额外猜测账号资料。非常旧的无邮箱索引设备不能从不含用户 ID 的票据推断账号；保留原私钥，遇到同账号已有其他设备记录时停止覆盖。

LoginTicketTests 验证新设备注册后再次登录走设备验证、私钥保持不变、未注册时无 OPK、注册超时阻止重复提交、明确拒绝可重试、设备验证失败不回退注册，以及公开完成接口的 JSON 和无 Bearer 请求。尚未使用真实账号执行线上注册/验证。
