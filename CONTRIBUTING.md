# 贡献指南

感谢参与 TouchBarPal。提交前请阅读以下约定。

## 开发环境

- macOS 13+，带 Touch Bar 的 MacBook Pro
- Command Line Tools
- 按 [BUILDING.md](docs/BUILDING.md) 构建

## 提交前检查

```bash
./build.sh
.build/TouchBarPal.app/Contents/MacOS/TouchBarPal --selftest
```

自检必须全部通过。涉及以下区域时请手动回归：

- 主条 chip 的显示与点击
- 监控开关的快速连点
- 剪贴板文本 / 图片粘贴
- 返回与收起按钮
- 宠物墙滚动与切换

## 代码风格

- Swift 5，缩进 4 空格。
- 文件、类型、函数命名沿用现有风格。
- 注释解释「为什么」，不复述代码。
- 新逻辑尽量补一条 `--selftest` 用例。
- 不引入第三方依赖。

## 提交信息

一句话说明改了什么，例如：

```
Fix monitor chips lingering after being unchecked
```

## 范围

- 新功能请先开 Issue 讨论，避免大改后被拒。
- 保持 App 只做 Touch Bar 增强，不加账号、云同步、统计。
- 私有 API 的兼容处理优先于视觉重构。

## 许可

提交的代码以 MIT 许可发布。
