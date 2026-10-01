# Sylphplay 手机版

Sylphplay 的移动端实现，使用 **Flutter** 开发，支持 **Android / iOS**。

与[桌面版](../README.md)共享同一产品定位：**音频 / 视频 / 图片三合一的本地播放器**，不联网、无广告、无在线曲库。

***

## 功能特性

- 音频 / 视频 / 图片本地播放，支持选择文件与文件夹并扫描本地媒体目录

- 播放队列：可持久化（重启保留），支持列表 / 网格视图

- 歌词：LRC 解析（含 GBK 编码兜底，兼容酷我等下载源）、逐字高亮、联网自动查找（LRCLIB）

- 音频可视化频谱

- 后台播放：锁屏 / 通知栏 / 耳机线控按键控制（基于 `just_audio_background` + `audio_session`）

- 深浅主题、播放倍速与实验特性设置

- 视频缩略图预览、文件信息查看

> 桌面版专有的「设为默认打开方式」与「强制对齐 DLC」在手机版不提供。

***

## 环境要求

- Flutter SDK（Dart `>=3.4.0`）

- Android：构建与运行无需额外工具链；运行时权限已适配 Android 13+ 的 `READ_MEDIA_*`

- iOS：需在 **macOS + Xcode** 上构建；后台音频已在 `ios/Runner/Info.plist` 声明 `UIBackgroundModes: audio`

***

## 快速开始

```bash
flutter pub get                  # 安装依赖
flutter run                      # 调试运行（连接设备/模拟器）

flutter build apk --release      # 构建 Android APK
flutter build ipa --release      # 构建 iOS 包（需 macOS + Xcode）
```

***

## 目录结构

```
lib/
├── main.dart            # 入口：初始化后台音频与音频会话
├── models/              # 数据模型（媒体项、应用设置）
├── state/               # 播放状态（playback）与应用状态（app_state）
├── logic/               # 歌词、自动查找、可视化、缩略图、媒体探测
├── theme/               # 主题
└── ui/                  # 界面（音频 / 视频 / 图片 / 队列 / 设置 / 信息）
android/                 # Android 工程
ios/                     # iOS 工程
assets/                  # 图标等静态资源
```

***

## 发布产物示例

`Sylphplay-1.0.0-Android.apk`、`Sylphplay-1.0.0-iOS.ipa`。