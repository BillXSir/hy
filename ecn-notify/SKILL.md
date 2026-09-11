---
name: ecn-notify
description: 拉取飞书 ECN 审批抄送(审批定义 code 见脚本常量,抄送 topic 17 未读 / 18 已读),把过去 24h 新增 ECN 简报以 bot 身份发到目标群,附件挂话题,并维护去重状态。用于运行、调试、改动或排查这条 ECN 通知流水线。
metadata:
  short-description: ECN 抄送简报推送到目标群
---

# ECN 通知(ECN 抄送简报)

每天把 ECN 抄送(未读 topic 17 / 已读 topic 18)里过去 24h 的新条目,汇总成一条简报发到
目标群(群名与 chat_id 属内部标识,这里不放真实值;填 `scripts/ecn_notify.py` 顶部的 `CHAT_ID`),
附件以话题回复挂载;主聊天只有 1 条总结 + 「N 条回复」。无新 ECN 则完全静默。

> **脱敏说明**:本文件里的本机路径、profile 名都是**举例**(标 `#举例`),照自己环境改;
> 群 chat_id、审批定义 code、实例 UUID 这类内部标识一律用占位符,真实值不进仓库。
> **仓库里不含任何 token / 密钥**——凭据只存在本机 `lark-cli` 的 profile 里,靠 `lark-cli auth login` 走 OAuth 拿到,代码里一个字都不出现。

## 执行

```bash
# 正常跑(定时/手动一致)
bash /Users/mac/dsh-workspace/ecn-notify/run-ecn.sh            #举例:路径按自己的运行目录改
# 只渲染不发送、不写状态(会把附件下载下来、打印还原后的真实文件名)
bash /Users/mac/dsh-workspace/ecn-notify/run-ecn.sh --dry-run
# 无视去重表重放一遍(核对格式最顺手;写回与磁盘状态取并集,不会冲掉历史)
bash /Users/mac/dsh-workspace/ecn-notify/run-ecn.sh --dry-run --ignore-state
# 真补发(会真发群,慎用):去掉 --dry-run,只补发的条目同样进话题
bash /Users/mac/dsh-workspace/ecn-notify/run-ecn.sh --ignore-state --window 3600
# 自定义回看窗口(秒)
bash /Users/mac/dsh-workspace/ecn-notify/run-ecn.sh --window 3600
```

逻辑都在 `scripts/ecn_notify.py`(纯标准库,不改逻辑就别重写):
拉抄送 → 按 `instance_code` 去重 → 取实例详情 → **下载附件并还原真实文件名** → 渲染 markdown
→ bot 发群 → 附件 `--reply-in-thread`(按本地文件名上传) → 写回 `ecn_sent.json`。

改解析逻辑后跑离线自测(不联网、不调 CLI):

```bash
/usr/bin/python3 /Users/mac/.codex/skills/ecn-notify/scripts/test_parsers.py   #举例:skill 目录按自己的位置改
```

## 简报格式约定(2026-09-11 按反馈定稿,别改回去)

- **标题**:`📋 ECN 发布通知 · <起始 时分> ~ <结束 时分>`——日期后面直接跟时间区间,精确到分钟
- **每条开头只写一个编号**:优先表单「变更编号」里的 ECN 号 → 再退到附件文件名里的 ECN 号
  (有的单子变更编号栏被填成 B0 物料码,真 ECN 号只在附件名里,如 `ECN2601010004.pdf`)
  → 最后退到审批单编号 `serial_number`。**不写** UUID / instance_code / open_id / 发起人
- **不写「附件:N」这一行**(附件本体在话题里,计数没用)
- 表单默认提示文案(如「非必填选项,产品经理填写」)当空处理,渲染成「无」
- 编号口径想改成只认审批单号:改 `ecn_notify.py` 的 `HEADER_ID_MODE = "serial"`
- **不要改回去**:编号后面不要再跟 UUID / open_id / 发起人;别再渲染「附件:N」

## 附件:必须自己下载再上传(否则群里的文件名是 `authcode`)

审批附件控件 `value` 是签名 URL,末段固定是 `.../stream/download/authcode/?code=...`。
**把 URL 直接交给 `im +messages-reply --file`,lark-cli 会拿 URL 末段当文件名 —— 群里的文件就叫
`authcode`,连扩展名都没有。** 这就是「下载出来为啥是 authcode」的原因。

