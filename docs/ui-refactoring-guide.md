# 页面层重构与学习地图

本次只重构展示层。Core 下的算法、网络、存储、认证与消息协调器，以及 CryptoLabModel 均保持原文件内容。保留发送后的草稿清空条件、按钮禁用条件、下拉同步、重试判定、生命周期调用和窗口触摸穿透逻辑。

## 从哪里开始读

1. `Chat/Features/ConversationView.swift`：查看页面如何组合组件，数据来自哪里，点击后调用哪个业务方法。
2. `Chat/UI/Components/MessageBubbleView.swift`：只读一条消息的展示。输入是消息、是否允许重试、是否忙碌及回调。
3. `Chat/UI/Styles/MessageBubbleViewStyle.swift`：修改颜色、圆角、间距、字体。
4. `Chat/UI/Components/ComponentPreviews.swift`：在 Xcode Canvas 打开气泡、输入区、人物与提示预览。使用虚构数据，无 AppModel、无服务器、无真实密钥。

## 三层职责

- Features：页面状态、导航、组织组件、调用现有业务方法。不要把密钥或网络处理移进组件。
- UI/Components：可复用的小视图。用普通属性接收显示内容，用 Binding 接收可编辑文字，用闭包传出点击事件。
- UI/Styles：外观配置。AppTheme.swift 提供全局颜色/字体默认值；各个 Style 文件引用默认值或提供独立值。

样式文件使用静态常量，修改源码后编译/刷新预览生效，不是运行时主题编辑器。采用系统语义字体和颜色，继续支持动态字体与深色模式。

## 修改入口

| 想修改什么 | 文件（均位于 Chat/ 下） |
|---|---|
| 全局默认主色、字体 | UI/Styles/AppTheme.swift |
| App 按钮与导航强调色 | UI/Styles/ChatAppStyle.swift |
| 聊天气泡颜色、圆角、内边距 | UI/Styles/MessageBubbleViewStyle.swift |
| 消息之间的间距、聊天页边距 | UI/Styles/ConversationViewStyle.swift |
| 输入框行数、发送图标字号、输入区边距 | UI/Styles/MessageComposerViewStyle.swift |
| 头像大小、背景、圆角 | UI/Styles/InitialAvatarStyle.swift |
| 人物行的姓名/用户名及排列 | UI/Styles/PersonRowStyle.swift |
| 错误/成功提示 | UI/Styles/NoticeViewStyle.swift |
| 好友申请行及按钮样式 | UI/Styles/FriendRequestRowStyle.swift |
| 登录页介绍图标与标题 | UI/Styles/AuthIntroductionViewStyle.swift |
| 登录表单样式 | UI/Styles/AuthViewStyle.swift |
| 加载浮层字体、背景材质、阴影 | UI/Styles/LoadingBannerStyle.swift |
| 好友、申请、设备、诊断、密钥实验页面 | UI/Styles/ 下同名 Style 文件 |
| 公钥、JSON、日志的可选中文字 | UI/Components/CodeText.swift（可传入独立 font） |

原来同一源文件里的页面仍共享对应文件的样式，例如 DeviceViewsStyle 对应本机设备和好友设备页面。组件拥有自己的样式，改组件样式会影响所有使用它的页面；需要独立外观时先增加具体角色属性，不要到处复制组件。

## 如何练习

气泡背景：修改 outgoingBackground / incomingBackground。
气泡圆角：修改 cornerRadius。
气泡文字与状态间隔：修改 contentSpacing。
消息行间距：修改 ConversationViewStyle.messageSpacing。
输入框最大行数：修改 MessageComposerViewStyle.inputLines。

`CGFloat? = nil` 表示沿用 SwiftUI 的系统默认内边距。改成具体数值（例如 20）即可单独覆盖。`.frame(width: 0, height: 0)` 之类的隐藏窗口锚点仍在生命周期适配器内，因为它是行为结构而不是可见页面装饰。

先只改一个属性，观察短消息、长消息和英文。再试深色模式和大字体。变更布局结构时改组件，变更外观数值时改 Style，变更页面导航时改 Features。

## 不应随样式修改的行为

- 不删掉发送回调中的 `text == draft`，防止旧发送任务清空用户刚输入的新内容。
- 不把本地可靠保存的返回值解释为对方收到或已读。
- 不移除 `.id(message.id)`，滚动定位依赖它。
- 不改变重试判定、`.disabled`、`.task`、`.refreshable` 的业务条件。
- CodeText 接收 Text，保持原文字的本地化和动态字符串语义；不要把服务器日志自动当作翻译键。

本次没有改变界面设计，也没有新增线上请求。保留现有滚动策略和业务状态展示；后续 UX 改进可以在这套结构上单独完成。
