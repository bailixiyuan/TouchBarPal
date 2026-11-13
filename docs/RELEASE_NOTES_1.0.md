# TouchBarPal 1.0

TouchBarPal 的第一个公开版本：给带 Touch Bar 的 Mac 增加一条常驻工具条。

## 下载

- `TouchBarPal-1.0-universal.dmg`（推荐）
- `TouchBarPal-1.0-universal.zip`

Universal 2（`arm64` + `x86_64`），要求 macOS 13.0+ 与 Touch Bar 硬件。

## 功能

- **剪贴板历史**：最近 40 条文本 / 图片，点击粘贴，自动去重，忽略密码管理器标记。
- **快捷输入**：短语管理，点一条即输入。
- **App 启动器**：最近使用 / 自定义列表，运行状态绿点，点前台 App 收起。
- **快捷键提示**：读取前台 App 菜单快捷键，点提示直接执行。
- **系统监控**：天气、电池、CPU、内存逐项开关。
- **宠物**：内置水豚、导入自定义宠物、可滚动的宠物墙。
- **设置**：权限引导、登录启动、诊断信息。

## 1.0 的稳定性改进

- 剪贴板 chip 改为自绘子视图，消除标题更新后的重影。
- 监控开关批量提交并防抖，快速连点不卡顿。
- 按 Touch Bar 实际宽度重新测量容量，图标不会压住宠物或越界。
- 取消勾选的监控 chip 立即隐藏，不与应用图标重叠。
- 宠物墙只在宠物列表变化时重建，降低内存与 CPU。

## 安装

见 [docs/INSTALL.md](https://github.com/chenhao/TouchBarPal/blob/main/docs/INSTALL.md)。

App 为本地签名、未公证。首次打开请右键 →「打开」，或：

```bash
xattr -dr com.apple.quarantine /Applications/TouchBarPal.app
```

然后到「系统设置 › 隐私与安全性 › 辅助功能」勾选 TouchBarPal。

## 已知限制

- 全局 Touch Bar 使用私有 API，系统大版本升级后可能失效。
- 未公证，无法上架 Mac App Store。
- 快捷键与粘贴依赖辅助功能权限。

**完整说明：** https://github.com/chenhao/TouchBarPal