正解(脚本已实现):自己 `urllib` 下载 → 从响应头 `Content-Disposition`
(`filename*=UTF-8''...`)取真实文件名(实测 `ECN2601010001.pdf`,文件名为举例)→ 落盘到临时目录
→ `--file <文件名>` + `cwd=<临时目录>` 上传(lark-cli 只吃 cwd 相对路径,绝对路径和 `..` 会被拒)。

顺序上**先下载再渲染再发送**:条目开头的编号要用附件文件名里的 ECN 号。
签名链接约 12h 过期,下载和发送必须同一轮完成。

## 身份硬约束

- 拉抄送 + 取实例详情必须 `--as user`(抄送是人的收件箱,tenant/bot token 读不到)
- 发消息必须 `--as bot`(群里只有群内 bot 能发言)
- **自动化禁止**以 user 身份发消息(`im:message.send_as_user`),不要为了"跑通"把发送换成 user
- 前置条件:`lark-cli auth status` 里 `user.available == true`,且 bot 在群成员列表里。
  缺 user 授权时脚本会直接失败并写日志——此时在**私聊**里跑
  `lark-cli auth login --no-wait --json --domain approval,im`,把 `verification_url` 原样发给用户,
  用户点完再跑 `lark-cli auth login --device-code <code>` 收尾

## 授权与 token 续期(7 天是「空闲窗口」,不是授权总寿命)

实测口径(`lark-cli auth status --json`):

| token | 寿命 |
|-------|------|
| `user_access_token`(`expiresAt`) | 2 小时 |
| `refresh_token`(`refreshExpiresAt`) | **7 天**(空闲窗口,滑动) |

**关键:7 天不是"授权只能活 7 天"。** 每次以 user 身份调用会拿 refresh_token 换新
access_token,飞书同时下发**新的 refresh_token**(旧的作废,复用会报 `refresh_token_reused`),
7 天重新计时。所以只要任务**至少每 7 天跑一次**,就永远不会掉线——本机每天 9:15 跑,
每次都走 `--as user` 拉抄送,等于每天自动续期一次。

证据:同一个账号在 claude profile 的授权 `grantedAt = 2026-08-04`,到 9/11 仍 valid,
`refreshExpiresAt` 一直是「最近一次刷新 + 7 天」——就是滚出来的,不是固定死在授权当天。

**真正会掉线的情况**(届时只能重新授权,没有别的办法):

- 连续 7 天没跑(机器关机 / launchd 没装 / 手动 unload / 脚本一直报错没成功调过 user 接口)
- 你在飞书里撤销了应用授权、改密码,或管理员改了应用权限
- 换机器 / `lark-cli auth logout`

脚本每次开跑会打一行 `user 身份就绪,refresh token 剩余 N 天`;不足 2 天会打 WARN。
看到 WARN 就在**私聊**里重新走一遍 device flow:

```bash
lark-cli auth login --no-wait --json --domain approval,im   # 拿 verification_url 原样发给用户
lark-cli auth login --device-code <code>                    # 前台阻塞到用户点完
```

## 状态与日志

| 文件 | 作用 |
|------|------|
| `/Users/mac/dsh-workspace/ecn-notify/ecn_sent.json` #举例 | 已发 instance_code,防止重复推送。误清空 = 当天重发 |
| `/Users/mac/dsh-workspace/ecn-notify/logs/run.log` #举例 | 每次运行的逐条日志(topic 命中数、失败项、message_id) |
| `/Users/mac/dsh-workspace/ecn-notify/logs/launchd.log` #举例 | launchd 触发记录 |

排查先看 `run.log` 最后一段。静默(0 条)是正常行为,不是故障。

## 定时

launchd,每天 9:15 本地时间:

```bash
launchctl load -w /Users/mac/dsh-workspace/ecn-notify/com.dsh.ecn-notify.daily.plist     #举例
launchctl start com.dsh.ecn-notify.daily      # 手动触发一次
launchctl unload -w /Users/mac/dsh-workspace/ecn-notify/com.dsh.ecn-notify.daily.plist   #举例
```

不装 `RunAtLoad`、不做闲时预跑:24h 滚动窗口对时间敏感,凌晨预跑会漏掉 3-9 点发生的 ECN。

## 更多

命令差异、静默规则、字段名坑、故障排查表:
[references/ecn-notify.md](references/ecn-notify.md)。
字段名研究报告(官方文档 + SDK 原文留档):`/Users/mac/dsh-workspace/审批API研究/飞书审批API字段报告.md` #举例(本机留档,不在本仓库)。
