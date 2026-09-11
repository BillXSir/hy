# 飞书权限 scope 清单

为运行"每日工作日报"skill，外部 LLM 调 lark-cli 时需要以下权限。

## 必需 scope（缺一不可）

| 维度 | scope 名 | 用途 |
|---|---|---|
| 用户身份 | user_access_token | 必须以**用户身份**调 `--as user`，搜私聊/IM 消息时 bot 身份拿不到 |
| IM 消息 | `im:message:readonly` 或 `im:message:list:readonly` | 搜索/读消息、拿群聊上下文 |
| IM 消息 | `im:message.group_at_message_detail:readonly` | `@me` 过滤、群公告详情 |
| 云空间 | `drive:drive:readonly` | drive +search 搜文档 |
| 云空间 | `docs:document.content:readonly` 或 `docs:doc:readonly` | docs +fetch 读文档正文 |
| 飞书任务 | `task:task:readonly` | task +get-my-tasks 拉任务 |

## 可选 scope

| 维度 | scope 名 | 用途 |
|---|---|---|
| 邮件 | `mail:user_mailbox:readonly` | 拉邮件；未开通则跳过此维度，不影响其它 |

## 用户身份 token 获取

lark-cli 默认使用当前用户身份（在调用者登录环境注入），不需要在 prompt 里写 user_access_token。但被调用的 LLM 必须运行在**已登录飞书用户态**的环境里（aily 平台 / 飞书开放平台 SDK 注入 / lark-cli `login` 子命令）。

## 在 aily 平台内运行（默认情况）

Bill 当前账号已开通（除邮箱外）：

- ✅ IM 消息（im:*）
- ✅ 云空间文档（drive:* / docs:*）
- ✅ 飞书任务（task:*）
- ❌ 邮箱（mail:*）— 未开通，skill 会自动跳过

不需要额外申请，run 起来直接可用。

## 在外部环境运行（Claude/GPT/其他模型 CLI）

1. 给该 LLM 的运行环境装 `lark-cli`（`pip install lark-cli` 或下载 binary）
2. 在环境里 `lark-cli login`，用飞书账号扫码授权
3. 确认 token 已注入：`lark-cli contact +get-user --as user` 能返回当前用户即 OK
4. skill 的 description 在触发 LLM 看到后，agent 自行按 references/data-fetching.md 里的命令模板调 lark-cli 即可

## 权限申请（按需）

如果某个 scope 不足，lark-cli 调用会返回 `99991663 | 99991664` 等权限错码：

1. 去飞书开放平台 → 应用后台 → 「权限管理」搜对应 scope 名
2. 应用类型：**自建应用**（个人/小团队）或**企业自建应用**（公司统一管理）
3. 企业自建应用 scope 由租户管理员审批；个人应用一般直接通过
4. 审批通过后 lark-cli 重新 `login` 一次即可生效
