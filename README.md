# hy

个人 skill / 工具集散地。

> **脱敏说明**:仓库里出现的本机路径、profile 名都是**举例**(标 `#举例`),按自己环境替换;
> 群 chat_id、审批定义 code、实例 UUID 这类内部标识一律用占位符给出,真实值不进仓库。
> **仓库里不含任何 token / 密钥**——凭据只存在本机 `lark-cli` 的 profile 里,由 `lark-cli auth login`
> 走一遍 OAuth 得到,脚本与文档里一个字都不出现。

## 目录

| 目录 | 说明 |
|------|------|
| `ecn-notify/` | 飞书 ECN 抄送简报:每 24h 拉审批抄送,汇总发到飞书群,附件挂话题,失败私聊告警 |
| `Feishu-daily-report/` | 飞书每日工作日报:从 IM / 文档 / 任务 / 邮件多维度拉当日数据,生成 bullet 式日报 |
| `machine-repair/` | 现场设备维修手册 + 可执行脚本:每个问题一个目录,默认"先跑安全模式拿判定再分析" |

## machine-repair

现场设备(机器人 / 边缘盒子)的维修操作手册。核心是**每个问题都有一条安全的一键命令**:默认只读或可逆,
不写文件、不重启、不碰固件,先拿到明确 verdict 再决定要不要动系统。破坏性与持久化动作一律藏在显式参数后面。

```
machine-repair/
├── README.md                                      总纲:铁律、目录约定、新增问题模板
└── bluetooth-dead-hci0/                           蓝牙"僵尸 hci0"(适配器在但从未初始化)
    ├── README.md                                  症状指纹 → 判定表 → 修复阶梯 → 回滚
    ├── bt-dead-hci0.sh                            一键脚本(diagnose/fix/install/uninstall)
    ├── deploy-remote.sh                           远程部署器(默认目标 37.38.39.8,一条命令修一台)
    └── case-yarbo-firmware-race.md                真实案例:开机竞速导致固件 ENOENT
```

当前收录的问题:

| 问题 | 症状指纹 |
|---|---|
| 蓝牙"僵尸 hci0" | `hciconfig` 有 `hci0`,但 `DOWN` + `BD Address: 00:00:00:00:00:00` + `Features` 全零 |

详见 `machine-repair/README.md`。


## ecn-notify

把飞书审批「ECN 发布通知」的抄送(未读 + 已读)里过去 24h 的新条目,汇总成一条简报发到指定群,
附件以话题回复挂载;无新条目则完全静默。**真失败会私聊告警**(无新条目、电脑休眠导致跑晚都不算失败)。

```
ecn-notify/
├── SKILL.md                              主文件(给 agent 读的 skill 定义)
├── references/ecn-notify.md              详细参考:Lark CLI 命令、字段坑、故障排查
├── scripts/ecn_notify.py                 主脚本(纯标准库)
├── scripts/test_parsers.py               离线自测(不联网、不调 CLI,89 项)
└── runner/
    ├── run-ecn.sh                        运行入口
    └── com.dsh.ecn-notify.daily.plist    launchd 定时(每天 9:15)
```

### 两个值得抄的设计

1. **滚动窗口兜底**:窗口左界 = `min(now-86400, 状态里最早的已发记录时间 - 5min)`,
   机器休眠 / 关机超过 24h 再唤醒时,缺口能被捞回来;重复推送由去重表挡住。
   写死 `now-86400` 的版本会永久漏掉那段时间里发生的条目。
2. **失败主动私聊告警**:错误先分类(auth / network / permission / other),只有网络类才重试
   (3 次,间隔 5 秒——凌晨唤醒时 WiFi 还在重连,这个窗口最容易连不上);真失败私聊一条,
   同类 20 小时冷却。为什么需要:「今天没有新条目」和「跑了但失败了」在群里长得一模一样。

状态文件 `ecn_sent.json` 同时存去重表与告警冷却记录:

```json
{
  "sent":   { "<instance_code>": "2026-09-14T09:15:03+08:00" },
  "alerts": { "<告警类型>":      "2026-09-14T09:15:04+08:00" }
}
```

旧的纯数组格式(只有去重码、没时间戳)在读取时自动迁移,不用手工改。

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
