# 发布到 GitHub

1. 把 README、docs、RELEASE_NOTES 里的 `chenhao` 替换成 GitHub 用户名。
2. 新建仓库（建议公开、不勾选自动生成 README）。
3. 初始化并推送：

   ```bash
   cd TouchBarPal
   git init
   git add .
   git commit -m "TouchBarPal 1.0"
   git branch -M main
   git remote add origin git@github.com:chenhao/TouchBarPal.git
   git push -u origin main
   ```

4. 仓库 Settings：

   - Issues 开启
   - Discussions 可选
   - Actions 允许运行
   - 在 About 里填描述、网站（可选）和 topics：
     `macos`, `touchbar`, `macbook-pro`, `clipboard-manager`, `app-launcher`, `swift`

5. 打 tag 并创建 Release：

   ```bash
   git tag -a v1.0 -m "TouchBarPal 1.0"
   git push origin v1.0
   ```

   在 GitHub → Releases → Draft a new release：

   - Tag：`v1.0`
   - 标题：`TouchBarPal 1.0`
   - 说明：粘贴 `docs/RELEASE_NOTES_1.0.md`
   - 上传 `dist/` 下的 zip、dmg、SHA256SUMS.txt
   - 勾选 「Set as the latest release」

6. 检查 Release 页面里的 SHA-256 与上传文件一致。

## 仓库设置建议

- `main` 分支保护：要求 CI 通过。
- 关闭 Wiki，文档放在 `docs/`。
- 关闭自动合并，使用 PR 模板。

## 版本号

发新版时同时修改：

- `Resources/Info.plist` 的 `CFBundleShortVersionString` / `CFBundleVersion`
- `tools/package.sh` 的 `VERSION`
- `README.md` 版本徽章与下载链接
- 新增 `docs/RELEASE_NOTES_<version>.md`
