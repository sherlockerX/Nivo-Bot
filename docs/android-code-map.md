# Android源码地图

以`android/src/android/app/src/main/java/`为起点。`com/openminis/app/`承载上游聊天、模型、工具和系统功能；`io/github/nanomuse/`承载本分支扩展。保留两者边界便于合并上游。

|场景|业务层|界面层|关键约束|
|---|---|---|---|
|主要聊天|`chat/`、上游`ui/chat/ChatViewModel.kt`|`ui/chat/`、`ui/home/`|当前用户授权、前台工具门禁、回复朗读|
|每日点子|`ideas/`|`ui/ideas/`|日期刷新、分类选择、进入对话|
|待办|`todo/TodoStore.kt`、`TodoAgentBridge.kt`、`TodoBackup.kt`|`ui/todo/`|账号、revision、幂等、完成原话|
|专注|`focus/FocusStore.kt`、`FocusTiming.kt`、`FocusStatistics.kt`|`ui/focus/`|单调时间、暂停不累计、到期封顶、结束不完成任务|
|生活碎片|`mosaic/MosaicStore.kt`、`MosaicDatabase.kt`|`ui/mosaic/`|草稿、关联快照、事务一致性|
|教练|`coach/`、`growth/`|`ui/coach/`、`ui/feed/`|课程与训练证据、聊天衔接、掌握边界|
|账号与同步|`account/`、`sync/`、`cloud/`|设置与首页|账号代次隔离、旧请求失效|
|语音与媒体|`speech/`、`call/`、`media/`|聊天与配置页|系统TTS和外部服务证据分开|

## 从一个交互追到数据

```text
首页/侧栏入口
  → ui/<模块>/页面
  → <模块>/Store（账号与事务）
  → Room DAO / 实体
  → Flow通知页面

聊天工具调用
  → ChatViewModel风险与前台门禁
  → AgentBridge参数校验
  → 同一Store事务
  → 结构化结果与页面入口
```

待办与专注不应另建一套“AI专用数据库”。UI和工具共用Store，防止聊天里说已保存、页面里却找不到。

## 测试入口

- `app/src/test/java/io/github/nanomuse/`：纯规则、协议与回归。
- `app/src/androidTest/java/io/github/nanomuse/todo/`：Room、分类、备份、并发和版本冲突。
- `app/src/androidTest/java/io/github/nanomuse/focus/`：协议、计时、迁移、全屏和日记关联。
- `app/schemas/`：Room历史结构，迁移测试依赖。

## 优先维护方向

先保持数据正确与边界清楚，再按具体问题提取小组件。`ChatViewModel`规模较大，适合以后逐功能抽离，但应有独立变更和回归，不与宣传页改动混在一起。当前不做大范围包迁移、业务重命名或格式化。
