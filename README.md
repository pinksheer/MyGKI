# 固定版 GKI 5.10.236 构建

本仓库只构建一个目标：

| 项目 | 固定值 |
|---|---|
| 内核版本 | `5.10.236-android12-9-00003-gfb24cf99ad97-ab14313284` |
| 构建时间 | `Fri Jan 9 20:21:51 CST 2026` |
| AOSP 标签 | `android12-5.10-2025-05_r6` |
| AOSP common 提交 | `fb24cf99ad973cd4c7c7fa375c6053f939ef3a89` |
| Root 方案 | BakaSU（原 ReSukiSU） |
| 文件系统隐藏 | SuSFS |
| Unicode 修复 | `unicode_bypass_fix_6.1-.patch` |

## 构建

1. 打开仓库的 **Actions** 页面。
2. 选择 **Build fixed GKI 5.10.236 BakaSU SuSFS**。
3. 点击 **Run workflow**。
4. 构建完成后下载 `BakaSU-SuSFS-5.10.236-android12-9-ab14313284` 产物。

产物包含 AnyKernel3 刷入包、原始 `Image`、`Image.lz4`、构建信息和 SHA-256 校验值。

工作流会固定并核验内核、BakaSU、SuSFS 与 AnyKernel3 的提交。编译后还会从内核镜像中核验完整版本串和构建时间；任一值不一致都会直接失败，不会上传错误产物。

> 刷入自定义内核有无法启动和数据丢失风险。操作前请备份原厂 `boot.img` 和重要数据，并确认设备使用 Android 12 GKI 5.10。
