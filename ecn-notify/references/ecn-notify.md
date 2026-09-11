# ECN 通知 —— Skill 文档(本机落地版)

> 源文档:`/Users/mac/Downloads/ECN通知_Skill文档.md` #举例(本机下载目录,不在本仓库)
> 本文件是**本机单 profile 的落地版**:命令名、路径、定时器都按本机实际情况适配;
> 文中写出的本机路径与 profile 名都是**举例**,按自己环境替换。

## 目的

每天定时读取 ECN 抄送(未读 topic 17 / 已读 topic 18),把过去 24h 的新 ECN 简报推到
目标群;附件以话题形式挂到总结消息下,主聊天只留 1 条总结 + 「N 条回复」。

## 关键 ID 与常量

| 项目 | 值 |
|------|----|
| 审批定义 code | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`(内部标识,不放真实值;审批定义列表里取) |
| 抄送 topic 未读 / 已读 | `17` / `18` |
| 目标群 chat_id | `oc_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx`(内部标识,不放真实值;群设置 / chat 列表里取) |
| 群模式 | `group`(非 topic),仍支持 `--reply-in-thread` |
| 去重状态文件 | `/Users/mac/dsh-workspace/ecn-notify/ecn_sent.json` #举例 |
| 运行日志 | `/Users/mac/dsh-workspace/ecn-notify/logs/run.log` #举例 |
| 执行脚本 | `/Users/mac/.codex/skills/ecn-notify/scripts/ecn_notify.py` #举例 |
| cron 包装 | `/Users/mac/dsh-workspace/ecn-notify/run-ecn.sh` #举例 |
| launchd plist | `/Users/mac/dsh-workspace/ecn-notify/com.dsh.ecn-notify.daily.plist` #举例 |

## 身份要求(最容易翻车的一点)

| 步骤 | 身份 | 原因 |
|------|------|------|
| Step 1 拉抄送列表 | **user** | 抄送是"人的收件箱",tenant/bot token 读不到 |
| Step 3 拉实例详情 | **user** | 同上,form/附件按当前用户视角返回 |
| Step 5/6 发总结 + 挂附件 | **bot** | 群里发消息必须是群内 bot |

所以本机必须同时具备:
1. `lark-cli auth status` 里 `user.available == true`(device flow 授权过)
2. bot 已在目标群成员列表里

任一不满足,脚本会直接失败并打日志,**不会**退回 user 身份发消息(自动化禁止 `im:message.send_as_user`)。

## user 授权会过期吗(7 天的事)

| token | 寿命 | 说明 |
|-------|------|------|
| `user_access_token` | 2 小时 | 每次调用自动换 |
| `refresh_token` | **7 天** | **空闲窗口**,不是授权总寿命 |

7 天是"多久没用就作废",不是"授权只能用 7 天":refresh_token 换新 access_token 时
飞书会同时下发新的 refresh_token(旧的作废,复用报 `refresh_token_reused`),7 天重新计时。
本机每天 9:15 跑一次、每次都走 `--as user`,所以窗口天天被续上,正常情况永不掉线。

实证:同一账号在 claude profile 的授权 `grantedAt=2026-08-04`,到 9/11 仍 valid,
`refreshExpiresAt` 始终是「最近一次刷新 + 7 天」。

脚本开跑时 `check_user_token()` 会打一行剩余天数,< 2 天打 WARN。
掉线只有三种原因:连续 7 天没成功调用过 user 接口、用户侧撤销授权/改密码、`auth logout`。

## 本机与源文档的差异

| 源文档 | 本机现实 | 处理 |
|--------|---------|------|
| `/home/gem/.aily/workspace/ecn_sent.json` | 该路径不存在(另一台环境) | 改成 `/Users/mac/dsh-workspace/ecn-notify/ecn_sent.json` #举例 |
| `aily-cli auto create --trigger-type cron` | 本机无 `aily-cli` | 用 launchd(`launchd.plist`,`StartCalendarInterval` 9:15 本地时间)+ 包装脚本 |
| `--approval-code` 参数 | lark-cli 1.0.93 的 `approval tasks query` 参数名是 `--definition-code` | 脚本用 `--definition-code` |
| `--start-time` / `--end-time` | 实际参数是 `--start-timestamp` / `--end-timestamp` | 已改 |
| `approvals get` 查元信息 | 保留为可选排查手段 | `lark-cli approval approvals get` |

## 字段名坑(实测 + 官方文档核对)

字段名研究报告:`/Users/mac/dsh-workspace/审批API研究/飞书审批API字段报告.md` #举例(本机留档,不在本仓库;含文档与 SDK 原文)。
以下是脚本已经处理掉的坑,改脚本前先看一眼:

1. **`tasks[]` 里没有 `instance_code`**——实例 Code 挂在 **`process_code`**(Go SDK 注释:「审批流程 Code,即审批实例 Code」)。
   脚本按 `process_code` → `instance_code` → `instanceCode` 兜底。
2. **`form` 是 JSON 字符串**,不是对象——要先 `json.loads` 再遍历控件。
3. **附件控件的 `value` 是带签名的 URL 数组**(`attachmentV2` / `imageV2`),不是 `file_xxx` file_token;
   文件名在逗号分隔的 `ext` 里。**签名链接约 12 小时过期**,所以拉了必须当轮就发,不能缓存 URL 第二天补发。
4. **`tasks[].status` 两套口径**:文档字段表给数字串(`"1"/"2"/"17"`),官方示例给 `"Todo"/"Running"`——脚本两套都当字符串读。
5. **lark-cli 的输出流**:成功响应走 stdout,**失败响应(ok:false)走 stderr**,且同一个流里可能跟一段更新提示 `_notice`;
   `--page-all` 还会往 stderr 插 `[page N] fetching...` 进度行。
   所以判定只认带 `ok` 字段的对象,不能整段 `json.loads`,也不能"取最后一个 JSON"。
   这类解析错误会让「查询失败」静默变成「查到 0 条」,是最隐蔽的坑——脚本已改成查询失败直接 ABORT + 退出码 1。
6. **附件 URL 末段是 `authcode`**,不是文件名——把 URL 直接给 `--file`,群里的文件就叫 `authcode`(无扩展名)。
   真文件名只在下载响应的 `Content-Disposition` 里(`filename*=UTF-8''ECN2601010001.pdf`,文件名为举例)。详见下面「附件」一节。
7. **`instance_code` 是 UUID,不是业务编号**。业务编号分散在两处:表单控件「变更编号」
   (正常是 ECN 号,也有人填成 `B0...` 这种物料码),以及附件文件名。
   审批单编号是 `serial_number`(一串纯数字单号,永远有)。源文档 Step 3 里
   把业务编号当 `--instance-code` 传是错的,`instances get` 只吃 UUID。

## 流程(脚本已实现)

1. **窗口**:`now-86400` ~ `now`(unix 秒,滚动 24h)
2. **拉取**:topic 17 与 18 各查一次,按 `instance_code` 合并去重
3. **再对状态文件去重**:`ecn_sent.json` 里已有的跳过(`--ignore-state` 可跳过这步,重放用)
4. **取详情**:`approval instances get --instance-code X --as user`,抽 `form` / 附件
5. **下载附件**:逐个 `urllib` 下载到临时目录,按 `Content-Disposition` 还原真实文件名
6. **渲染 markdown** 总结(编号要用到上一步的文件名,所以下载在渲染之前)
7. **发总结**:`im +messages-send --chat-id <群> --as bot --markdown`,拿 `message_id`
8. **挂附件**:每个附件一次 `im +messages-reply --message-id <om_> --as bot --reply-in-thread --file <本地文件名>`,
   `cwd=<临时目录>`。发完 `rmtree` 临时目录
9. **写回**:把本次发过的 `instance_code` 追加进 `ecn_sent.json`(永远并集,`--ignore-state` 补发也不会冲掉历史)

## 简报格式(2026-09-11 定稿)

```
📋 ECN 发布通知 · 2026-01-01 11:02 ~ 2026-01-02 11:02
过去 24 小时新增 2 条

