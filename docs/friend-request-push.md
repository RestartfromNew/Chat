# 在线好友申请（2026-10-19）

对接后端 main `90bf9e9` 的 docs 12.2/12.3 和 UserHandler 推送实现。

- WebSocket `friend.request.received` 中的 `unprocessed_requests` 是单条增量，以 `request_id` 去重，`id` 是申请人编号。此事件不进入聊天业务响应队列，不发送 envelope ACK。
- SocketConsole 负责事件分流，FriendRequestsModel 管理申请共享状态，FriendRequestInbox 合并 HTTP 快照和在线增量，RequestsView 仅负责展示和操作。申请角标实时更新。
- 每次连接成功、进入申请页或下拉刷新，通过 `/fetch_unprocessed_friend_request` 补拉完整列表，兼容空列表字符串 `None`。服务端推送为尽力投递，不能替代 HTTP 补拉。
- 拉取期间收到的申请保留到快照合并后；重复申请更新同一项；本机已处理的申请不会被迟到快照或推送恢复。退出登录清空共享状态。
- 接受申请后自动刷新好友；启动任务正在执行时记录待刷新操作，待任务结束继续。409 `friend_request_already_processed` 会移除过期申请并刷新列表。
- 顶层好友加载提示绑定独立 loadingFriends 状态，在 HTTP 完成、失败或生命周期重置时关闭，后续密钥准备与重连不再让它持续转圈。

FriendPushTests 覆盖协议解析、去重、快照与推送交错、已处理申请防恢复、共享状态与退出清理、加载提示成功/失败/取消路径。线上账号之间的真实推送仍需联调。
