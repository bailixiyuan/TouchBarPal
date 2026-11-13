# 从源码构建

## 环境

- macOS 13.0 及以上
- 带 Touch Bar 的 MacBook Pro（运行和调试需要硬件）
- Xcode Command Line Tools；完整 Xcode 不是必需
- Swift 5.9+（随 CLT 提供）

检查工具链：

```bash
xcode-select -p
swiftc --version
```

## 构建

```bash
git clone https://github.com/chenhao/TouchBarPal.git
cd TouchBarPal
./build.sh
```

产物：`.build/TouchBarPal.app`。

发布用 Universal 2：

```bash
./build.sh --universal
lipo -info .build/TouchBarPal.app/Contents/MacOS/TouchBarPal
```

## 调试

直接运行构建产物可以打开调试页：

```bash
pkill -x TouchBarPal; sleep 2
TBP_START_PAGE=clip .build/TouchBarPal.app/Contents/MacOS/TouchBarPal
```

`TBP_START_PAGE` 可取 `main`、`clip`、`apps`、`phrases`、`pets`、`shortcuts`。

其它调试变量：

| 变量 | 作用 |
| --- | --- |
| `TBP_IMPORT_PET=<folder>` | 启动时导入并选中一只宠物 |
| `TBP_TYPE_DEMO=<text>` | 启动后向当前 App 输入文本 |
| `TBP_PET_STRESS=1` | 宠物压力测试 |

命令行辅助：

```bash
# 打印前台 App 的菜单快捷键
.build/TouchBarPal.app/Contents/MacOS/TouchBarPal --dump-shortcuts

# 按标题执行一条快捷键
.build/TouchBarPal.app/Contents/MacOS/TouchBarPal --press-shortcut "全部最小化"
```

## 自检

```bash
.build/TouchBarPal.app/Contents/MacOS/TouchBarPal --selftest
```

不需要图形界面。改动布局、剪贴板、快捷键或设置后请先跑一遍。

## 签名

构建脚本优先使用本机的 `TouchBarPal Local Signing` 证书；没有则退回 ad-hoc 签名。

为什么不用 hardened runtime：全局 Touch Bar 依赖私有 API
`NSTouchBar.presentSystemModalTouchBar(_:placement:systemTrayItemIdentifier:)`，
hardened runtime 下会失败。

稳定性建议：创建一次自签名证书并长期复用。ad-hoc 签名每次构建都会变 cdhash，
会静默失效辅助功能授权。

用 Xcode 创建：Xcode › Settings › Accounts › Manage Certificates › `+` ›
Apple Development，或钥匙串访问 › 证书助理 › 创建证书，名称填
`TouchBarPal Local Signing`，类型选「代码签名」。

## 打包发布物

```bash
./tools/package.sh
```

生成到 `dist/`：

- `TouchBarPal-1.0-universal.zip`
- `TouchBarPal-1.0-universal.dmg`
- `SHA256SUMS.txt`

脚本会重新做 Universal 构建、签名检查，并输出每个文件的 SHA-256。
把这三个文件一起上传到 GitHub Release。

## 目录与模块

见 [README 的目录结构](../README.md#目录结构)。

## 提交前

1. `./build.sh`
2. `--selftest` 全部通过
3. 手动检查主条 chip、监控开关、剪贴板粘贴和返回按钮
4. 不提交 `.build/`、`dist/`、`.DS_Store`
