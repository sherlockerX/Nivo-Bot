# Nivo开源入口

Nivo是基于nanoMuse与OpenMinis持续开发的Android与iOS应用，内置伙伴为十七／Shiqi。此分支聚焦AI聊天、教练训练、待办、专注与生活碎片，保留GPL许可和上游归属。开发版Android包名为`io.github.nivo`，iOS安装身份不变。以下下载记录保留各版本发布时的名称与文件。

Android2.0.9(60)Companion使用新包名`io.github.sherlockerx.nelan`，与旧包`io.github.nanomuse.app`并存，不能覆盖更新。新应用有独立私有目录、Keystore及系统权限，同一签名不会自动转移旧数据。新包名下1660项JVM测试完成，1658通过、2跳过、0失败或错误，Debug与正式Release构建通过。最终APK、源码归档及校验文件已完成本地核验，正式证书与原版本一致，旧包名候选已作废。[公网发行页](https://nivo.8666886.xyz/releases/android-2.0.9.html)已部署，3份完整下载的大小与SHA256核验通过。双应用安装和迁移仍需真机验收；原Android2.0.7(58)产物保留为历史记录。

旧应用应继续保留。现有`.minisbak`可导入聊天及选择的文件、技能、记忆、MCP配置、服务商／模型、所选凭据和环境变量；待办使用独立JSON导入。专注只能导入停用状态的锁定计划和白名单，不能恢复专注历史。心得及照片、教练进度、自定义宠物、周期任务和通用偏好不在通用备份范围内，不能承诺完整迁移。操作入口见[迁移指南](https://nivo.8666886.xyz/install.html#android-migration)，代码范围与手机验收步骤见[详细迁移说明](docs/releases/v2.0.9.md#moving-from-the-old-android-package)。系统权限与Device Owner不会随备份转移。

iOS下载继续保留2.0.8(59)Clarity未签名ReleaseIPA及其对应源码和校验值。本轮只同步iOS源码品牌变更与版本字段，33项Windows便携XCTest及45份Swift语法解析通过，尚未进行本轮Xcode构建或iPhone验证，也不发布2.0.9IPA。2.0.8的完整发行CI和本地产物核验不能用作本轮源码证据。用户之前的iPhone反馈仅对应更早的检查包，实际2.0.8ReleaseIPA仍需个人签名后的手机验收。

本分支没有Apple Developer Program账号，不提供TestFlight或App Store分发；Release配置不带来Apple签名，iOS安装前仍需自行签名。CI测试与编译结果仅适用于对应提交和构建配置，不能替代iPhone真机验收。强制专注、周期锁定计划与应用白名单仅限Android；iOS提供专注提醒和引导式访问说明，由用户在系统中手动开启和结束。

|平台|安装包|对应源码|校验文件|
|---|---|---|---|
|Android2.0.9(60)，已部署并完成下载核验|[APK](https://nivo.8666886.xyz/downloads/Nelan-v2.0.9-arm64.apk)|[源码](https://nivo.8666886.xyz/downloads/Nelan-v2.0.9-source.zip)|[SHA256SUMS-v2.0.9.txt](https://nivo.8666886.xyz/downloads/SHA256SUMS-v2.0.9.txt)|
|Android2.0.7(58)，历史文件|[APK](https://nivo.8666886.xyz/downloads/Nivo-Bot-v2.0.7-arm64.apk)|[源码](https://nivo.8666886.xyz/downloads/Nivo-Bot-v2.0.7-source.zip)|[SHA256SUMS-v2.0.7.txt](https://nivo.8666886.xyz/downloads/SHA256SUMS-v2.0.7.txt)|
|iOS2.0.8(59)，未签名Release|[未签名ReleaseIPA](https://nivo.8666886.xyz/downloads/Nivo-Bot-v2.0.8-unsigned.ipa)|[源码](https://nivo.8666886.xyz/downloads/Nivo-Bot-v2.0.8-source.zip)|[SHA256SUMS-v2.0.8.txt](https://nivo.8666886.xyz/downloads/SHA256SUMS-v2.0.8.txt)|

提交`4163621fba0d40cabdb7354eaba8f9b97ad7be5c`的[CI44797863407](https://github.com/sherlockerX/Nivo-Bot/actions/runs/44797863407)完整通过：835项便携Swift测试、0失败，地图离线回归、Release设备应用编译、应用测试目标编译及NanoMuse源码零警告检查通过。应用测试仅编译、未执行，地图离线回归未请求Apple服务。IPA为70035647字节，SHA256为`ad631e6b0f4f1ecb7d8c71c4691d53734b1fb15ad0957796eed1344f6fd39a6a`；源码ZIP为76465089字节，SHA256为`c44c1d9a762f9a281bf3984b252d6648cb067013c001cc7aa024e6a11df25313`，核验8379份源码文件，ZIP共8380项。新ReleaseIPA仍需自行签名后进行手机验收。本地核验不证明公网下载可用。

Android2.0.9APK为42013135字节，源码ZIP为64696802字节，校验文件为181字节，完整SHA256、证书及APK检查记录见[2.0.9发行说明](docs/releases/v2.0.9.md)。源码归档固定于APK源码提交`905f9f23cba0017083a3fc50f3d443a7ade55f9b`，包含4892份源码文件，ZIP完整性与关键文件比对通过。最终核验文档由后续发布提交记录，不回写已固定的源码包，也不改变APK对应的源码提交。

公网发布ID为`site-20261121-nelan-2.0.9-1e28a2c`，网站提交为`1e28a2c18005bead71b8de43aaf2f8b31d8f1459`。54份静态文件HTTP检查与3份完整下载核验通过；37份HTML的CDN追加脚本及robots.txt管理前缀单独记录，其余16份静态响应与源码字节一致。该证据不代表浏览器交互、视觉验收、手机验收或搜索收录通过。

实际保留的原生输入见[2.0.9输入清单](docs/releases/v2.0.9-build-inputs.json)。proot子模块已展开，iSH及其嵌套iOS子模块未展开；外部依赖和工具链仍须单独准备。rclone的4KB加载段对齐和固定proot-loader的完整源码重建缺口仍保留，未建立16KB页设备兼容性，也不承诺逐字节可复现构建。iOS原包证据见[2.0.8发行说明](docs/releases/v2.0.8.md)，Android历史身份见[2.0.7发行说明](docs/releases/v2.0.7.md)。每个平台的源码归档记录自己的快照与依赖覆盖范围，不能用新源码覆盖旧安装包的来源记录。

- 产品网站源码：[site/](site/README.md)。纯静态、无需Node依赖，可部署到GitHub Pages或其他静态主机。
- Android构建：[docs/android-development.md](docs/android-development.md)。
- iOS功能与构建：[专注及教练](docs/zh/ios-focus-and-coach.md)、[当前验证状态](docs/zh/ios-local-port.md#current-validation)、[CI工作流](https://github.com/sherlockerX/Nivo-Bot/actions/workflows/ios-check.yml)。
- 源码地图：[docs/android-code-map.md](docs/android-code-map.md)。
- 项目仓库：[sherlockerX/Nivo-Bot](https://github.com/sherlockerX/Nivo-Bot)。
- 许可与来源：[LICENSE](LICENSE)、[NOTICE](NOTICE)、[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 贡献方式

先讨论具体问题，再提交范围清楚的改动。沿用Conventional Commits与DCO签署；保留上游文件中的来源标识。修改任务或计时逻辑时覆盖账号隔离、revision冲突、幂等重试、中断恢复；修改UI时检查字号、横屏、深浅主题和返回路径。

本分支允许讨论并准备贡献，不改变OpenMinis自身不接受PR的政策。`android/CONTRIBUTING.md`描述上游规则；此分支的工作入口以本文件与根目录约束为准。

## 发布前必须核对

1. 工作树和候选包的LICENSE、第三方说明、Room迁移schema及运行资源齐全。
2. `source_audit.py`没有未处理的凭据命中；另行检查Git历史，发现真实泄露须轮换凭据，不能只删当前文件。
3. 按发行版本核验Android包名及签名：2.0.9为`io.github.sherlockerx.nelan`，后续Nivo为`io.github.nivo`。说明支持的备份类别、未迁移数据和新包授权要求，不承诺跨包覆盖更新或完整数据迁移。iOS未签名IPA须明确个人签名前提。
4. 版本号与APK、IPA、源码提交、校验和对应。下载和发布记录使用本分支的[正式仓库](https://github.com/sherlockerX/Nivo-Bot/releases)，不引用上游发行版作自己的下载。
5. 在新环境验证依赖可获得、子模块齐全、arm64原生构建和测试。已有缓存上的构建成功不等于新机器可复现。
6. 真机检查双应用并存、受支持的备份恢复、聊天与模型配置、待办、停用专注计划及新包权限；确认未覆盖的生活记录、教练等数据仍可在旧应用访问，明确未经验证的设备和服务。
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
