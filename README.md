# SRTStreamer（SRT推流）

iOS 15+ SwiftUI 应用，使用 HaishinKit 2.0.9 + SRTHaishinKit，以 caller 模式把摄像头+麦克风通过 SRT 推送到 MediaMTX。

## 构建（GitHub Actions）
1. 在 GitHub 新建仓库，把本目录全部内容（含 `.github/` 隐藏目录）上传到仓库根目录。
2. 推送后会自动运行 workflow；也可在 **Actions → Build unsigned IPA → Run workflow** 手动运行。
3. 运行完成后，在该次运行页面底部 **Artifacts** 下载 `SRTStreamer-ipa`，解压得到 `SRTStreamer.ipa`（未签名）。
4. 使用 AltStore / SideStore / 爱思助手 / Sideloadly 等工具签名安装。

## 使用
- 推流地址：`srt://8.148.79.198:8890?streamid=publish:live:push:密钥`（把“密钥”换成你自己的，建议只用英文数字）
- 延迟默认 200ms，分辨率 720p/1080p（竖屏），码率 2–6 Mbps，30fps，关键帧间隔 1 秒。
- 推流中屏幕常亮；画面左上角显示已送入编码器的视频帧数和 SRT 实际发送码率。

## OBS 拉流
媒体源（取消“本地文件”）输入：
`srt://IP:8890?streamid=read:live:push:密钥`

## 说明
旧版只发音频的原因：SRTStream.publish() 只有在调用时已收到视频帧才会把视频轨写入 TS。本版会先等摄像头画面到达再 publish。
