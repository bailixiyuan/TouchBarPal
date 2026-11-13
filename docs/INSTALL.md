# 安装与卸载

## 适配系统

| 项目 | 要求 |
| --- | --- |
| macOS | 13.0 Ventura 及以上；1.0 在 macOS 26.7.3 验证 |
| 硬件 | 带 Touch Bar 的 MacBook Pro（Intel / Apple Silicon） |
| 架构 | Universal 2（`arm64` + `x86_64`） |
| 权限 | 辅助功能（粘贴 / 快捷键）、定位服务（天气） |

没有 Touch Bar 的 Mac 可以安装，但看不到工具条。

## 从 Release 安装

1. 从 [Releases](../../../releases/tag/v1.0) 下载 `TouchBarPal-1.0-universal.dmg`。
2. 双击打开，把 **TouchBarPal** 拖到「应用程序」文件夹。
3. 在「应用程序」里右键 **TouchBarPal** →「打开」。
   如果仍被拦截，执行：
   ```bash
   xattr -dr com.apple.quarantine /Applications/TouchBarPal.app
   open /Applications/TouchBarPal.app
   ```
4. 打开「系统设置 › 隐私与安全性 › 辅助功能」，点 `+` 添加
   `/Applications/TouchBarPal.app` 并勾选。没有这一步，点剪贴板条目只会复制，不会自动粘贴。
5. 需要天气定位时，在「隐私与安全性 › 定位服务」中允许 TouchBarPal。
6. 状态栏出现 Touch Bar 图标。点它 →「显示 Touch Bar 面板」。
7. 确认 Touch Bar 处于「App Controls with Control Strip」模式：
   系统设置 › 键盘 › Touch Bar 显示 →「App 控制」。

### 校验下载

```bash
shasum -a 256 ~/Downloads/TouchBarPal-1.0-universal.dmg
```

与 Release 页面公布的值比较。

## 首次使用

1. 点状态栏图标 →「打开设置…」。
2. 在「工具栏」选择要显示的 App 和数量。
3. 在「监控」按需打开天气 / 电池 / CPU / 内存。
4. 在「通用」里可以开启登录启动、导入宠物、查看诊断。

## 从源码安装

```bash
git clone https://github.com/chenhao/TouchBarPal.git
cd TouchBarPal
./install.sh
```

`install.sh` 会构建、复制到 `/Applications`、移除 quarantine 标记并启动。

## 卸载

```bash
cd TouchBarPal
./uninstall.sh
```

或手动：

```bash
osascript -e 'tell application id "com.local.touchbarpal" to quit'
rm -rf /Applications/TouchBarPal.app
rm -f ~/Library/LaunchAgents/com.local.touchbarpal.plist
rm -rf ~/Library/Application\ Support/TouchBarPal
defaults delete com.local.touchbarpal
```

最后到「系统设置 › 隐私与安全性 › 辅助功能」移除旧条目。

## 常见问题

### 打开时提示「无法验证开发者」

App 使用本地签名、未公证。右键 →「打开」，或执行上面的 `xattr` 命令。

### 工具条不出现

- 确认点过状态栏图标 →「显示 Touch Bar 面板」。
- 确认 Touch Bar 显示模式是「App 控制」。
- 退出 App 后重新打开；`pkill -x TouchBarPal` 后等 2 秒再启动。
- 系统大版本升级后私有 API 可能失效，见 README 的「已知限制」。

### 点剪贴板不会自动粘贴

到「辅助功能」里删除旧条目，再重新添加并勾选。重新编译或换了签名后，系统会认为它是新 App。

### 快捷键页是空的

- 快捷键来自前台 App 的菜单栏；先切到目标 App 再打开该页。
- 确认辅助功能已授权。
- 有些 App 的菜单项没有快捷键，或使用自绘菜单，不会显示。
