# 念步/Nelan网站部署

网站地址：`https://nivo.8666886.xyz/`。静态网站与Android模型服务互相独立，网站不保存用户会话或API密钥。

服务器目录采用`/opt/nivo-site/www/releases/<版本与构建编号>/`，`www/current`是当前发行版链接。容器只读挂载`www`并通过已有Docker代理网络提供80端口，不向宿主机发布新端口。主Caddy代理到`nivo-site:80`，不修改已有服务的配置块。

部署前校验静态文件与下载包SHA256，解包到新发行目录。先验证静态容器和Caddy候选配置，再备份主Caddyfile、原子替换并reload。更新失败时恢复原Caddyfile并reload；回退内容时切回先前的`www/current`链接。

源站抽查的首页、功能页、模型页、Gemini教程、下载页与发行清单必须与已验证`files.json`中的SHA256一致。响应包含品牌词或`schemaVersion`不能证明发布成功；即使新旧页面品牌相同，内容不符也回滚。此处校验容器内源站，不把公网Cloudflare追加脚本的响应当作源文件。

下载目录只包含安装包、对应源码和校验文件。签名密钥、签名配置、加密凭据、本机记录、服务器证书、Git配置与数据库均不得放进站点。每个平台的安装包身份必须与其`releases.json`记录及对应源码一致，`release.json`兼容入口对应当前Android发行；不同平台的最新可下载版本可以不同。历史文件保持原名与原校验和。

各平台最新版本从正式清单独立读取。Android保留包名`io.github.nanomuse.app`与此前正式版签名，上线前核对最终APK证书指纹；真机覆盖升级须另行验收。共用源码的版本字段更新不能代替新平台产物，不把历史IPA改名作为新版。

站点使用念步/Nelan品牌与十七/Shiqi助手名称，仍部署在既有域名及`nivo-site`容器。新品牌的正式发行记录显式设置`productName: "念步/Nelan"`；旧记录缺省沿用原品牌，文件名、校验和及对应源码不随网站换名改写。网站改名和本地生成成功不能作为安装包已上传或新版已上线的证据。

历史2.0.5(56)发布文件分别为`Nivo-Bot-v2.0.5-arm64.apk`与`Nivo-Bot-v2.0.5-unsigned.ipa`，继续保留。未签名IPA在清单中使用`distribution: "ipa"`和`signing: "unsigned"`，上线前核对原始文件SHA256、大小、包内版本与最低系统要求。下载页必须显示自行签名安装的前提，不把IPA文件当作TestFlight或App Store入口。Android强制专注能力不得写入iOS发行功能说明。

新增源码归档从构建使用的固定commit导出，在清单记录`sourceCommit`、`sourceSha256`和`sourceSizeBytes`。安装包和源码包均在文件最终生成后计算哈希与大小，不用移动中的分支地址或未提交工作区代替对应源码。

`scripts/site/deploy_netcatty.py`部署静态站并继承现有下载目录；新安装包与源码包需要单独上传、校验后才能加入正式下载清单。`mobile-release.yml`在`v*`标签上调用`scripts/release/publish_mobile.py`，支持仅Android、仅iOS或双平台发行，按标签内实际记录校验官网文件后上传到GitHub。双平台同版发行必须指向同一份源码归档；单平台发行无需伪造另一平台记录。发布器保留标签、文件大小、哈希、包内身份与现有附件校验，不覆盖不同内容的同名文件。

`scripts/deploy/compose.nivo.yml`和`nivo.Caddyfile`是可审查的部署模板。可通过`NIVO_CADDY_IMAGE`固定实际使用的镜像digest。公网Cloudflare验证策略需另行检查；源站200不能代替公网浏览器验收。
