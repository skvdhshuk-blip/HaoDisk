# HaoDisk 隐私政策 / Privacy Policy

生效日期：2026-09-06

HaoDisk 在你的 Mac 上分析你选择的文件夹。应用不收集、上传、出售或共享个人数据，不包含广告、追踪、遥测或第三方分析 SDK，也不要求创建账号。

## 本地处理

- 扫描读取文件名、路径、类型、大小和文件身份 / 修改时间，用于统计、显示和清理前核对；不读取文件正文。
- 扫描结果只保存在当前进程内存中，不写入历史数据库。
- 应用会在自身沙箱内保存最近一次选择的文件夹授权书签，方便下次使用。该记录不上传。
- 菜单中的“忘记文件夹授权”会删除此记录并释放当前访问。退出应用也会结束本次运行的访问。
- 清理仅在你检查并确认清单后调用 macOS 的移到废纸篓功能。应用不会清空废纸篓。

## 系统权限

访问范围由 macOS 的文件夹选择器与 App Sandbox 控制。某些系统保护目录仍可能无法读取。应用不会要求管理员权限、完整磁盘访问、辅助功能或网络访问。

## 联系

可通过 [GitHub Issues](https://github.com/skvdhshuk-blip/HaoDisk/issues) 提交问题。请勿在公开 Issue 中附带个人文件清单、私人路径或其他敏感内容。你主动提交到 GitHub 的信息由 GitHub 按其政策处理。

## English

HaoDisk analyzes folders you choose locally on your Mac. It does not collect, transmit, sell, or share personal data. It has no accounts, advertising, tracking, analytics SDKs, or network entitlement.

It reads file metadata to calculate sizes and verify items before a user-confirmed move to Trash. It does not read file contents. Scan results stay in memory. The most recent folder permission bookmark is stored in the app's sandbox and can be removed using “忘记文件夹授权” (Forget Folder Access). HaoDisk never empties Trash.

Questions may be submitted through the repository's public GitHub Issues. Do not include private file listings or sensitive information.
