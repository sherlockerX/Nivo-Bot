# Nivo Bot产品网站

`site/index.html`是本分支的产品入口，不再跳转到上游网站。旧页面保留在`legacy.html`，默认发布工具不会包含旧页或上游素材。

## 预览

```bash
python -m http.server 8080 --bind 127.0.0.1 --directory site
```

打开http://127.0.0.1:8080/。无框架依赖、远程字体、分析追踪或模型请求。原创SVG与HTML交互用于功能示意，不伪装成真实用户数据。

|文件|职责|
|---|---|
|index.html|产品叙事、功能演示入口、FAQ和下载|
|product.css|响应式布局、移动端、减少动态效果与开发者页样式|
|product.js|流程切换、示例计时、菜单、下载元信息|
|developers.html|构建、模块、贡献、数据边界和许可|
|release.json|版本与下载状态的唯一来源|
|brand-mark.svg|原创网站字标，不替换App图标|

## 下载配置

当前目标为`https://nivo.8666886.xyz/`，`release.json`采用`channel: public`并填写对应安装包的HTTPS地址和SHA256。部署必须同时上传安装包、对应源码ZIP和校验文件，不能只更新元信息。开发预览可使用`local-preview`和同源相对APK路径，不应误写为公开正式版。

## 校验和部署

```bash
python scripts/site/check_site.py --root site
python scripts/site/build_site.py --root site --output build/product-site
```

输出目录只包含产品页白名单。可以上传到静态主机，或手动触发现有`.github/workflows/pages.yml`。工作流保持手动触发，不会因为本地整理自动公开。若部署到`sherlockerX/Nicholasx`的GitHub Pages，通常路径为`https://sherlockerx.github.io/Nicholasx/`，这只是部署配置目标，不代表已上线。

开发者完整指南见[OPEN_SOURCE.md](../OPEN_SOURCE.md)。
