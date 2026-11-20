# iOS工具自检审查与复测

本次审查根据用户提供的iPhone自检报告核对原生界面、模型配置、工具桥接、记录权限及CLI协议。修复在`codex/ios-self-test-audit`分支验证，不改变版本号或官网正式下载。报告未包含被测IPA的准确构建号，因此不能假定手机与当前源码完全一致。

## 已核实与修复

|报告现象|源码结论|处理|
|---|---|---|
|聊天能用模型，`minis-model-use list --all`却为空|聊天绑定与允许AI调用的副模型是独立配置；空授权列表会返回0|保留授权边界；明确设置入口与`--all`含义，使列举、搜索和运行遵循相同过滤规则|
|错误提示拼进模型名|确有字符串拼接问题|模型标识与操作建议分开生成|
|带斜杠的配置路径读不到|真正的解析缺陷是型号里的点号被当成字段分隔符|按已登记的完整子项ID及完整字段路径匹配，读写使用同一解析|
|`minis-config get`无参数退出码不符|通用CLI的参数错误码2与配置CLI文档约定1混用|统一为配置命令自己的退出码；主题误用提示改用`topic-help`|
|quiet配置读取缺值或输出失败|读取结果的`value`未被正确解包，标量和字符串错误也不能走旧对象序列化器|使用命令专用出口，保留null、标量、数组和对象类型，普通输出保持原字段契约|
|前置CLI参数吞掉命令或缺值被忽略|复审发现config前置元数据缺值会回落默认查询，model-use前置输出开关会吞命令，provider缺值会丢失筛选|使用实际入口共用的纯解析器，先拒绝缺值，再保留命令、搜索词和显式筛选|
|`mosaic_query`首次即失败|原入口会拒绝框架附带的`tool_title`；不能确认这解释了手机全部失败|接受并校验展示标题，标题不参与查询或授权|
|个人记录统一提示expired|没有固定14分钟有效期；后台、隐藏聊天、新回合或账户代次变化会撤销权限|按原因返回稳定错误码和恢复动作，保留执行前后及结果交付前的权限校验|
|生活记录裸报`NivoLifeError错误6`|Swift枚举被桥接成无意义编号，无法据此判断磁盘损坏|分别报告权限、加载状态、查询参数、版本或数据解码失败；未知存储错误不泄露私有路径|
|拼图缺分页、无`--compact`|当前JSON已有`next_offset`，Markdown未明确列出；CLI未实现compact|保留JSON分页，补Markdown分页字段，compact只改变JSON空白|
|`sessions status`双层data|Swift和Objective-C重复包装|统一会话出口；send、retry、open失败也不能被外层成功状态掩盖|
|scheduled probe缺ID却报账户或不存在|确有缺参校验晚于宿主访问的问题|解析阶段检查目标ID和写入版本；权限拒绝保持执行失败，不冒充参数错误|
|地图cycling或bogus变驾车|确有静默回退|未知模式直接拒绝，cycling使用MapKit骑行枚举，服务不支持时返回原错误|
|地图数字明显异常、route/search失败|未拿到原始解析端点和设备服务响应，具体错距根因未证实|返回解析后的from/to与mode，多候选要求消歧；保留错误域、代码和阶段，超时取消并拒收晚回调|

## 模型调用的配置方式

打开设置→模型分组，找到`Models nanoMuse Can Call at Runtime`区域，中文为“nanoMuse运行时可调用的模型”。需要改变授权时使用`Add Models or Groups`选择允许AI通过工具调用的模型或模型组。也可在应用中打开`minis://settings/model-groups`。聊天主模型选择与这份授权名单分别保存。读取现有名单可执行：

```sh
minis-model-use list --all
```

`--all`保留为兼容参数，仍只列出已授权且启用的模型，不会授权调用其他模型，也不会启用已停用的供应商。显式传入的供应商和模态筛选继续生效。选择模型前可查看其模态和供应商；列举成功不能证明真实模型请求成功，真实请求仍取决于用户配置和供应商服务。

这里的授权范围指应用选择模型和供应商的入口。现有原始请求透传`body_mode=replace`允许调用方原样提供请求体，其中的`model`字段可与入口选择不同；这不是严格的供应商侧模型白名单。本轮未修改这项已有的高级协议，也没有用真实请求测试它，因此不能将入口过滤描述为对所有透传请求的模型级限制。

配置读取使用`topic-help`实际返回的完整路径，无需把`/`改成`%2F`：

```sh
minis-config topic-help models
minis-config get 'models.<provider-id>/deepseek-v4.1-flash.contextWindow'
minis-config get 'models.<provider-id>/deepseek-v4.1-flash.contextWindow' --quiet
```

