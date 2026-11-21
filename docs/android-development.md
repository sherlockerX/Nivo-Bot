# Nivo Bot Android开发指南

本指南针对`sherlockerX/Nicholasx`分支，保留上游Android目录和协议。iOS、Web运行端和云端不在本次构建验证范围。

GitHub上的自动触发、APK下载、测试范围和可选签名配置见[Android自动打包](android-ci.md)。

## 工具链与路径

|项目|配置|
|---|---|
|Gradle项目|`android/src/android/`|
|应用模块|`android/src/android/app/`|
|JDK|21，源码编译目标17|
|Gradle Wrapper|8.11.1|
|compileSdk / targetSdk / minSdk|36 / 35 / 26|
|NDK|27.2.12479018|
|CMake|3.22.1|
|正式设备ABI|arm64-v8a|
|界面测试ABI|x86_64，不能据此验证arm64沙盒|

配置以`app/build.gradle.kts`为准。Android Studio可直接打开Gradle项目。SDK与JDK通过环境变量传入，不提交`local.properties`。

## 首次构建

```bash
git clone --recurse-submodules https://github.com/sherlockerX/Nicholasx.git
cd Nicholasx
# Linux或WSL，先配置JDK、SDK、NDK、Go与gomobile
bash scripts/android/build-natives.sh
```

原生脚本准备PRoot、Alpine rootfs和rclone.aar。现有脚本包含按需下载和`gomobile@latest`，严格可复现发布还需固定Go工具链与来源摘要。不要用个人机器里的缓存二进制替代来源说明。

Windows PowerShell7：

```powershell
$env:JAVA_HOME = '你的JDK21目录'
$env:ANDROID_HOME = '你的Android SDK目录'
./scripts/android/Build-Android.ps1 -Target Check
./scripts/android/Build-Android.ps1 -Target Debug
```

脚本使用Wrapper JAR，兼容没有`gradlew.bat`的仓库。完整原生链建议在Linux/WSL准备；Windows可复用经验证的构建输入。`-Offline`只在依赖缓存完整时使用，`-GradleHome`可指定独立缓存。

## 测试与产物

```powershell
./scripts/android/Build-Android.ps1 -Target Test -Abi x86_64 -Isolated
./scripts/android/Build-Android.ps1 -Target DeviceTestApk -Abi x86_64 -Isolated
./scripts/android/Build-Android.ps1 -Target Release -RequireReleaseKey
```

单测覆盖nanoMuse模块及修改过的上游provider、sandbox、chat、sessions包。设备测试安装包以`.uitest`隔离，不在正式应用上写合成学习数据。

产物在`android/src/android/app/build/outputs/apk/`，报告在`app/build/reports/tests/`。`Build-Android.ps1 -Target Release`默认要求项目签名；Debug仍可用于开发。直接调用Gradle时用`-Pnm.requireReleaseKey=true`防止缺失配置时回退Debug。密钥应保存在仓库外，签名配置不得提交。

## Nivo的Android版本与签名 {#nivo-bot的android版本与签名}

Nivo开发版的Android包名为`io.github.nivo`，版本字段暂留`2.0.9(60)`。已发布的念步2.0.9使用`io.github.sherlockerx.nelan`，更早的版本使用`io.github.nanomuse.app`。三者可并存，签名相同也无法跨包覆盖升级或自动继承数据。下一次正式发布应提升版本和构建号，不替换已有2.0.9文件。已发布iOS包仍为`2.0.8(59)`，其Bundle ID没有更改。

版本号与应用ID由`app/build.gradle.kts`记录；`scripts/rebrand.py`的`ANDROID_VERSION_NAME`、`ANDROID_VERSION_CODE`及`ANDROID_APP_ID`须同步，完整生成入口会应用这些值。`--android-brand-only`只更新品牌资源，保留当前版本和安装身份。`VERSION_NAME`和`VERSION_CODE`也用于iOS源码生成，源码字段更新不改变已留存IPA。后续升级需递增Android内部编号；不要为升版本而更换证书。整个多平台仓库的`release-bump.sh`不是本分支Android单独发版入口。

两个Android更新入口均指向`sherlockerX/Nicholasx`，不再请求上游下载索引。版本栏使用独立缓存；既有`MOSAIC_OFFLINE`自动检查开关仍保留。尚未公开发布时，关于页可能显示无发行版或无法访问，不会虚构下载链接。

首次建立专用证书（只执行一次，已有文件会拒绝覆盖）：

```powershell
./scripts/android/New-ReleaseSigning.ps1 -KeyDirectory 'D:\PrivateKeys\Nicholasx' -JavaHome $env:JAVA_HOME
./scripts/android/Build-Android.ps1 -Target Release -SigningCredentialPath 'D:\PrivateKeys\Nicholasx\signing-credential.xml'
```

脚本创建RSA3072签名密钥、公钥证书和Windows DPAPI加密凭据，目录只允许当前用户和SYSTEM访问。`android/keystore.properties`只保存证书路径和别名，不存口令。构建时临时注入口令环境变量，结束后恢复。不得将密钥目录、凭据XML或签名配置打进开源包。凭据XML只能在原Windows用户和机器解密：迁移电脑前需在本机将口令转存密码管理器，并单独备份密钥；不能只复制XML就认为完成备份。

**包名与签名共同影响安装兼容性。**新包`io.github.nivo`有自己的私有目录、Keystore和权限。使用不同证书的同包名Debug和Release也不能直接互相覆盖。迁移仅使用[已支持的备份类别](releases/v2.0.9.md#moving-from-the-old-android-package)，保留旧应用查看心得、教练和专注历史等尚不能完整迁移的记录。

## 必须保持的约束

- 不移动`com.openminis.app`namespace或修改沙盒相对路径；新applicationId会改变Android私有目录根路径。新增功能放在`io.github.nanomuse.*`，上游修改带nanoMuse说明。
- Room的历史schema是测试资产，不按“旧文件”删除。
- 分词字典、KaTeX资源、模型目录和原生输入缺失会破坏构建或运行，应通过源码审计发现。
- 账号切换后旧页面不得写入；所有待办修改在事务内检查revision；专注实际耗时不由AI填写。
- 新增UI字符串覆盖现有语言目录；保持深浅主题、大字号、横屏和键盘可用。
- 日记关联与任务状态变更保持原子事务，避免只保存一半。

模块职责见[Android源码地图](android-code-map.md)，公开分发要求见[开源入口](../OPEN_SOURCE.md)。
