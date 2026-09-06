# HaoDisk 开发计划

目标：交付可以在开启沙箱的 macOS App 中实际使用的目录空间分析与手动清理流程，并建立 GitHub public 仓库。App Store 提交是后续发布步骤，本次不把本地构建称为审核通过。

0.2 的商业化目标、质量门槛与逐项验收见 [COMMERCIAL_ACCEPTANCE.md](COMMERCIAL_ACCEPTANCE.md)。

## 产品范围

| 项目 | 首版决定 | 验收 |
| --- | --- | --- |
| 开发套件 | Swift、SwiftUI、AppKit、Foundation；macOS 14+ | 标准 Xcode 工程可构建，无第三方运行时依赖 |
| 布局 | 紧凑工具栏与路径导航，左侧原生目录表格，右侧矩形占比图；磁盘详情按需展开 | 双击下钻、返回、选择联动、列表模式 |
| 授权 | NSOpenPanel 选择目录，security-scoped bookmark 保存最近一次授权 | 重启恢复、失效重新选择、忘记授权 |
| 扫描 | 后台遍历、进度、取消、权限问题统计 | 包含隐藏文件，不跟随符号链接，不跨挂载卷 |
| 统计 | 默认已分配大小，可切换逻辑大小 | 硬链接去重；APFS 克隆共享块不承诺精确可释放空间 |
| 清理 | 手动加入待清理清单，检查范围和文件身份，确认后移到废纸篓 | 禁止授权根、系统与应用资料路径、应用包和不完整目录；逐项反馈 |
| 隐私 | 无账号、网络、遥测、文件上传 | 最小 entitlements 和隐私清单 |

## 实现与验证顺序

1. 建立扫描、面积布局、清理策略与对应测试 → 验证字节统计、取消、链接和边界。
2. 完成原生界面、授权生命周期与扫描任务管理 → Debug / Release 构建。
3. 用隔离测试目录运行已签名沙箱 App → 验证选择器、图表、下钻、清理确认和书签恢复。
4. 记录 App Store 准备事项、构建方法和限制 → 检查隐私声明与实际代码一致。
5. 创建并推送公开 HaoDisk 仓库 → 核对远端提交、可见性和 CI。

## 计量与权限原则

- 磁盘容量来自卷信息；图表仅代表已授权且可读取的文件。两者不会强行对齐。
- 未读完、取消、达到内存保护上限都标记为不完整；不把缺失项目宣称为空。
- 不读取文件正文，不主动下载 iCloud 占位文件；不扫描符号链接的目标。
- 废纸篓本身仍占空间，直到用户在 Finder 中清空。应用不提供永久删除。
- 不申请 root、完整磁盘访问、Apple Events、辅助功能、网络或临时沙箱例外。

## Apple 依据

- [访问沙箱外文件与保存授权](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- [App Review Guidelines 2.4.5](https://developer.apple.com/app-store/review/guidelines/)
- [FileManager.trashItem](https://developer.apple.com/documentation/foundation/filemanager/trashitem(at:resultingitemurl:))
- [Required reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
