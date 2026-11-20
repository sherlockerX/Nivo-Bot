# 产品网站截图来源

2026年11月19日重新构建Android维护源码，在独立、空白的模拟器中操作App并截图。官网首页、功能画廊、功能详情与分享预览共用这组六张原始PNG。

## 构建身份

|项目|实测值|
|---|---|
|Android源码提交|`88cbe9c991c1f0569bb8aec64e0410ae6ef551c4`|
|源码状态|拍摄时Android目录无未提交改动，网站修改不影响APK|
|版本|`2.0.5`，`versionCode 56`，当前维护源码，未修改版本号|
|变体|`debug`，`nm.uiTest=true`，`x86_64`|
|包名|`io.github.nanomuse.app.uitest`|
|APK大小|59,416,129字节|
|APK SHA256|`d562f9fa0b45a5851fd4dcf20cf9a5865ab05fddd25a5f34ffce5d2ce2a67b4d`|
|构建结果|`BUILD SUCCESSFUL in 10m 2s`，72项任务中12项执行、60项已是最新|
|模拟器|独立AVD `NivoSiteCapture`，Android16，API36.1，Google APIs Play Store x86_64|
|显示|1080×2400，density420，简体中文|

拍摄包来自该提交，不是下载目录中已有的2.0.5发行文件。网站明确标注当前维护版本的Android模拟器实拍，不以相同版本号宣称二者界面相同，不覆盖原有APK、IPA或源码归档。

在`android/src/android`目录配置JDK21、Android SDK和Gradle缓存后，实际构建使用Gradle Wrapper的Java入口。Windows上须将`nm.bash`指向Git Bash，避免调用依赖WSL的系统bash：

```powershell
& '<JDK21>/bin/java.exe' `
  -classpath gradle/wrapper/gradle-wrapper.jar org.gradle.wrapper.GradleWrapperMain `
  --no-daemon --console=plain --max-workers=2 --offline `
  '-Pnm.abi=x86_64' '-Pnm.uiTest=true' '-Pnm.bash=<Git>/bin/bash.exe' `
  '-Dorg.gradle.jvmargs=-Xmx4g -XX:MaxMetaspaceSize=768m -Dfile.encoding=UTF-8' `
  '-Pkotlin.compiler.execution.strategy=in-process' `
  :app:assembleDebug :app:assembleDebugAndroidTest
```

本轮构建了应用和仪器测试APK，未运行完整单元测试或仪器测试。编译成功及页面操作不替代arm64沙盒、真实模型调用、强制专注或iPhone验证。

## 拍摄内容

所有示例记录在这个独立模拟器中通过实际界面创建，没有读取用户手机数据、配置API Key或改写正式学习档案。PNG直接由ADB屏幕采集保存，不裁切、不重绘、不替换状态栏，也未用网页或SVG模拟应用画面。

|图片|操作与画面内容|
|---|---|
|[chat.png](../site/media/screenshots/chat.png)|主要聊天页，保留“今天想读一章书……”的未发送输入草稿。没有模型回答，不作为AI成功创建任务的证据。|
|[tasks.png](../site/media/screenshots/tasks.png)|通过任务编辑器建立阅读、整理笔记、散步选题三条示例待办。阅读任务有“个人成长”分组、“阅读”标签和备注，任务均未标记完成。|
|[focus.png](../site/media/screenshots/focus.png)|由阅读任务的计时入口开始普通25分钟番茄钟，截图时显示23:22，使用App内置矢量背景。没有启用强制锁机。|
|[fragments.png](../site/media/screenshots/fragments.png)|本次专注实际运行3分25秒后“结束并保存”，通过“记录心得”进入编辑器。任务与时段自动带入，填写示例阅读心得和“不错”心情并保存。拼图页显示记录及03:25专注时长，关联任务仍未完成。|
|[coach.png](../site/media/screenshots/coach.png)|最新教练技能列表，六项技能处于初始状态，已达成单元数为0。没有提交测试答案或制造学习成果。|
|[ideas.png](../site/media/screenshots/ideas.png)|当天App实际显示的轮换点子，包含工作与生活分类；不宣称是联网生成的实时热点。|

专注图和心得图是同一操作流程的不同时间点。截图中出现的阅读内容只是公开展示用的示例文字，3分25秒是实际运行的计时结果，不代表完成了一次真实阅读。

## 原图校验

全部图片均为1080×2400。仓库图片与首次采集的原图逐字节一致，SHA256如下：

|文件|SHA256|
|---|---|
|`chat.png`|`c52cfea480bd0848769a524144f75976a3b55b6c5ace4f60c69fc10fcfbc2906`|
|`tasks.png`|`e9c4749975c4f0dc9c4562a2a2b61a586348fd6ab2a2e4c1de90ded10c13e812`|
|`focus.png`|`ef9ae0db0afed9c2b4e941e96cc010ca8feb3a02312ebad2d9611d139bb4e6f1`|
|`fragments.png`|`f2fbb2b6e13ecce8de5c969b1f69b98af6341fa04081d9ddf0b997307a1162b6`|
|`coach.png`|`470e07cd0df45f91fd8a01c0f99f961e64156b360782018234a0ce4aa113b0c6`|
|`ideas.png`|`74143fe2976b0552dd38b9db11e41e429de74fa72b10f19b46b25e4e21ba8aff`|

## 后续更新

1. 记录Android源码提交与工作树状态，重新构建独立调试包，保存构建输出和APK哈希。
2. 在独立模拟器中新建公开示例数据，核对每次操作后的真实界面，再采集PNG。保留UI树和操作证据，不复用采集失败前的旧画面。
3. 检查没有个人账号、密钥、私人记录或其他应用内容后，替换`site/media/screenshots/`对应原图，更新本页来源及校验值。
4. 按需更新`scripts/site/screenshots.py`的替代文字和`scripts/site/content.py`的功能说明，再运行生成器。
5. 运行网站静态与单元检查，以及`browser_qa.py --full`。浏览器检查包括六图实际解码、四种宽度的比例与裁剪、原图入口、轮播与标签手势。
6. 原图资源和HTML一同发布，验证线上图片哈希。站点发布流程见[产品网站维护](product-site.md)。