整个模型路径应从本机`topic-help models`复制，示例模型名不要求在本机存在，尖括号占位符不能原样输入shell。普通输出保留`value`的历史编码；quiet输出解码后的JSON值。`get appearance`等主题名不等同于字段，应先执行`topic-help appearance`。

## 个人记录的恢复与边界

记录查询只使用当前前台可见聊天中实际保存的用户请求。切到后台、隐藏聊天、取消、编辑原请求或进入新回合后，旧查询不能自行恢复授权。恢复时回到原聊天，发送新的读取请求；应用会使用新回合建立权限。无需卸载或清空记录。

错误应包含`success:false`、`dataAvailable:false`、稳定`error`及兼容旧调用方的同值`code`和说明；需要新请求时返回`requiresNewUserTurn:true`。它不能被AI解释成“没有记录”。记录正文和图片、凭据、任意私有文件分别处理；读记录不授予改任务、完成训练或运行已保存脚本的权限。

前端审查核对了模型组授权入口、聊天可见性和前后台撤销调用链。本次没有重新设计页面，未在iPhone上实测动画、返回手势或权限弹窗遮挡行为。需用新包确认切页再回来后的恢复体验。

原生模型查询支持已授权的新聊天；`minis-jigsaw-cli`保留自身独立的权限入口及主聊天或绑定练习聊天范围。两条路径拒绝时应说明各自原因，不能通过shell替代被撤销的模型查询授权。

## 时区与环境判断

`TZ=LCL+8:00:00`采用POSIX符号约定，表示UTC−8，与洛杉矶冬令时一致。现有shell代码按系统时区当前偏移生成，不是固定东八区。本次修复的是生活记录CLI默认使用`Asia/Shanghai`，现在跟随设备当前时区；指定历史自然日仍按原日期标签读取，不迁移或改写历史数据。

当前剪贴板代码对未知子命令已有JSON错误，正确读取命令仍为`apple-clipboard get`。精简shell未预装python、curl等不代表原生工具失效；没有为此扩大应用安装包。定位、日历、相册等系统权限未授予时，拒绝属于正常行为，本次没有自动授予权限。

## 验证记录

