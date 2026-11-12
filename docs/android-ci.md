# Android自动打包

本仓库的`Android · Nivo APK`工作流会在`master`、`main`分支的Android源码、原生依赖或构建脚本更新时自动运行。Pull Request也会构建；只改README等文档不会触发。也可以进入仓库的**Actions → Android · Nivo APK → Run workflow**手动构建。

## 下载和安装

打开一次成功的运行，在页面下方的**Artifacts**下载`Nivo-Android-运行编号-尝试编号`并解压。GitHub要求登录后才能下载，产物保留30天。

|文件|用途|
|---|---|
|`Nivo-版本-内部编号-arm64-debug-signed.apk`|可安装测试包，应用ID带`.uitest`，独立于正式应用|
|`Nivo-版本-内部编号-arm64-unsigned.apk`|经过优化的未签名Release包，需本地签名后才能安装|
|`Nivo-版本-内部编号-arm64-release-signed.apk`|仅明确请求且配置好Secrets时生成的正式签名包|
|`SHA256SUMS`|解压后使用`sha256sum -c SHA256SUMS`核对APK|
|`build-info.json`|提交、运行链接、实际包名、版本、架构和测试数量|
|`*.signature.txt`|Android签名校验结果和公钥证书摘要，不含私钥|

自动构建不会创建GitHub Release，也不会替换网站下载。Debug测试包的数据独立，不能据此验证正式应用数据迁移；runner生成的Debug证书也不保证跨次一致。正式应用的后续更新必须继续使用原来的专用证书。

## 可选的正式签名

默认自动构建不需要任何Secrets。需要GitHub生成正式签名包时，维护者可在**Settings → Secrets and variables → Actions**添加：

- `NIVO_ANDROID_KEYSTORE_BASE64`：专用keystore文件的完整Base64编码。
- `NIVO_ANDROID_STORE_PASSWORD`：keystore口令。
- `NIVO_ANDROID_KEY_ALIAS`：证书别名。
- `NIVO_ANDROID_KEY_PASSWORD`：该密钥的口令。

添加Secrets意味着允许GitHub runner临时使用签名私钥，应由密钥持有者决定。本配置不会自动上传本机私钥，也不会创建或更换正式证书。不要把这些内容写入仓库、Issue或日志。

随后手动运行工作流，勾选`signed_release`。缺少Secrets会明确失败，不会回退Debug签名。签名文件只在runner临时目录创建，口令经当前构建步骤的环境变量提供，工作结束时清理。Pull Request和普通push不会读取正式签名材料。

## 构建与验证范围

工作流使用JDK21、Go1.26、Android SDK36、NDK27.2.12479018和CMake3.22.1。先构建PRoot、Alpine沙盒输入和rclone，再生成arm64的Debug与Release APK。原生缓存按源码及工具链版本失效，gomobile版本与rclone模块固定一致。

CI将Kotlin编译放在Gradle进程内，配置4GB堆并限制为2个worker，避免独立Kotlin守护进程的默认小堆在大型Compose源码上耗尽。该设置只在工作流中生效，本机Gradle配置不受影响。

工作流执行本分支相关的JVM单元测试，并编译Android设备测试源码；APK生成后再用`aapt`和`apksigner`核对身份、架构、版本及签名。测试报告和Release混淆映射单独保留14天。此流程不运行模拟器或真实手机，不能代替手机上的交互、后台恢复、沙盒与模型服务验收。

构建辅助脚本可在无Android SDK的环境独立验证：

```bash
python -m unittest discover -s scripts/android -p test_ci_helpers.py -v
```

本地构建和原有正式签名步骤见[Android开发指南](android-development.md)。
