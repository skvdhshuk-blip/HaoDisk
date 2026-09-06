# GitHub Pages 主页

主页源码位于 `site/`，使用原生 HTML / CSS，无构建依赖或统计脚本。GitHub Pages 从独立的 `gh-pages` 分支根目录发布，包含 `.nojekyll`。应用主分支的构建和 QA 文件不会因此发布到网站。

## 发布

1. 修改 `site/`，本地运行 `python3 -m http.server 8074 --directory site`。
2. 检查桌面和手机宽度、图片、链接、键盘焦点及隐私说明。
3. 在单独的 `gh-pages` checkout 中同步 `site/` 内容，保留 `.nojekyll`，审核差异后提交并推送该分支。
4. 检查 GitHub 的 `pages build and deployment` 成功，再验证线上文件与本地一致。

2026-09-06 首次发布提交：`2ba06cd`。主页、隐私页、支持页、CSS 及两张图片均返回 HTTP 200，文件内容与本地一致；Chrome 桌面及 390 px 手机宽度验证无横向溢出。

`assets/app.jpg` 是 HaoDisk 0.2.4 运行自建 HaoDisk-Sample 目录的实际截图，不包含用户真实工作区。页面中的额外容量插图注明为示意。

目前商店入口显示“即将推出”。只有 Apple 审核通过且实际商店页面可用后，才更新为真实下载链接。

- https://skvdhshuk-blip.github.io/HaoDisk/
- https://skvdhshuk-blip.github.io/HaoDisk/privacy.html
- https://skvdhshuk-blip.github.io/HaoDisk/support.html