Windows不具备Xcode。先在macOSCI复现了`probe`缺参等参数问题，再实施修复：[失败基线44730972621](https://github.com/sherlockerX/Nivo-Bot/actions/runs/44730972621)，提交`7fea541`。该次执行772项Swift测试，新增6个测试方法中产生48个失败断言，设备构建按快速验证选项跳过。失败断言数不等于失败测试方法数。

最终源码提交`99a4ab07d2540fc6dd2695e72ca13fe0165fa65e`的[完整CI44738549366](https://github.com/sherlockerX/Nivo-Bot/actions/runs/44738549366)已全部成功：832项便携Swift测试，0失败；原生地图8组离线回归通过，包含10组区域边界探针和100轮并发完成竞争；未签名设备应用编译、应用测试目标编译和`NanoMuse/`零警告检查通过。原生地图回归使用真实命令入口和生产参数规则，替换沙盒输出设施，不请求Apple地图服务。后续补充审查结果的提交只改变文档，应用源码与该CI提交相同。

`NivoConfigRegistryTests`的2个测试和`NivoModelUseAuthorizationTests`的5个测试位于应用测试目标，不在上述832项内。本次工作流对该目标执行`build-for-testing`，不会运行这7个测试；不能将编译通过表述为授权集成测试已运行通过。

第二轮地图探针在[44735693350](https://github.com/sherlockerX/Nivo-Bot/actions/runs/44735693350)复现极区和全球尺度的区域跨度越界。例如纬度0°、半径20000000m产生361.7478°的纬度跨度，纬度90°、半径1000m产生约2.9×10¹⁴°的经度跨度。离线构造未抛异常，不能称已复现应用崩溃。随后生产代码把纬度与经度跨度分别限制在180°和360°，触极时调整纬度中心以覆盖原始查询点；正常区域与用于距离计算的查询中心保持原值。测试保留Apple原始探针日志并验证修正后的生产区域。

本地Python静态约束检查先发现13条既有界面文案缺少七种语言，补齐后21项通过。这不等于Swift运行测试。独立静态测试使用`--noconftest`，因为本机没有项目运行时的`loguru`依赖；测试不使用该运行时fixture。pytest另有未安装异步插件导致的`asyncio_mode`配置警告，未影响这21项检查。

地图的外层shell主动取消尚未接入`native_offload_set_abort_handler`。阶段等待仍有边界：search约20秒，两个地名加route最多约65秒，ETA最多约50秒；显式指定更短shell超时时，底层操作可能继续到自己的超时。这是既有边界，本轮未扩展取消协议，不应描述为已经实现即时全链路取消。

## 检查包

CI产物`nivo-ios-unsigned-37`中的`Nivo-Bot-unsigned.ipa`对应提交`99a4ab0`。它是未签名的Debug检查包，沿用当前源码的2.0.7(58)版本字段，本次没有提升版本号或更新官网正式下载。

|字段|验证结果|
|---|---|
|包名|`io.github.nanomuse.app`|
|架构|arm64设备应用|
|大小|89167225字节，85.04MiB|
|SHA-256|`a73c0f7809edc5b1d5d01432cf8e5a00a95f5c6c591706dd5da8266ca0bf0e3c`|
|下载完整性|本地计算与CI校验文件一致，ZIP成员CRC检查通过|
|测试组件|未包含`.xctest`测试包|
|签名与运行|没有内嵌描述文件，需自行签名；未在iPhone安装或运行|

## iPhone复测清单

CLI命令可在现有聊天关联的终端中手动执行，列举模型、读取配置、会话状态及拼图列表不会调用模型推理。第4、5项需要发送聊天请求，会保存消息并使用所选主模型；地图成功路径会请求Apple地图服务。

1. 保留原数据并安装匹配签名身份的检查包，记录应用版本和构建来源。不要为测试清空原数据。
2. 先列举现有副模型授权名单，无需清空配置。若当前名单为空，预期仍为0但有准确设置提示；需要验证授权后的列举时，再自行添加一个模型并重新列举。禁用的供应商不能因`--all`重新出现。真实调用费用由所选供应商计收。
3. 从`topic-help models`复制包含点号的真实路径，普通和quiet模式都应可读；无参数`minis-config get`应返回结构化错误及退出码1。
   补测`minis-config --actor`应返回参数错误；`minis-model-use --compact list`应保留list命令；`minis-model-use list --provider`应返回参数错误及退出码2。
4. 在新聊天发送“读取最近七天专注和心得”，保持聊天可见。验证`focus_query`、`mosaic_query`和`personal_records_query`返回的范围、时区及记录与页面一致。
5. 读取期间切后台或打开其他页面，旧结果应拒绝交付并说明原因；返回原聊天发送新请求，应重新查询。连续保持前台超过20分钟，确认没有仅由时间导致的授权失效。
6. 在主聊天或绑定的练习聊天执行下方拼图命令，`--limit 2`表示每页2个自然日，后续`--offset`采用返回的`next_offset`，直到null。Markdown命令不带`--compact`。更换设备时区后在新请求里核对今日日期，不要求历史日期标签随时区移动。
7. 先执行`minis-sessions-cli list --limit 5`，从`data.sessions[].session_id`复制ID，再执行`minis-sessions-cli status --id <session-id>`，替换占位符，确认仅有一层`data`；不存在的会话应在外层报告失败且退出非0。执行`minis-scheduled probe`，应直接提示缺少`--id`并退出2，不弹权限框或读取任务。
8. 在同一设备分别测试地图地名和明确坐标请求。先核对route或eta成功响应的`from`、`to`和`mode`，再与Apple地图相同交通方式比较。`--mode bogus`应立即拒绝，cycling不能悄悄显示driving。多候选应返回消歧提示，不取第一项。
9. 测试地图网络中断和恢复；服务返回的错误应保留阶段、错误域和原始代码，本地超时应返回`timeout`及阶段。晚到回调不能覆盖已返回的超时结果。路线可用性、真实距离、地区覆盖与网络恢复均待真机验证。

拼图分页示例：

```sh
minis-jigsaw-cli list --days 7 --limit 2 --offset 0 --compact
minis-jigsaw-cli list --days 7 --limit 2 --offset 0 --format md
```

读取第二页时，把`--offset 0`改成第一页返回的`next_offset`；JSON与Markdown分别执行，不能同时指定`--compact --format md`。

地图复测可使用公开地标坐标，避免地址同名影响判断：

```sh
apple-maps eta --from 40.7128,-74.0060 --to 42.3601,-71.0589 --mode driving
apple-maps route --from 37.7749,-122.4194 --to 34.0522,-118.2437 --mode driving
apple-maps search --query coffee --lat 42.3601 --lon -71.0589 --radius 1000
apple-maps route --from 40.7128,-74.0060 --to 42.3601,-71.0589 --mode bogus
```

这些命令是复测步骤，不代表本次已请求服务或确认返回距离。
