# 0.2.5 清理条件修复

## 行为

| 场景 | 0.2.4 | 0.2.5 |
| --- | --- | --- |
| 普通项目中的 Library / library | 该目录和父目录被保护 | 允许清理 |
| 普通父目录包含应用或资料包 | 父目录被保护 | 不再仅因包含包而被保护；清理父目录会包含包 |
| 直接选择应用包、资料包及包内内容 | 禁止 | 保留 |
| /Library、/System、/Users/用户名/Library 及相应外置卷路径 | 禁止 | 保留 |
| 未完整读取、真实受保护子项、文件在扫描后变化 | 禁止 | 保留 |

路径判断保持纯字符串计算，不增加文件系统访问。普通包的限制仅存在于包和包内节点，不再混入向祖先汇总的受保护路径标记。清理前仍流式复核整个目标目录。

升级后重新扫描以生成新的临时索引；不复用跨启动扫描索引。

## 验证（2026-09-06）

- 修复前，项目 Library 和包含包的父目录回归测试失败；修复后通过。
- 38 项 Swift 核心测试、43 项 Xcode 测试全部通过，Release 通用归档成功。
- 覆盖真实 Library 路径、大小写、外置卷、路径规范化、包内保护、真正受保护子项仍阻止父目录。
- 覆盖先清理 library 再清理含包父目录的事务更新，以及包内文件变化后拒绝父目录清理。
- Developer ID 签名沙箱应用实际选择自建 Cleanup-025-QA 目录；Project 同时含 library 和 Build/Test.app，简介中的“加入待清理”可用。
- 实际将样本 library 移到系统废纸篓后，Project 从 8 KB 更新为 4 KB；继续将包含 Test.app 的 Project 移到废纸篓成功，根目录只剩 Keep（4 KB）。未调用手动重新扫描，未清空废纸篓，未清理用户工作区。
- 0.2.5（7）使用 Developer ID Application: Hao Wang (M2WM2NJP68) 签名，Apple 公证及 stapler 验证通过，Gatekeeper 返回 accepted / Notarized Developer ID。

本次提供本地签名包；GitHub 0.2.4 Release 和 App Store 待审核构建未替换。
