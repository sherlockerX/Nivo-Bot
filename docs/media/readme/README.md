# Nivo Bot的README展示素材

这些图是为Nivo Bot制作的原创功能示意，采用官网的米白、深绿与陶土色。画面使用示例内容，不是手机截图、真实任务、训练成果或性能验证记录。

- `hero.png`：品牌封面。
- `feature-tour.gif`：六个功能页横向切换，960×512，约14秒循环。静态图可单独查看。
- `chat.png`、`tasks.png`、`focus.png`、`fragments.png`、`coach.png`、`ideas.png`：1200×640功能介绍图。

GitHub会过滤README的脚本与大多数布局样式，因此轮播使用GIF，静态图使用普通HTML表格。阅读时可直接选择静态图，避免依赖动画。

## 重新生成

生成器位于[scripts/readme-media.py](../../../scripts/readme-media.py)。依赖Pillow与Playwright，使用本地Chromium渲染原创HTML和矢量场景，不请求模型或远程图片。

```bash
python -m pip install Pillow playwright
python -m playwright install chromium
python scripts/readme-media.py
```

素材沿用仓库的GPL-3.0-or-later许可。README信息结构参考[LobeHub](https://github.com/lobehub/lobe-chat)、[AppFlowy](https://github.com/AppFlowy-IO/AppFlowy)与[Immich](https://github.com/immich-app/immich)的品牌入口、功能图组和使用指南组织方式；未使用这些项目的图片或界面素材。
