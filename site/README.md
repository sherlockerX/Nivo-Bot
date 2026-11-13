# Nivo Bot产品网站

多页静态产品站，部署在`https://nivo.8666886.xyz/`。没有运行框架、远程字体、分析追踪器或模型请求。

|页面|职责|
|---|---|
|`index.html`|解释产品、使用流程和下一步|
|`features.html`、`features/*.html`|六张原创功能图轮播与独立详页|
|`models.html`、`models/*.html`|服务商筛选、22种接入教程|
|`downloads.html`|平台、渠道和版本选择、历史记录与文件校验|
|`releases/*.html`|每版固定的说明与对应源码|
|`developers.html`、`privacy.html`|源码、贡献、许可和数据边界|

## 修改内容和预览

页面与原创SVG是生成文件，编辑`scripts/site/content.py`中的功能和教程内容，或`render_site.py`的页面结构，再重新生成。样式和交互直接修改`product.css`与`product.js`。图像是功能示意，不是手机截图，也不使用真实个人数据。

```bash
python scripts/site/render_site.py
python -m http.server 8783 --bind 127.0.0.1 --directory site
```

教程首先对照Android的`OwnKeyPresets.kt`、服务商配置页和模型槽位，再引用各厂商官方文档。每篇保留核对日期和官方入口；账户限制、价格和模型可用性仍以对应平台为准。网站不收集API Key，不代访客调用模型验证。

## 加入后续版本

`releases.json`采用版本2清单，字段说明见[产品站维护指南](../docs/product-site.md)。新增发行记录后重新生成页面即可扩展版本历史，不覆盖旧安装文件。`release.json`继续保留旧入口兼容。

当前保留Android v2.0.0（51）的正式APK与对应源码原文件。iOS状态为`unreleased`，没有虚构下载链接。未来可配置`apk`、`ipa`、`app-store`或`testflight`发行方式；商店入口不要求填写不存在的IPA文件哈希。

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

检查包含轮播、服务商搜索、手机导航、复制、平台和渠道切换、浏览器返回、网络失败，以及隔离数据下的多版本排序和iOS商店分发。真实发行清单不会被测试数据修改。

## 部署

现站运行在Netcatty管理的独立`nivo-site`容器，入口为`/opt/nivo-site/www/current`。新前端发布使用独立目录和原子符号链接切换，保留旧版及现有下载文件，公网Caddy代理继续使用原域名。

仓库的Pages工作流仍保持手动触发；不会因普通推送自动改变公网托管位置。许可与上游归属保留GPL-3.0-or-later、nanoMuse和OpenMinis说明。
