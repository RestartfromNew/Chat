# 按后端线程转交路径重写 iOS 建连

历史分析依据 GitHub main 8bf3d13，核对 main 初始化、TcpServer、ThreadPool、Connection、HttpParse、HttpSession、WebSocketPool、WebsocketWorker、WebSocketSession/Handler、Dispatcher 及 iOS 调用方。

## 实际路径

```text
main 创建并初始化 HTTP pool / WebSocket pool / business pool
TcpServer.acceptConnection
  → ThreadPool.task_queue → HTTP worker
  → Connection.read → HttpParse.parse → takeRequest
  → HttpSession 判断 Upgrade: websocket
       false → Router.route（/ws 在这里会得到 route_not_found）
       true  → PendingWebsocket 移交 Connection 和 HttpRequest
  → ThreadPool.worker → WebSocketPool.forward_connections
  → WebsocketWorker.transferSession → eventfd 唤醒 → handleWakeup
  → acceptingSessions 计算 Sec-WebSocket-Accept，发送 HTTP 101
  → socket 切 nonblocking，加入 WebSocket session map 和 epoll
  → handleReadable → FrameParse / ApplicationParse → Dispatcher
```

普通 Router 不需要添加一个返回 200 的 /ws 接口。客户端应发标准 HTTP Upgrade，等待 worker 返回 101，之后才发 WebSocket 帧。

## iOS 实现

WebSocketConnection.swift 独立负责连接。SocketConsole 管理界面状态与消息分发，AppModel 登录后直接发起握手并携带当前 Bearer；2026-10-12 已去掉额外 HTTP 验证前置步骤，实际业务鉴权在每帧 authorization 中，明确鉴权错误才刷新重试。

- 显式使用 GET 和无缓存请求；URLSessionWebSocketTask 生成标准 Upgrade、Connection、Sec-WebSocket-Key、Version，校验 Accept、管理 TLS 和帧掩码。
- 通过 URLSessionWebSocketDelegate.didOpen 完成异步 open，仅这个回调把界面改成“已连接”。不再把首次 Pong 当作握手成功条件，也不在握手前排队发送 Ping。
- 握手最长 20 秒；错误、关闭、取消只完成一次 continuation。
- 禁止重定向继续携带凭据；session 不使用 Cookie/缓存。
- 收帧循环仅在握手成功后启动；Ping 单独测试，send 需已连接。
- 每次连接独立实例和 generation，旧连接的回调不能修改新连接状态；退出/重连关闭旧 session。
- 保留 HTTP 状态诊断与加密帧分发。2026-10-12 已对齐新版：默认路径 `/websocket-test`，每条业务帧带 authorization；正式帧使用双方设备 ID，测试帧不需要设备字段。详见 [新版消息接口](websocket-encrypted-messages.md)。

## 验证

67 项 iOS 测试通过。其中使用真实本地 TCP listener 返回标准 WebSocket Upgrade：

- 接收到 GET /ws HTTP/1.1、Upgrade、Version 13 和测试用 Bearer。
- 服务器只返回 101，不回 Pong，客户端仍完成 open。
- 101 与首条文本帧一起到达时，首帧保留并可接收。
- HTTP 404 不进入已连接，状态码可读取。
- 静默握手超时，取消不会挂住。

另使用后端原始 HttpParse.cpp 独立编译测试，把标准请求以从 1 字节到完整请求长度的所有 chunk 大小分段传入，全部正确保留 Upgrade 与 Sec-WebSocket-Key。此测试只覆盖解析器；完整 epoll/eventfd 后端需在 Linux 部署环境验证。

## 仍需服务器验证

本次改动只写入 iOS；没有改写或部署远端 C++ 服务。此前公网 /ws 返回的 404 不能靠改客户端状态机强制变成 101。应在 HTTP Upgrade 判断、forward_connections 和 acceptingSessions 三个边界确认日志，才能确定线上请求停在哪一步。不能把当前本地测试通过称为线上连接已修复。

源码另外存在两个独立的服务器问题：Upgrade 分支绕过普通 Router 的鉴权，acceptingSessions 尚未检查 access token；Sec-WebSocket-Key 使用大小写敏感查找。上线业务推送前应在服务端完成鉴权并按 HTTP 规则处理头名称大小写。iOS 不会因此省略 Bearer，也不会伪造升级成功。

更新：2026-10-12 公网部署修复后，根路径已返回 101；同一 WebSocketConnection 原生探针握手与 Ping/Pong 均通过。上述 404 分析保留为历史排查记录。
