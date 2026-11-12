# Nivo Bot网站部署

网站地址：`https://nivo.8666886.xyz/`。静态网站与Android模型服务互相独立，网站不保存用户会话或API密钥。

服务器目录采用`/opt/nivo-site/www/releases/<版本与构建编号>/`，`www/current`是当前发行版链接。容器只读挂载`www`并通过已有Docker代理网络提供80端口，不向宿主机发布新端口。主Caddy代理到`nivo-site:80`，不修改已有服务的配置块。

部署前校验静态文件与下载包SHA256，解包到新发行目录。先验证静态容器和Caddy候选配置，再备份主Caddyfile、原子替换并reload。更新失败时恢复原Caddyfile并reload；回退内容时切回先前的`www/current`链接。

下载目录只包含安装包、对应源码和校验文件。签名密钥、签名配置、加密凭据、本机记录、服务器证书、Git配置与数据库均不得放进站点。APK版本、release.json和源码发行记录必须一致。

`scripts/deploy/compose.nivo.yml`和`nivo.Caddyfile`是可审查的部署模板。可通过`NIVO_CADDY_IMAGE`固定实际使用的镜像digest。公网Cloudflare验证策略需另行检查；源站200不能代替公网浏览器验收。