1. ECN2601010001
   • 变更内容:{示例:变更内容文本}
   • 关联包材:无
```

- 标题 = 日期 + 分钟级时间区间(滚动窗口两个端点都写全,跨天不含糊)
- 每条开头**只放一个编号**,不要 UUID / open_id / 发起人(之前那版就是被这三样搞乱的)
- 编号优先级:`变更编号`(ECN 形态)→ 附件文件名里的 ECN 号 → `serial_number`
- 不渲染「附件:N」

## 附件(踩过的坑,改这里前先读)

审批附件控件是 `attachmentV2`,其 `value` 是**签名 URL 数组**:

```
https://internal-api-drive-stream.feishu.cn/space/api/box/stream/download/authcode/?code=<几百字符签名>
```

- URL 里**没有文件名**,末段固定是字面量 `authcode`。
- `lark-cli im +messages-reply --file <URL>` 虽然能自动下载再上传,但**文件名取自 URL 末段**
  → 群里收到的文件叫 `authcode`,没有扩展名。这就是「下载出来为啥是 authcode」。
- 真文件名只在 HTTP 响应头的 `Content-Disposition`:
  `attachment; filename="ECN2601010001.pdf"; filename*=UTF-8''ECN2601010001.pdf`
- 所以脚本改成:自己下载 → 按响应头还原文件名(优先 RFC 5987 的 `filename*=`)→
  `--file <basename>` + `cwd=<tmpdir>` 上传。lark-cli 只接受 cwd 相对路径(绝对路径、`..` 会被拒)。
- 签名链接约 12h 过期,`dedup_attachments` 按去掉 query 的 URL 去重(同文件不同签名算一个)。
- 附带发现:有些附件内容是**公司文档加密(DRM)包裹**的(文件头能看到 DRM 标记),
  要在装了公司加密客户端的机器上才正常打开;这不是命名问题,也不在我们这条链路里。

## 静默规则

- 去重后无新 ECN → 只写日志,不发任何消息
- 实例详情拉取失败 → 跳过该条,总结末尾追加「异常说明」
- 附件 URL 取不到 / 发送失败 → 跳过该附件,其余照发

## 定时

```bash
# 安装(9:15 每天,本地时区)
launchctl load -w /Users/mac/dsh-workspace/ecn-notify/com.dsh.ecn-notify.daily.plist   #举例
# 手动触发验证
launchctl start com.dsh.ecn-notify.daily
# 卸载
launchctl unload -w /Users/mac/dsh-workspace/ecn-notify/com.dsh.ecn-notify.daily.plist #举例
```

时区注意:源文档提到 cron 时区坑。launchd 用系统本地时区,macOS 上是 Asia/Shanghai,不用额外处理;
但脚本按 unix 秒算窗口,和时区无关。

## 故障排查

| 现象 | 排查方向 |
|------|---------|
| `need_user_authorization` / `token_missing` | user 身份没授权或 token 过期 → 私聊里 `lark-cli auth login --no-wait --json --domain approval,im` 重新授权 |
| 日志 `refresh token 剩余 < 2 天` | 连续 7 天没跑过任务才会这样,提前重新授权;别等到真过期那天 |
| 日志出现 `ABORT 抄送查询失败` | 查询没跑通(**不是**"今天没有 ECN"),看上一行错误;退出码 1 |
| 日志里混进 `[page 1] fetching...` | lark-cli 输出格式变了,检查 `run_cli` 的 JSON 提取逻辑 |
| `1069303 Access denied` | 应用 scope 未开或应用未发布版本 |
| `invalid chat_id` / bot 不在群 | 管理员在群设置里把 bot 加回去 |
| 附件"下载失败" | 附件 URL 是带签名的临时链接(约 12h 过期),过期只能重拉实例详情 |
| 群里的附件名叫 `authcode` | 用回旧写法了(把 URL 直接给 `--file`)。必须自己下载、按 `Content-Disposition` 命名后再传 |
| 附件打不开 / 乱码 | 正常:原件是公司 DRM 加密的,要公司加密客户端打开 |
| 条目开头是 UUID | `变更编号` 和附件名里都没有 ECN 号 → 退回 `serial_number`;整条退到 UUID 说明详情拉取异常 |
| 重复发同一 ECN | 检查 `ecn_sent.json` 是否被清空 / 写入失败 |
| 拉了 0 条但明明有 ECN | 抄送过滤只认 topic 17/18;topic 1/2 是待办/已办审批,语义不同 |
