# 验证记录

最近更新：2026-11-05（Asia/Shanghai）。macOS 记录为 2026-11-04，Android 为本次 1.0.1 验证。

## macOS

- Swift 6.4.2 / Apple Command Line Tools 构建 Release 成功；目标为 macOS 13+ / arm64。
- `dist/拾流.app` 已启动并检查界面，截图为 `dist/Flow-macOS.png`。
- `codesign --verify --deep --strict` 通过，采用本地 ad-hoc 签名；Info.plist 检查通过。未做 Developer ID 签名和 Apple 公证。
- 7 组核心检查通过：URL 与参数安全、结构化进度和中文路径、历史恢复与损坏处理、大型元数据与子进程失败、启动前及运行中取消、真实视频下载与 MP3 提取、真实下载打断与 HTTP Range 续传。
- 集成测试使用 FFmpeg 生成的本地文件，最终续传输出与源文件逐字节相同。未逐一验证 YouTube、Bilibili 等外部站点。
- yt-dlp、FFmpeg、Deno 使用当前 Mac 已安装的版本，未打包进 `.app`。

命令：`bash scripts/build-macos.sh`、`python3 scripts/integration-test.py`。

## Android

- JDK 17、Gradle 8.11.1、AGP 8.9.2、Kotlin 2.1.20 构建成功。
- `:app:assembleDebug`、`:app:testDebugUnitTest`、`:app:lintDebug` 全部通过。
- 单元测试 8 项，失败 0 项。最终 Lint 报告为 `No issues found.`。覆盖整段分享文案、Markdown 链接、截图中的 xg 地址、普通分享地址、相对跳转、跳转上限、域名限制、引擎版本读取与错误提示。
- 包名 `app.flow.downloader`，版本 `1.0.1` / versionCode 2，minSdk 29，targetSdk 35。
- APK 包含 arm64-v8a、armeabi-v7a、x86_64；yt-dlp/Python/FFmpeg 运行时随 AAR 打包。
- APK Signature Scheme v2 验证通过，使用 Android Debug 开发签名。
- 在 **Android 15 / arm64 模拟器**实际安装了旧版 1.0.0，读出内置引擎 `2025.11.12`；覆盖升级后读出 `2026.10.26`，旧任务的 ID、状态和进度保持完整。
- 在模拟器 UI 中通过分享菜单传入本地测试视频，实际点击解析、加入队列，执行原生 yt-dlp 下载，确认生成 MediaStore URI、公共 `Download/拾流` 文件存在，并与源 MP4 逐字节一致。
- 在模拟器 UI 中选择 MP3，执行 FFmpeg 转换，导出后拉回文件，用 ffprobe 确认音频编码为 MP3。
- 设备内 instrumentation 测试通过：构造与官方网页捕获视频相同的元数据，经过 `DouyinSession.prepare`、`--load-info-json` 和原生引擎完成视频、MP3 下载；视频 SHA-256 与源文件一致。这个受控测试验证下载路径，不代表已通过抖音验证码。
- 用户给定的整段抖音文案在 UI 中被正确提取为短链接。实际访问后得到“需要新的浏览器验证状态”的中文提示；没有旧版本警告或 Unsupported URL。内置 WebView 能加载官方网页并显示站点验证码，未尝试自动完成验证码或登录。
- **给定抖音视频在测试网络中仍需要站点验证，未验证该具体视频在完成验证码后的下载成功率。没有进行安卓真机测试。**

本机 Java 到远程仓库的 TLS 连接不稳定，因此首次构建时使用 `.tools/` 中的临时本地依赖缓存转发脚本；本次通过相同仓库标识读取离线缓存完成构建。项目源码与 Gradle Wrapper 保留官方仓库配置，Wrapper 启用官方 Gradle 分发文件 SHA-256 校验。临时转发不属于应用运行时。

## 交付产物

- `dist/拾流.app`
- `dist/Flow-macOS.zip`
- `dist/Flow-Android-debug.apk`
- `dist/Flow-Android-1.0.1-debug.apk`（同一份新 APK，保留明确版本名）
- `dist/Flow-Android-1.0.1.png`（模拟器实际界面）
- `dist/Flow-source.zip`（应用源码、构建脚本、Gradle Wrapper、许可证与说明；不含构建缓存和二进制依赖的源码）
- `dist/SHA256SUMS.txt`

源码和许可证分发注意事项见 `THIRD_PARTY_NOTICES.md`。对外发布前还需要完整整理二进制依赖对应源码、平台发布签名和设备测试。
