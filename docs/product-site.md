# 产品网站维护

Nivo Bot站点采用独立HTML页面，目录页支持浏览器搜索、后退和直接分享链接。源码位于`site/`，生成入口及内容源位于`scripts/site/`。

## 内容组织

首页解释“是什么、用来做什么、下一步去哪里”；功能画廊提供六种可切换的原创SVG和六个详页；模型目录为每个接入入口提供单独教程，包含账号、凭证、表单、验证、排障、费用和官方来源。开发者与隐私说明分别成页。

轮播支持按钮、左右方向键、Home／End、触摸滑动、暂停、视口离开暂停和系统减少动态效果。移动端聚焦示意图中的设备区域；插图始终标注虚构示例，不作为实机或性能证据。

模型教程核对了App协议和`/v1`拼接方式。例如Gemini原生使用`/v1beta`，与OpenAI兼容层不同；智谱`/api/paas/v4`与方舟`/api/v3`不能重复追加`/v1`。OpenCode旧目录端点与当前官方文档不同，教程按协议指向当前端点，不修改App预置代码。

官方来源存于每个服务商内容条目的`docs`与`console`字段。入口包括百炼、DeepSeek、Kimi、GLM、硅基流动、方舟、MiniMax、OpenAI、Claude、Gemini、OpenRouter、xAI、Groq、Mistral、OpenCode、Standard Compute、CheaperInference，以及Ollama、LM Studio和vLLM文档。核对日期为2026-11-13，未使用个人Key逐一请求所有厂商。

信息结构参考[Linear](https://linear.app/features)的独立功能入口、[Raycast](https://www.raycast.com/)的产品图叙事和[Obsidian](https://obsidian.md/download)的平台下载分区；未复制其品牌图像或界面。

## 发布版本清单

`site/releases.json`：

|字段|作用|
|---|---|
|`schemaVersion`|当前为2|
|`platforms`|平台ID、名称、`available`或`unreleased`状态|
|`releases[].id`|全站唯一发行记录ID|
|`platform`|与平台列表中的ID对应|
|`version`、`versionCode`|展示版本和内部编号；按数字比较版本|
|`channel`|`stable`或`beta`，下载页也可查看全部|
|`distribution`|`apk`、`ipa`、`app-store`或`testflight`|
|`releasedAt`|ISO日期|
|`minimumOs`、`architecture`|系统要求与可选架构说明|
|`downloadUrl`|实际可用的HTTPS文件或官方商店入口|
|`sizeBytes`、`sha256`|二进制发行必须填写；商店入口可省略|
|`sourceUrl`|与发行版对应的源码入口|
|`sourceSha256`|源码归档的校验和（有归档时提供）|
|`certificateSha256`|Android更新身份的公钥证书指纹|
|`notesUrl`|站内独立HTML说明页，不能越过站点目录|
|`summary`、`notes`|发行摘要与改动条目|

新增版本时，先上传实际文件并核对大小、SHA256和证书，再添加记录；不要覆盖同名历史文件。需要源码归档时，一并保存该安装包的对应源码。重新生成站点后，旧版说明不会随推荐版本改变。

iOS真正公开分发时，将平台状态改为`available`，填写实际分发方式、最低系统、官方入口和对应源码。没有直链IPA时不编造文件大小或SHA256。切勿仅因为仓库有iOS源码就标为已发布。

## 验证与回滚

先运行`render_site.py --check`、静态检查和单元测试，再执行浏览器QA。发布白名单阻止目录穿越与多余文件混入；验证下载清单时区分文件、商店链接和未发布状态。

线上采用`www/releases/<站点发布ID>`与`www/current`符号链接。每次保留前一个目标与独立部署清单，现有下载目录引用已验证的原始发行文件。切换后检查首页、独立路由、JS、SVG、版本清单、下载响应与校验信息；失败时恢复前一链接和本次变更的站点专用配置。不得因此覆盖服务器上其他服务的代理配置。
