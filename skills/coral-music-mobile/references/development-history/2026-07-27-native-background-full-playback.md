# 2026-07-27 原生后台完整列表播放

## 目标

让 iOS 与 Android 在线 User API 歌单以逻辑队列原生连续播放；锁屏后下一首取链不经过 Flutter、Activity 或 WebView；失败不自动降低用户选定音质。

## 本次变更

- 新增 `NativePlaybackBridge`，Flutter 只下发队列、索引、模式、目标音质和传输指令，并镜像原生状态。
- iOS 新增 `NativePlaybackCoordinator`：`AVQueuePlayer` 保留当前/下一首，消耗窗口时原生即时取链并补齐；`MPRemoteCommandCenter` 的播放、暂停、上下曲、Seek 直接操作该队列。
- User API 返回显式低于请求的质量时失败为“该曲无此音质”；Flutter 控制器删除自动降质和失败自动跳过，仍可在同一质量刷新 URL 后重试一次。
- User API `MusicInfo` 现在会保留 `qualityMeta` 中声明的桌面兼容 `_qualitys`，即使曲目对象未填充 `availableQualities`。
- 取入并锁定 QuickJS-NG `v0.15.1`（commit `fd0a0210b7be00957751871e7e01b8291268fc29`），作为 Android JNI 运行时源码。
- Android 已新增 `NativePlaybackService`（Media3 `MediaSessionService`）和事件通道。服务保存整列逻辑 `coral://queue/<index>` URI；ExoPlayer 的 `ResolvingDataSource` 在每次打开媒体数据时通过共享、单线程的 `HeadlessUserApiRunner` / QuickJS JNI 即时取链，未回退到 Activity/WebView。显式低于目标质量的返回会停止并报“该曲无此音质”。
- Android 系统导航栏颜色现在跟随 Flutter `scaffoldBackgroundColor`，并关闭系统对比度强制，修复长屏手势导航区与深色页面底部不连续的问题。
- Android 原生服务在取链前立即进入前台，避免 `ForegroundServiceDidNotStartInTimeException` 导致约十秒后闪退；播放位置通过原生事件每 500ms 镜像回 Flutter，消除界面停在 `0:00` 而实际音频已播放的问题。
- Android 每个逻辑 `MediaItem` 现在携带标题、歌手、专辑、封面与可播放标记，系统 `MediaSession` 可直接驱动锁屏/控制中心媒体卡片；FLAC 采样率、总样本数和完整响应长度在原生首包中解析，切歌后保留真实格式信息，不展示探测 Range 请求导致的伪码率。

## 证据

- `flutter analyze`（桥接、User API、播放器与测试）通过。
- `flutter test test/player_controller_test.dart test/user_api_runner_test.dart` 通过（24 项）。
- `flutter build ios --profile` 通过，产物 `build/ios/iphoneos/Runner.app`。
- `flutter build apk --debug` 通过；APK 包含 `arm64-v8a`、`armeabi-v7a`、`x86_64` 的 `libcoral_quickjs.so`。32 位 x86 不在发布 ABI 范围且 QuickJS-NG x87 宏无法编译，已明确排除。
- Android 真机 `SM N986U`（Android 13，`R5CR70B7SMA`）已安装并启动 debug APK；浅色主题截图确认系统手势导航区与页面背景连续。
- 同一 Android 真机：原生 MediaSession 已报告 `PLAYING`、100 项队列和媒体描述（标题/歌手/专辑）。播放页实测首曲为 `1672 kbps · 48 kHz · SQ`；通过硬件“下一曲”切至另一曲后为 `781 kbps · 44 kHz · SQ`，位置和媒体元数据均已切换。此前的 `0:00`、采样率消失和错误 `1 kbps` 已在该回归中修复。
- 2026-07-27 iOS 环境：真实设备 `00008110-000A2C513E78801E`（iOS 26.4.2）已检测到；当前 `Runner.app` Profile 构建已成功安装、启动，`devicectl` 确认进程 PID `17551` 存活。该证据仅覆盖签名、安装、启动与原生桥接加载；尚未覆盖真实音源、锁屏、耳机、断网和 100 首 Soak。

## 未完成与门槛

- Android 已完成 `MediaSessionService + ExoPlayer ResolvingDataSource + QuickJS-NG JNI` 核心链路，但尚未用有效 User API 脚本在真机完成锁屏、耳机下一曲、短暂断网与 100 首无损 Soak，不能宣称该验收已通过。
- iOS 已完成编译验证，尚未使用真实音源在 iPhone 锁屏、耳机下一曲、短暂断网和 100 首无损队列下做 Soak；任何一次降质、页面回调切歌、无故停播或敏感日志均为失败。
- iOS 当前直接交给 `AVPlayerItem(url:)`；若真实源要求已加载流的 Range/Headers 刷新，再升级为 `coral://` + `AVAssetResourceLoaderDelegate`，不预先增加未证实的代理层。
