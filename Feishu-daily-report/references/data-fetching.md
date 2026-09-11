# 数据拉取命令模板

六个维度的 lark-cli 命令。所有时间用 ISO 8601 + 时区，**统一 +08:00**。所有 `--as user` 是读操作的默认身份。

> 时间变量（每个 Run 现场实算，不要硬编码）：
> - `TODAY_START`：当天 00:00:00 +08:00，例 `2026-09-11T00:00:00+08:00`
> - `NOW`：当前时刻 +08:00，例 `2026-09-11T18:20:00+08:00`
>
> Python 算当前：把 `datetime.now(ZoneInfo("Asia/Shanghai"))` 格式化为 `%Y-%m-%dT%H:%M:%S+08:00`，当天的 0 点用 `.replace(hour=0,minute=0,second=0,microsecond=0)`。

## 1. Bill 今日主动发的消息

```bash
# Bill 自己的 open_id：ou_22fe9916a6eb083f581cef0610a2b826
lark-cli im +messages-search \
  --as user \
  --sender ou_22fe9916a6eb083f581cef0610a2b826 \
  --sender-type user \
  --start "$TODAY_START" \
  --end "$NOW" \
  --page-all
```

返回：Bill 今日作为发送者的全部消息，含 chat_id / content / 时间。按 chat_id 分组得到他在每个群/会话写了什么。

## 2. Bill 今日主动回复、跟进、转发的消息

看 Bill 回复了哪些别人的消息（他的回复上下文）—— 用维度 1 的数据按 thread / parent 字段挑；如需独立查"Bill 在哪些对话里参与了发言"：

```bash
# 任何 Bill 出现过的会话消息，但排除他自己发的
lark-cli im +messages-search \
  --as user \
  --at-chatter-ids ou_22fe9916a6eb083f581cef0610a2b826 \
  --start "$TODAY_START" \
  --end "$NOW" \
  --page-all \
  --exclude-sender-type user
```

（实际更稳的是维度 1 + 看 message.thread / parent_message_id；维度 1 拿到的 Bill 消息里如果带 `parent_message_id`，往上回拉 2~3 条就是 Bill 看到的"被回复消息"原文。）

## 3. 今日 @Bill / 公告通知

```bash
lark-cli im +messages-search \
  --as user \
  --is-at-me \
  --start "$TODAY_START" \
  --end "$NOW" \
  --page-all
```

每条结果里取 `chat_id` + `message_id`，对每条用：

```bash
# 拉该消息前后 3 条上下文，识别事件背景
lark-cli im +messages-list \
  --as user \
  --chat-id <chat_id> \
  --start <消息时间前30分钟> \
  --end <消息时间后30分钟>
```

## 4. 今日文档更新

### 4a. Bill 自己今天编辑过的文档

```bash
lark-cli drive +search \
  --as user \
  --created-by-me \
  --edited-since "$TODAY_START" \
  --edited-until "$NOW" \
  --sort edit_time \
  --page-all
```

### 4b. 今天被 Bill 评论 / 被通知更新的文档

```bash
lark-cli drive +search \
  --as user \
  --commented-since "$TODAY_START" \
  --commented-until "$NOW" \
  --page-all
```

### 4c. 拿核心文档的最新内容

对维度 4a/4b 命中里需要看具体内容的（不是每条都拉，**只看高优 / 重要变更的 1~3 篇**）：

```bash
# 解析出 token / URL
lark-cli drive +inspect --as user --url "<wiki 或 docx 完整 URL>"

# 拉大纲（看更新了哪几节）
lark-cli docs +fetch --as user --doc "<url or token>" --scope outline

# 拉某节最新内容
lark-cli docs +fetch --as user --doc "<url or token>" --scope section --start-block-id <heading 的 block id>
```

## 5. 今日完成的飞书任务

```bash
lark-cli task +get-my-tasks \
  --as user \
  --complete true \
  --created_at "$TODAY_START" \
  --page-all
```

> `--created_at` 是任务创建时间；如果要按"完成时间"查，单接口不支持完成时间过滤，需要拉全量再按 `completed_at` 过滤（`--page-all` + 后处理）。

## 6. 邮件（可选）

先探活：

```bash
lark-cli mail user_mailboxes profile \
  --as user \
  --params '{"user_mailbox_id":"me"}'
```

- 成功：返回 mailbox profile，可继续 `lark-cli mail user_mailboxes search --params '{"user_mailbox_id":"me","start_time":"'$TODAY_START'","end_time":"'$NOW'"}'`
- 报错 / 返回 "mailbox address not found"：跳过该维度，日报里直接不写邮件

## 外部模型 instruction 模板

如果要把整段塞进外部 LLM（比如 Claude / GPT / 自定义 agent）的 prompt，让它通过 lark-cli 复现：

```text
你是一个飞书工作日报生成助手。目标用户：Bill 薛博鸿（open_id ou_22fe9916a6eb083f581cef0610a2b826，部门 深圳汉阳科技·用户体验部·现场技术支持组）。

按以下六个维度拉取今日数据（时间窗：今天 00:00:00 +08:00 ~ 当前时刻 +08:00）：

1. lark-cli im +messages-search --as user --sender ou_22fe9916a6eb083f581cef0610a2b826 --sender-type user --start "<今日00:00>" --end "<当前>" --page-all
2. lark-cli im +messages-search --as user --at-chatter-ids ou_22fe9916a6eb083f581cef0610a2b826 --start ... --end ... --page-all --exclude-sender-type user
3. lark-cli im +messages-search --as user --is-at-me --start ... --end ... --page-all；每条用 im +messages-list 拿上下文
4. lark-cli drive +search --as user --created-by-me --edited-since <今日00:00> --edited-until <当前> --sort edit_time --page-all
5. lark-cli task +get-my-tasks --as user --complete true --created_at <今日00:00> --page-all
6. lark-cli mail user_mailboxes profile --as user --params '{"user_mailbox_id":"me"}'，失败则跳过

按主题归并事件，**去掉 HH:mm 时间戳**。每个 bullet 一句完整事件，体现 Bill 的立场。空模块省略。

输出格式（bullet points）：
- 📝 今日产出（Bill 主动写的内容 / 文档 / 完成任务）
- 💬 跟进消息（Bill 主动回复 / 转发 / 跟进的对话，串成事件）
- 📢 公告/通知（@他的消息、群公告，说明事件背景）
- 📄 文档更新（今天有更新的文档）

风格：简洁罗列；不调用 im_message 发送；不修改飞书资源；找不到任何数据时输出"今日暂无工作记录"。
```

把这段贴到任何支持 tool-use 的外部 LLM（让它能调 lark-cli）即可复现。
