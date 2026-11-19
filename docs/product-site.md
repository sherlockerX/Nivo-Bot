# 产品网站维护

Nivo Bot站点采用独立HTML页面，目录页支持浏览器搜索、后退和直接分享链接。源码位于`site/`，生成入口及内容源位于`scripts/site/`。

## 内容组织

首页解释“是什么、用来做什么、下一步去哪里”；功能画廊提供六种可切换的原创SVG和六个详页；模型目录为每个接入入口提供单独教程，包含账号、凭证、表单、验证、排障、费用和官方来源。开发者与隐私说明分别成页。

首页只保留产品定位、专注示意与三个页面入口，功能轮播仅在功能画廊展示。模型基础概念与常见问题位于`getting-started.html`，目录页直接选择厂商；下载页只负责选平台和版本，`versions.html`与`install.html`分别承载历史发行、安装与升级。各栏目通过真实链接跳转，不采用整页锚点堆叠或截断正文的固定高度布局。

全站导航使用常驻顶栏；手机额外显示一排直接切页的标签。桌面与手机分别保留顶栏占位，并设置教程锚点与侧边目录偏移，防止正文被导航遮挡。浏览器验收检查每个页面在四种宽度下滚动到底后的导航位置，以及独立URL、后退恢复和教程锚点可见性。

轮播支持按钮、左右方向键、Home／End、触摸滑动、暂停、视口离开暂停和系统减少动态效果。移动端聚焦示意图中的设备区域；插图始终标注虚构示例，不作为实机或性能证据。

模型教程核对了App协议和`/v1`拼接方式。例如Gemini原生使用`/v1beta`，与OpenAI兼容层不同；智谱`/api/paas/v4`与方舟`/api/v3`不能重复追加`/v1`。OpenCode旧目录端点与当前官方文档不同，教程按协议指向当前端点，不修改App预置代码。

官方来源存于每个服务商内容条目的`docs`与`console`字段。入口包括百炼、DeepSeek、Kimi、GLM、硅基流动、方舟、MiniMax、OpenAI、Claude、Gemini、OpenRouter、xAI、Groq、Mistral、OpenCode、Standard Compute、CheaperInference，以及Ollama、LM Studio和vLLM文档。核对日期为2026-11-13，未使用个人Key逐一请求所有厂商。

信息结构参考[Linear](https://linear.app/features)的独立功能入口、[Raycast](https://www.raycast.com/)的产品图叙事和[Obsidian](https://obsidian.md/download)的平台下载分区；未复制其品牌图像或界面。

## 阅读与搜索发现

正文采用深绿文字，次要说明也须保持可辨认的对比度；桌面正文基准为19像素，手机教程为18像素。中文沿用宋体，英文与数字采用Times New Roman；代码保留等宽字体。标题不再压缩字距，正文链接增加下划线。浏览器验收计算正文颜色与背景的实际对比度，并检查手机和电脑布局。

生成器保留Google Search Console的首页验证标签和原始HTML验证文件。验证文件只提供指定正文，不加入页面导航，不进入sitemap，也不得因后续部署而删除。IndexNow根目录key文件是公开的站点验证标记，不是账户API密钥；提交网址时只发送sitemap中的公开页面，不发送下载包或后台资料。

Bing Webmaster Tools采用`msvalidate.01`公开站点验证标签，随生成器写入页面的`head`，发布检查会阻止标签遗漏。完成所有权验证后仍需保留此标签；站点地图地址为`https://nivo.8666886.xyz/sitemap.xml`。

首页的WebSite与SoftwareApplication结构化数据描述网站名及版本清单中已提供的各平台稳定发行，并从清单读取版本与最低系统要求。未签名IPA的结构化信息保留自行签名要求。不得虚构评分、评价或商店发行；结构化数据也不保证富结果或排名。sitemap随内容页面和发行说明生成，`lastmod`依据内容维护日期，不能为催抓取而伪造日期。

站点所有权验证、sitemap提交、抓取请求、搜索引擎收录是不同状态。Google Search Console和Bing Webmaster Tools的结果应分别记录，IndexNow的200或202只代表通知被接受，不代表已收录。Edge是浏览器，默认搜索通常由Bing提供。参考[Google站点地图说明](https://developers.google.com/search/docs/crawling-indexing/sitemaps/build-sitemap)、[请求抓取](https://developers.google.com/search/docs/crawling-indexing/ask-google-to-recrawl)与[IndexNow协议](https://www.indexnow.org/documentation)。

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
|`signing`|IPA必须填写`unsigned`或`signed`；`unsigned`仅适用于iOS IPA|
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

iOS实际提供发行文件后，将平台状态改为`available`，填写实际分发方式、最低系统、文件入口和对应源码。未签名IPA使用`distribution: "ipa"`和`signing: "unsigned"`，卡片、独立说明页与禁用JavaScript时的入口都会说明需自行签名，不能直接安装到iPhone。只有实际存在的TestFlight或App Store入口才使用对应分发类型。没有直链IPA时不编造文件大小或SHA256。

2.0.5的文件名为`Nivo-Bot-v2.0.5-arm64.apk`与`Nivo-Bot-v2.0.5-unsigned.ipa`，Android版本号与iOS构建号均为56。真实大小、SHA256、最低系统和源码归档以最终产物核验后填入，旧版记录与下载文件继续保留。填写完成后同时更新兼容入口`site/release.json`，重新运行生成器与站点检查。

功能内容以两端源码为依据。普通专注、背景、任务关联、分组时长统计、专注感悟、技能档案和个人记录查询按各平台实际实现描述。强制专注、允许应用与自动锁机计划明确限定为Android11及以上；iOS仅提供普通计时、本机提醒和系统引导式访问说明，提醒不自动启动计时，引导式访问由用户在系统中开启与结束。

## 验证与回滚

先运行`render_site.py --check`、静态检查和单元测试，再执行浏览器QA。发布白名单阻止目录穿越与多余文件混入；验证下载清单时区分文件、商店链接和未发布状态。

线上采用`www/releases/<站点发布ID>`与`www/current`符号链接。每次保留前一个目标与独立部署清单，现有下载目录引用已验证的原始发行文件。切换后检查首页、独立路由、JS、SVG、版本清单、下载响应与校验信息；失败时恢复前一链接和本次变更的站点专用配置。不得因此覆盖服务器上其他服务的代理配置。

公网验证时，Cloudflare可能在HTML结尾追加性能统计与安全检查脚本。源站文件应按构建哈希逐字节核对；公网HTML应另查原页面内容与实际交互，不把CDN追加脚本误判成源码漂移。安装包、源码归档及其他静态资源仍须按完整响应校验SHA256。
