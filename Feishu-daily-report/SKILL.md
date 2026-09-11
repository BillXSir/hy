---
name: daily-work-report
label: 每日工作日报
description: 为指定飞书用户生成每日工作日报。从飞书多维度（IM 消息、文档更新、飞书任务、邮件）拉取该用户当日数据，按主题分组输出 bullet points，简洁罗列。Use when：用户说「生成我的工作日报」「今天的日报」「工作日报」「daily report」；或定时任务在每个工作日 18:20 触发生成 Bill（薛博鸿）的日报。已为该用户（Bill 薛博鸿 / bill@yarbo.com / 深圳汉阳科技·用户体验部·现场技术支持组）打通：IM 消息、文档搜索、飞书任务已开通；邮箱未开通会自动跳过。可通过 lark-cli / aily-cli 在任何具备对应权限的环境复现。
---

# 每日工作日报

为指定飞书用户生成一份当日工作日报。直接输出 bullet points 列表，简洁明了，不写大幅描述。

## 用户信息（默认目标用户）

- 姓名：Bill 薛博鸿
- 邮箱：bill@yarbo.com
- 用户 ID（user_id）：`7425452462591229956`
- open_id：`ou_22fe9916a6eb083f581cef0610a2b826`
- 部门：深圳汉阳科技·用户体验部·现场技术支持组

> 要换其他用户时，先在 `lark-cli contact +get-user` 取其 open_id / user_id，再把下面所有 `--sender` / `--creator-ids` 替换为目标用户的 open_id；时间窗与维度不变。

## 数据拉取（六个维度）

完整命令模板见 [references/data-fetching.md](references/data-fetching.md)。所有时间窗以"今天 0 点 ~ 当前时刻"为界，**时区用 +08:00**。

1. **今日 Bill 主动在飞书写的内容**——`lark-cli im +messages-search --sender <open_id> --start <今日00:00> --end <当前> --page-all`
2. **今日 Bill 主动回复、跟进、转发的消息**——同上条件 + `--exclude-sender-type user` 排除自己发的，看他回复了谁
3. **今日 @Bill / 公告通知**——`lark-cli im +messages-search --is-at-me --start ... --end ... --page-all`，再回看每条被 @ 消息的群聊上下文
4. **今日文档更新**——`lark-cli drive +search --created-by-me --edited-since <今日00:00> --edited-until <当前> --sort edit_time`（自己改的）；另起一条用 `--commented-since` / `--commented-until` 查自己被 @ 或评论的文档；核心文档用 `lark-cli drive +inspect --url <doc_url>` 拿 token，再 `lark-cli docs +fetch --doc <url_or_token> --scope outline` 拉取大纲与最新内容
5. **今日完成的飞书任务**——`lark-cli task +get-my-tasks --complete true --created_at <今日00:00>`
6. **邮件（可选）**——先 `lark-cli mail user_mailboxes profile --params '{"user_mailbox_id":"me"}}'` 探活；返回 "mailbox address not found" 或权限错即跳过该维度

## 需要的飞书权限 scope

完整 scope 清单与申请方式见 [references/permissions.md](references/permissions.md)。最小集合：

| 维度 | 所需 scope |
|---|---|
| IM 消息（搜索、读消息） | `im:message:readonly`（或 `im:message.group_at_message_detail:readonly` 用于 @我 类） |
| 云空间（搜索 / 读文档） | `drive:drive:readonly` + `docs:document.content:readonly` |
| 飞书任务（读） | `task:task:readonly` |
| 邮件（读） | `mail:user_mailbox:readonly`（可选；未开通时跳过） |
| 用户身份 | 用户身份 token（user_access_token），能以该用户身份调用 |

> 关键：执行身份必须是**用户身份**（`--as user`），这样搜出来的是该用户自己的数据；用 bot 身份搜不到私聊消息。

## 处理原则（关键）

按主题归并事件，不写「几点说了什么」。

- **去掉所有 HH:mm 时间戳**，按主题事件归并；不写「上午/下午/几点」
- **通过 Bill 自己发的消息反推事件背景**：例如 Bill 在群里问「现在做到哪了」「什么进度」「现在情况如何」—— 这是他在跟进某事，把前因后果串成一句完整事件
- **保留 Bill 的立场与观点**：他对某事的主张、反驳、要求、判断，必须写明
- **看 @ 消息前的群聊上下文**：识别 Bill 与对方正在讨论的核心问题，写成完整事件，而不是只摘孤立的被 @ 句
- **写「做了什么」而非「几点说了什么」**：只关心今天发生了什么主题事件
- **跨维度去重**：同一件事可能在 IM、文档、任务三个维度都出现（如「更新了 XX 文档并发到 XX 群」）—— 合并到一处，不要重复列
- **空模块省略**：今日没有的维度直接不写，不凑内容

## 输出结构

bullet points 形式，按主题分组。空模块直接省略。

```
📝 今日产出
- [Bill 主动写的内容 / 文档 / 完成任务，每条一句完整事件]

💬 跟进消息
- [Bill 主动回复 / 转发 / 跟进的对话，串成完整事件；体现他的立场]

📢 公告/通知
- [@Bill 的消息、群公告；说清楚事件背景，不要只摘被 @ 句]

📄 文档更新
- [今日更新的文档，说明更新内容或进度]
```

每个 bullet **一句话完整事件**，主谓宾齐全，不要 "他说 X" "回 Y" 这种断片。

## 风格与硬约束

- 风格：简洁罗列，bullet points 为主；避免大段描述
- 加粗克制（每个 bullet 至多一处）
- **不调用 im_message 发送**——日报由调用方（定时任务 / 用户对话）自行决定投递方式；本 skill 只产出内容
- **不修改任何飞书资源**（消息、文档、任务、日程）—— 本 skill 全部为只读操作
- 找不到任何数据时，输出「今日暂无工作记录」，不要硬凑内容
- 时间窗严格按当日（00:00 ~ 当前），跨日数据不收

## 复用建议

- 接入 `aily-cli auto` 做成定时任务：cron `0 20 18 * * 1-5`（工作日 18:20），把整段 instruction 喂给 `--instruction`；本 skill 即 instruction 的「完整版」
- 外部模型（Claude / GPT / 其他）通过 lark-cli 复现时，instruction 模板见 [references/data-fetching.md](references/data-fetching.md) 末尾
