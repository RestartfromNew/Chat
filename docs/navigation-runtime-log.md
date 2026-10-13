# cannot add handler to 0 from 0 - dropping

2026-10-08，本机 Xcode 27.0 (27A266a)、iOS 27 模拟器复现。

这条消息是运行时系统日志，不是 Swift/C 编译警告。读取 Chat 进程的统一日志，4 条匹配记录的源都是：

- senderImagePath: /System/Library/Frameworks/QuartzCore.framework/QuartzCore
- subsystem: com.apple.coreanimation
- category: API
- messageType: Error

使用独立 App（不引用 Chat 代码，也没有网络、密钥、Keychain）做 A/B 复现，每次启动观察两秒：

```swift
// 0 条匹配日志
WindowGroup { Text("Plain view probe") }

// 2 条匹配日志，源同为 QuartzCore
WindowGroup { NavigationStack { Text("System navigation probe") } }
```

现阶段没有验证过的公开 API 能修复系统内部这条日志。项目保留标准 NavigationStack，不用私有 API、更换整个导航架构或关闭所有系统日志来掩盖问题。因此日志仍可能出现；本次不能声称已消除系统缺陷。

排查业务时可以在 Xcode 控制台过滤这条具体消息（只影响显示），保留其他错误；是否真正消失需要在更新后的 Xcode/iOS runtime 上重新运行最小复现。不要把它当作签名验证失败或 prekey 领取失败；这两类错误在应用界面中单独显示。

Apple 开发者论坛也有 Xcode 27 NavigationStack 的相同复现报告（社区报告，不是 Apple 官方修复承诺）：
https://developer.apple.com/forums/topics/developer-tools-and-services/developer-tools-and-services-xcode?page=6&sortBy=lastUpdated&sortOrder=DESC
