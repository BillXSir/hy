#!/usr/bin/env bash
# ============================================================
# ECN 通知 —— launchd 包装脚本
# 触发: com.dsh.ecn-notify.daily.plist (每天 9:15 本地时间)
# 手动跑: bash ~/dsh-workspace/ecn-notify/run-ecn.sh [--dry-run]        #举例
# 逻辑与参数说明见 skill: ~/.codex/skills/ecn-notify/SKILL.md
# ============================================================
set -uo pipefail

export HOME="/Users/mac"                                   #举例:换成自己的家目录
export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
# lark-cli 的 lark-channel 上下文（dsh profile）—— 不要用 env -u LARK_CHANNEL 绕回本机普通配置
export LARK_CHANNEL=1
export LARK_CHANNEL_HOME="$HOME/.lark-channel"
export LARK_CHANNEL_PROFILE=dsh                #举例:profile 名换成你自己的
export LARKSUITE_CLI_CONFIG_DIR="$HOME/.lark-channel/profiles/dsh/lark-cli"
export LARK_CHANNEL_CONFIG="$HOME/.lark-channel/profiles/dsh/lark-cli-source/config.json"

ECN_DIR="$HOME/dsh-workspace/ecn-notify"
SCRIPT="$HOME/.codex/skills/ecn-notify/scripts/ecn_notify.py"
LOG="$ECN_DIR/logs/launchd.log"

mkdir -p "$ECN_DIR/logs"

{
  echo "== $(date '+%Y-%m-%d %H:%M:%S') launchd 触发 =="
  /usr/bin/python3 "$SCRIPT" "$@"
  echo "== exit=$? =="
} >>"$LOG" 2>&1
