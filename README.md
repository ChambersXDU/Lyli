# Lyli

**让 Apple Music 的歌词出现在 macOS 菜单栏和桌面上。**

[![Release](https://img.shields.io/github/v/release/ChambersXDU/Lyli?label=release)](https://github.com/ChambersXDU/Lyli/releases/latest) [![CI](https://github.com/ChambersXDU/Lyli/actions/workflows/ci.yml/badge.svg)](https://github.com/ChambersXDU/Lyli/actions/workflows/ci.yml) ![macOS](https://img.shields.io/badge/macOS-14%2B-blue) ![Apple Silicon](https://img.shields.io/badge/Apple_Silicon-arm64-black) [![License](https://img.shields.io/badge/license-GPL--3.0-green)](LICENSE)

简体中文 · [English](README.en.md) · [下载最新版](https://github.com/ChambersXDU/Lyli/releases/latest) · [反馈问题](https://github.com/ChambersXDU/Lyli/issues)

Lyli 是为 Apple Music 打造的原生 macOS 歌词应用。它跟随播放进度显示歌词，支持逐字高亮、译文、时间轴校准，以及歌词的搜索、选择与编辑。自动匹配优先读取 Apple Music 已缓存的官方歌词，未命中时再从多个歌词来源查找。

## 功能

| 功能 | 说明 |
| --- | --- |
| 菜单栏与桌面歌词 | 选择适合自己的显示位置，调整字体、颜色、宽度与对齐方式。 |
| 整行与逐字同步 | 支持 LRC、YRC 和 Apple TTML 时间轴；歌词具备有效逐字时间时启用高亮。 |
| 长音辉光 | 桌面歌词与播放器弹窗中，持续至少 1.2 秒的中文单字或英文单词可缓慢发光、在词尾淡出；暂停及减少动态效果时关闭。 |
| Apple Music 官方缓存 | 通过歌曲 ID 关联本地缓存资料，校验歌名、歌手、专辑与时长后使用官方歌词。 |
| 多来源匹配 | 官方缓存未命中时，使用 LRCLIB、酷我、网易云、酷狗和 QQ 音乐；支持启用来源与匹配顺序设置。 |
| 译文与繁简转换 | 显示可用译文，并按需要切换中文简体或繁体。 |
| 时间轴校准 | 调整全局或单曲偏移，让歌词跟随当前播放。 |
| 歌词管理 | 搜索、预览、选择、编辑、删除与重新匹配；保护手动选择和校准过的歌词。 |
| 本地保存 | 已保存的歌词可以离线显示；支持开机启动与应用内更新检查。 |

## 安装

要求 **macOS 14 或更新版本、Apple Silicon（M 系列芯片）**，并使用 Music 应用播放音乐。当前发行包仅提供 arm64 版本。

1. 前往 [Releases 下载最新版](https://github.com/ChambersXDU/Lyli/releases/latest)，选择 `.dmg` 或 `.zip`。
2. 将 **Lyli.app** 放入“应用程序”文件夹并打开。
3. 按系统提示允许 Lyli 控制 Music；也可在“系统设置 → 隐私与安全性 → 自动化”中检查授权。
4. 在 Music 中播放歌曲，然后在 Lyli 设置中选择菜单栏或悬浮歌词显示。

如果 macOS 因应用验证提示阻止打开，可在“系统设置 → 隐私与安全性”中查看该应用的打开选项。发行包附带 ZIP 的 SHA-256 校验文件。

## 如何获取歌词

自动匹配先检查 Apple Music 的本地歌词缓存。可靠命中后直接保存并显示；没有缓存或歌曲归属证据不足时，继续使用其他已启用来源。官方歌词只有整行时间时，先尝试复用已保存的其他来源逐字歌词，再在后台查询已启用来源，显示官方歌词无需等待后台补齐。

Music 必须先获取过这首歌的歌词，**打开 Music 的歌词面板可以帮助生成缓存**。缓存本身只有整行时间时，Lyli 显示整行歌词；包含有效词或音节时间时，才显示逐字高亮。

读取仅针对 `~/Library/Caches/com.apple.Music/Cache.db` 和 `fsCachedData` 中的响应正文，不读取 Cookie、认证请求头，也不重放 Apple 签名请求。切歌后会进行有限次数的补读，适配 Music 稍晚写入的歌词。Apple 的缓存格式可能随系统版本变化；本地读取失败时自动回退。

融合以官方原文、译文和整行时间轴为准，只借用可靠对应的逐字时间。繁简体、标点和空格差异可对齐，分行差异仅在已有词边界上拆分或合并；缺行、实词不同或时间越界的行仍按整行显示。歌曲版本、全曲时间一致性或对应关系不足时放弃融合，不用字符插值猜逐字时间。歌词管理会标出逐字时间的来源。没有合适结果时，同一应用会话内不会反复查询同一份官方歌词与来源配置。

如果某首歌匹配不理想，可打开**歌词管理**搜索并选择候选，或编辑歌词与时间偏移。手动选择、人工修正、指定来源、置顶及校准过的歌词不会被自动缓存匹配覆盖。网络歌词来源的可用性与歌词完整度取决于相应服务，匹配结果并不保证每首歌都准确。

## 开发与验证

使用 Xcode Command Line Tools 提供的 Swift 工具链。代码按 Swift Package 组织，最低部署目标为 macOS 14。

```sh
git clone https://github.com/ChambersXDU/Lyli.git
cd Lyli/lyli

# 编译候选应用，不替换现有安装
./build.sh --debug --dest /tmp/Lyli.app

# 核心自测与应用流程回归
./scripts/swiftpm.sh run lyli-selftest
./scripts/test-lyrics-workflows.sh
```

`./build.sh --debug` 会编译、安装并启动应用；`--no-restart` 只安装而不重启。`./build.sh` 默认使用优化后的 Release 构建，`./package.sh` 生成 arm64 发行包。编译缓存保存在 `lyli/.build`，重复开发时保留该目录可以复用缓存。

验证当前播放歌曲的真实 Apple Music 缓存：

```sh
./scripts/swiftpm.sh run lyli-selftest --apple-music-cache
```

该检查需要 Music 正在播放或暂停在某首歌，以及可用的自动化授权。输出歌曲资料、缓存命中结果和时间轴检查结果，不打印歌词正文。缓存未命中也可能只是缺少足够的歌曲资料，不等同于 Music 没有歌词。

歌词与设置默认保存在 `~/.config/lyli/`。核心代码位于 `lyli/Sources/LyliCore`，macOS 界面位于 `lyli/Sources/lyli`。

开发细节见 [Swift 包说明](lyli/README.md)、[歌词匹配](lyli/docs/lyric-matching.md)、[播放响应与效率](lyli/docs/playback-efficiency.md)、[歌词显示稳定性](lyli/docs/lyric-display-stability.md)及[构建性能](lyli/docs/build-performance.md)。

## 反馈

通过 [GitHub Issues](https://github.com/ChambersXDU/Lyli/issues) 反馈问题。歌词相关问题请附上 Lyli 版本、macOS 版本、歌名、歌手、专辑，以及问题涉及的歌词来源或显示方式；请不要上传完整的 Music 缓存数据库或认证信息。

## 来源与致谢

Lyli 基于 [Yudaotor/lyrimuse](https://github.com/Yudaotor/lyrimuse) 改造，由 [ChambersXDU](https://github.com/ChambersXDU) 维护。当前版本聚焦 Apple Music 的本地歌词获取、匹配与显示，感谢原项目提供的基础。

## License

本项目采用 [GNU GPL v3](LICENSE)。第三方代码及其许可见 [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES)。歌词和歌曲资料的权利归相应权利人所有，应用将歌词本地缓存用于个人显示。
