# Nivo Bot产品网站

多页静态产品站，部署在`https://nivo.8666886.xyz/`。站点源码没有运行框架、远程字体、分析追踪器或模型请求。线上Cloudflare设置会向部分响应加入性能统计与防护脚本，详见隐私说明。

|页面|职责|
|---|---|
|`index.html`|解释产品、使用流程和下一步|
|`features.html`、`features/*.html`|六个模块的Android真实截图与独立详页|
|`models.html`、`models/*.html`|官方服务、自建模型和自定义接口的16种接入教程|
|`downloads.html`|平台、渠道和版本选择、历史记录与文件校验|
|`getting-started.html`|接入基础概念和常见问题|
|`versions.html`、`install.html`|独立版本历史与安装升级说明|
|`releases/*.html`|每版固定的说明与对应源码|
|`developers.html`、`privacy.html`|源码、贡献、许可和数据边界|

## 修改内容和预览

HTML是生成文件，编辑`scripts/site/content.py`中的功能和教程内容，或`render_site.py`的页面结构，再重新生成。首页日常案例与线形图标在`presentation.py`维护。样式和交互直接修改`product.css`与`product.js`。应用图片位于`media/screenshots/`，来自最新维护源码重新构建后在独立Android模拟器中运行的完整App，使用人工建立的示例记录，不读取用户档案。图片保留原始界面与比例，并提供完整原图链接；不以CSS、SVG或生成图片代替App界面。拍摄信息见[截图来源记录](../docs/product-site-screenshots.md)。

首页用阅读任务串起对话草稿、待办、专注和心得；访客主动切换，不自动播放、不创建数据。聊天截图未调用模型，不作为AI已创建任务的证据；专注截图只显示拍摄当时的真实计时状态。功能轮播集中在画廊，默认手动切换，可主动播放。全站常驻顶部导航，手机通过常驻页面标签切换栏目；教程默认收起服务商目录，目录与锚点预留导航高度。各个功能、教程、版本历史、安装说明均独立URL，不在首页重复叠加。

```bash
python scripts/site/render_site.py
python -m http.server 8783 --bind 127.0.0.1 --directory site
```

教程首先对照Android的`OwnKeyPresets.kt`、服务商配置页和模型槽位，再引用各厂商官方文档。每篇保留核对日期和官方入口；账户限制、价格和模型可用性仍以对应平台为准。网站不收集API Key，不代访客调用模型验证。

本地模式维护取消原项目账号验证、设备中继与自动跨设备同步，首次启动允许暂时跳过模型配置。入门与隐私页面区分当前维护行为和历史安装包；Android2.0.7的修复不会改写Android或iOS2.0.5的发行记录，也不代表已发布新版iOS。官方服务之外的接口使用自定义教程，不展示中转商推荐。目录依据`providers.json`中的`is_relay`字段筛选，发布白名单不再包含原中转商教程。

## 加入后续版本

`releases.json`采用版本2清单，字段说明见[产品站维护指南](../docs/product-site.md)。新增发行记录后重新生成页面即可扩展版本历史，不覆盖旧安装文件。`release.json`继续保留旧入口兼容。

本轮目标为Android2.0.7(58)Anchor，文件为`Nivo-Bot-v2.0.7-arm64.apk`。iOS实际下载继续使用`Nivo-Bot-v2.0.5-unsigned.ipa`，版本为2.0.5(56)，本次不生成2.0.7的IPA。共用源码版本字段更新不等于两端同时发布。最终产物核验后，在`releases.json`填写真实大小、SHA256、最低系统与对应源码，并更新Android兼容入口`release.json`。Android2.0.0(51)、Android2.0.5(56)、iOS2.0.5(56)及其对应源码原文件继续保留，不能覆盖同名历史文件。

Android保留包名`io.github.nanomuse.app`与原正式版签名身份；本次未在Android真机上测试覆盖升级。源码包`Nivo-Bot-v2.0.7-source.zip`从构建使用的固定commit导出，清单记录`sourceCommit`、`sourceSha256`与`sourceSizeBytes`，不以未提交工作区或移动分支代替对应源码。

`scripts/release/publish_mobile.py`按当前标签内的真实发行记录支持Android单平台、iOS单平台或双平台发布。双平台同版须共享同一份源码归档；只有官网实际文件与清单校验通过后，`mobile-release.yml`才创建或补全GitHub发行。旧iOS包不会随Android版本更新而自动成为新版。

iOS未签名IPA使用`distribution: "ipa"`和`signing: "unsigned"`，只有实际文件准备好后才将平台状态改为`available`。文件需用户使用自己的Apple开发签名与适用安装工具重新签名，不能下载后直接安装到iPhone，也不代表提供TestFlight或App Store入口。商店分发只记录真实入口，不填写不存在的IPA大小或哈希。

功能说明核对两端源码，强制专注、允许应用与自动锁机计划仅限Android11及以上。iOS提供普通计时、本机提醒和系统引导式访问说明；提醒后由用户开始计时，引导式访问也由用户自行开启与结束。

## 检查与构建

```bash
python scripts/site/render_site.py --check
python -m unittest discover -s scripts/site -p test_site.py -v
python scripts/site/check_site.py --root site
python scripts/site/build_site.py --root site --output build/product-site
```

输出目录必须为空。`site-manifest.json`是可发布文件白名单，构建不会夹带`legacy.html`、本机配置、私钥或其他额外文件。`downloads/`中的发行二进制由部署单独保留，不放进源码仓库。

可选浏览器验收需要Playwright及其Chromium：

```bash
python scripts/site/browser_qa.py --url http://127.0.0.1:8783/ --output build/site-qa --full
```

检查包含首页案例、轮播、服务商搜索与筛选重置、手机菜单焦点、复制、平台和渠道切换、浏览器返回、网络失败与超时回退、禁用JavaScript，以及隔离数据下的多版本排序、未签名IPA安装说明和iOS商店分发。真实发行清单不会被测试数据修改。真实产物元数据填入后须重新生成、检查和构建，不能直接发布填清单前的预构建目录。

## 部署

现站运行在Netcatty管理的独立`nivo-site`容器，入口为`/opt/nivo-site/www/current`。新前端发布使用独立目录和原子符号链接切换，保留旧版及现有下载文件，公网Caddy代理继续使用原域名。

`scripts/site/deploy_netcatty.py`备份旧配置与`deployment-manifest.json`，并原样继承其中的`search_submission`，保留既有Google与Bing搜索验证记录。上一版的`public_verification`和`public_verified`连同版本身份移入`public_verification_history`，已有历史继续累积。新部署始终设置`public_verified: false`，只有本轮公网浏览器、路由和下载校验完成后才能写入新验收证据；旧版验证不能证明新版已通过。源站检查失败仍恢复旧链接与配置，原部署清单不变。搜索验证标签和文件继续由生成器保留，不因普通版本发布重置。

仓库的Pages工作流仍保持手动触发；不会因普通推送自动改变公网托管位置。许可与上游归属保留GPL-3.0-or-later、nanoMuse和OpenMinis说明。
