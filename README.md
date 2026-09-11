# hy

个人 skill / 工具集散地。

> **脱敏说明**:仓库里出现的本机路径、profile 名都是**举例**(标 `#举例`),按自己环境替换;
> 群 chat_id、审批定义 code、实例 UUID 这类内部标识一律用占位符给出,真实值不进仓库。
> **仓库里不含任何 token / 密钥**——凭据只存在本机 `lark-cli` 的 profile 里,由 `lark-cli auth login`
> 走一遍 OAuth 得到,脚本与文档里一个字都不出现。

## 目录

| 目录 | 说明 |
|------|------|
| `ecn-notify/` | 飞书 ECN 抄送简报:每 24h 拉审批抄送,汇总发到飞书群,附件挂话题 |

## ecn-notify

把飞书审批「ECN 发布通知」的抄送(未读 + 已读)里过去 24h 的新条目,汇总成一条简报发到指定群,
附件以话题回复挂载;无新条目则完全静默。

```
ecn-notify/
├── SKILL.md                              主文件(给 agent 读的 skill 定义)
├── references/ecn-notify.md              详细参考:Lark CLI 命令、字段坑、故障排查
├── scripts/ecn_notify.py                 主脚本(纯标准库)
├── scripts/test_parsers.py               离线自测(不联网、不调 CLI)
└── runner/
    ├── run-ecn.sh                        运行入口
    └── com.dsh.ecn-notify.daily.plist    launchd 定时(每天 9:15)
```

### 依赖

- `lark-cli`(lark-channel profile,bot 身份 + user 身份 OAuth 授权都要有)
- Python 3(标准库,无第三方依赖)
- macOS + launchd(定时;换 Linux 用 cron 等价替换)

### 安装

```bash
# 1. skill 本体放 agent 的 skills 目录(目录名保持 ecn-notify)
cp -R ecn-notify ~/.codex/skills/          # Codex
# cp -R ecn-notify ~/.claude/skills/       # Claude Code

# 2. 运行目录(脚本、去重状态、日志)
mkdir -p ~/dsh-workspace/ecn-notify
cp ecn-notify/runner/run-ecn.sh ~/dsh-workspace/ecn-notify/
cp ecn-notify/runner/com.dsh.ecn-notify.daily.plist ~/dsh-workspace/ecn-notify/
```

脚本里的路径、群 `chat_id`、审批定义 code 都按实际环境改(文档里这些值都是举例或占位符)。详见 `ecn-notify/SKILL.md`。

### 自测

```bash
python3 ecn-notify/scripts/test_parsers.py
```
