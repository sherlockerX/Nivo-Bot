# Nivo Bot开源入口

Nivo Bot是基于nanoMuse与OpenMinis持续开发的Android应用。此分支聚焦AI聊天、教练训练、待办、专注、生活碎片及其协作；保留GPL许可和上游归属。上游README中的下载、社区、TestFlight、免费额度和网站属于上游项目，不代表此分支的服务承诺。

- 产品网站源码：[site/](site/README.md)。纯静态、无需Node依赖，可部署到GitHub Pages或其他静态主机。
- Android构建：[docs/android-development.md](docs/android-development.md)。
- 源码地图：[docs/android-code-map.md](docs/android-code-map.md)。
- 项目仓库：[sherlockerX/Nicholasx](https://github.com/sherlockerX/Nicholasx)。
- 许可与来源：[LICENSE](LICENSE)、[NOTICE](NOTICE)、[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 贡献方式

先讨论具体问题，再提交范围清楚的改动。沿用Conventional Commits与DCO签署；保留上游文件中的来源标识。修改任务或计时逻辑时覆盖账号隔离、revision冲突、幂等重试、中断恢复；修改UI时检查字号、横屏、深浅主题和返回路径。

本分支允许讨论并准备贡献，不改变OpenMinis自身不接受PR的政策。`android/CONTRIBUTING.md`描述上游规则；此分支的工作入口以本文件与根目录约束为准。

## 发布前必须核对

1. 工作树和候选包的LICENSE、第三方说明、Room迁移schema及运行资源齐全。
2. `source_audit.py`没有未处理的凭据命中；另行检查Git历史，发现真实泄露须轮换凭据，不能只删当前文件。
3. 发布签名、包名和升级路径确定。当前应用ID沿用`io.github.nanomuse.app`，与上游可能冲突；正式分发前决定是否独立ID，并评估本地数据迁移，不能直接替换字符串。
4. 版本号与APK、源码提交、校验和对应。这个分支未建立独立公共发布记录时，不引用上游发行版作自己的下载。
5. 在新环境验证依赖可获得、子模块齐全、arm64原生构建和测试。已有缓存上的构建成功不等于新机器可复现。
6. 真机检查安装升级、聊天配置、待办、专注、生活记录、教练恢复；明确未经验证的设备和服务。
7. 更换或审核上游服务地址、隐私说明、支持渠道和营销文案。不要承诺未运营的免费服务。

## 本地检查与候选包

```powershell
python scripts/release/source_audit.py --output source-audit.json
```

检查只输出路径、行号和类别，不打印秘密值。默认检查Git跟踪文件；忽略的本机运行文件不进入候选包。

```powershell
python scripts/release/prepare_source.py --root . --overlay reviewed-overlay --output Nivo-Bot-source.zip --restore-missing-from-head
```

`reviewed-overlay`是已审查、按仓库相对路径组织的修改目录。工具保留工作树现有改动，只有明确传入恢复开关时，才从HEAD补齐缺失跟踪文件到ZIP；不会恢复原工作树。候选包不带Git历史、签名密钥、数据库或本机配置。子模块只记录位置，仍需按`.gitmodules`单独获取。候选不是正式发行包，须阅读旁边的manifest。

## 安全报告

公开Issue不应包含密钥、真实学习记录或可利用漏洞细节。仓库所有者需在GitHub启用并确认私密漏洞报告入口，再对外提供地址。上游`SECURITY.md`的响应时限与渠道不能自动算作本分支承诺。
