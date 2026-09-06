# Mac App Store 准备

0.2.4（构建 6）已于 2026-09-06 完成正式归档、App Store 分发签名和上传，Apple 已处理构建。已于当日 19:52（Asia/Shanghai）提交审核，Apple 当前状态为“等待审核”。审核通过后自动发布，尚未上架。

## 权限设计

| Entitlement | 用途 |
| --- | --- |
| `com.apple.security.app-sandbox` | Debug / Release 都启用 App Sandbox |
| `com.apple.security.files.user-selected.read-write` | 仅通过系统选择器授权用户目录，支持确认后的废纸篓操作 |
| `com.apple.security.files.bookmarks.app-scope` | 保存最近一个目录的访问授权 |

Release 禁止注入调试用基础 entitlement。正式分发包应没有 `get-task-allow`。工程不包含网络、Apple Events、辅助功能、root、临时沙箱例外、第三方安装器或更新器。

`NSAppDataUsageDescription` 解释用户主动选择范围内的其他应用资料分析；这不是绕过 macOS 权限的手段。Library / 应用资料包仅供分析，清理功能不修改其中内容。

## 授权流程

```mermaid
flowchart LR
  A[用户选择文件夹] --> B[系统文件选择器授权]
  B --> C[保存授权书签]
  C --> D[后台扫描和显示]
  D --> E[手动加入清单]
  E --> F[检查并确认]
  F --> G[复核文件和目录内容]
  G --> H[系统移到废纸篓]
  H --> I[事务更新临时索引与受影响目录]
  C --> J[下次用户点击继续]
  J --> K[解析并更新书签]
  K --> D
```

书签解析失败时要求重新选择；不使用普通路径字符串假装获得访问权限。扫描和清理期间保留授权，切换或忘记时释放。

## 隐私清单

| API 类别 | 理由 | 实际用途 |
| --- | --- | --- |
| DiskSpace | `85F4.1` | 向用户显示磁盘空间 |
| FileTimestamp | `3B52.1` | 用户授权目录内的文件元数据与清理前身份核对 |
| UserDefaults | `CA92.1` | 仅保存本 App 的目录授权书签 |

App Privacy 问卷按当前实现应选择“不收集数据”。发布前根据实际最终构建重新核对，后续新增 SDK 或网络功能需要同步更新。

## 本次发布记录

| 项目 | 当前状态 |
| --- | --- |
| Bundle ID | `com.haodisk.app`，已注册 |
| Apple App ID | `6809158350` |
| 版本 / 构建 | `0.2.4 / 6`，arm64 + x86_64 |
| 上传 | 2026-09-06 19:29（Asia/Shanghai）成功，Apple 已处理 |
| 签名 | Apple Distribution；安装包为 Mac Developer Installer 签名；无 `get-task-allow` |
| 价格 | 免费、无内购 |
| 供应范围 | 148 个国家或地区，排除欧盟 27 国，不自动添加未来地区 |
| 类别 / 年龄 | 工具 / 4+ |
| App 隐私 | 已发布“不收集数据”及隐私政策 URL |
| 出口合规 | 已回答不使用问卷列出的加密算法 |
| 截图 | 已上传 2560 × 1600 原生应用截图，内容为自建演示目录 |
| 发布方式 | 审核通过后自动发布 |
| 审核 | 2026-09-06 19:52 已提交，等待审核 |
| 提交 ID | `6de69278-abe1-48d7-9c63-9cb174d77bfe` |

- [主页](https://skvdhshuk-blip.github.io/HaoDisk/)
- [隐私政策](https://skvdhshuk-blip.github.io/HaoDisk/privacy.html)
- [支持页面](https://skvdhshuk-blip.github.io/HaoDisk/support.html)
- [App Store Connect](https://appstoreconnect.apple.com/apps/6809158350/distribution)

审核联系人姓名沿用 Hao Wang，电话和邮箱由用户补充，已保存并通过提交校验。这些资料只提交 Apple，不存入仓库或公开主页。

本地沙箱应用的功能验证见 0.2.4 验证报告。正式上传成功不等于 TestFlight 真机复验、Intel 实机验证或 Apple 审核通过；这些状态分别记录，不能互相替代。

## 审核说明草稿

HaoDisk is a local disk-space analyzer. Click “选择文件夹” to select a folder using the standard macOS Open panel. The app only scans the selected folder and displays file sizes in a list and treemap. It needs no login or network access.

To test cleanup, create a disposable file in a selected ordinary folder, select it and click the trash toolbar button (or press Command-Delete), review the listed paths, then explicitly click “移到废纸篓”. There is one review sheet and no default Return-key action for moving files. Multiple items can be queued through the context menu before review. The app uses FileManager.trashItem and never permanently deletes files or empties Trash. System folders, Library folders, app/data packages, and unreadable items are protected. Before moving a directory to Trash, the app streams its current contents and compares them with the scan index. Successful cleanup updates affected index records and ancestors without rescanning the whole authorized root; external changes require a manual rescan. The app stores a security-scoped bookmark only for the most recently selected folder; it can be removed from the toolbar menu.

## 参考

- [App Review Guidelines 2.4.5](https://developer.apple.com/app-store/review/guidelines/)
- [Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- [Required reason API reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons)

## GitHub 直装分发

2026-09-06 的 v0.2.4 GitHub ZIP 已替换为 `Developer ID Application: Hao Wang (M2WM2NJP68)` 签名版本，使用 Xcode 已登录账号的云托管证书。Apple 公证及 stapler 验证通过，Gatekeeper 返回 `accepted / Notarized Developer ID`，`syspolicy_check distribution` 全部通过。旧开发签名附件已移除。

直装版与商店版来自同一份 0.2.4（6）归档，保留原有三项沙箱权限。GitHub 公证与 App Store 审核是独立流程，重新签署直装包不会改变已提交审核的商店构建。

复用归档时，使用 `xcodebuild -exportArchive`，导出选项为 `method=developer-id`、`teamID=M2WM2NJP68`、`signingStyle=automatic`，并传入 `-allowProvisioningUpdates`。`destination=export` 导出签名应用，`destination=upload` 提交公证。公证通过后对导出应用执行 `xcrun stapler staple`，再进行严格签名、stapler、Gatekeeper 和分发检查，最后打 ZIP。下载解压后的应用也必须重复验证公证凭证。

[Apple Developer ID 分发说明](https://developer.apple.com/developer-id/) · [Xcode 公证流程](https://help.apple.com/xcode/mac/current/en.lproj/dev88332a81e.html)
