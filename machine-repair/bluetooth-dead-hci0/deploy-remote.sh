#!/usr/bin/env bash
# ==============================================================================
# deploy-remote.sh — 给一台新设备跑完蓝牙僵尸 hci0 的全流程
#
# 用法:
#   ./deploy-remote.sh YARBO@10.0.0.5                     # 诊断 + 修当次（安全模式，不写文件）
#   ./deploy-remote.sh YARBO@10.0.0.5 --install           # 再加开机自愈（默认顺带屏蔽 rtl_btusb）
#   ./deploy-remote.sh YARBO@10.0.0.5 --install --reboot  # 装完重启并验证持久化生效
#   ./deploy-remote.sh YARBO@10.0.0.5 --no-blacklist --install
#   ./deploy-remote.sh YARBO@10.0.0.5 --uninstall         # 回滚持久化改动
#   ./deploy-remote.sh YARBO@10.0.0.5 --diagnose          # 纯只读
#
# 只依赖系统自带 ssh / scp。密码交互输入，靠 ControlMaster 复用，整个流程只输一次。
# 脚本里不含任何凭据。
# ==============================================================================
set -u

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$SELF_DIR/bt-dead-hci0.sh"
REMOTE_SCRIPT=/tmp/bt-dead-hci0.sh
BLACKLIST=rtl_btusb
DO_BLACKLIST=1
DO_INSTALL=0
DO_UNINSTALL=0
DO_REBOOT=0
MODE_ARG=""

usage() { sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'; }

[ $# -ge 1 ] || { usage; exit 2; }
TARGET=$1; shift

for a in "$@"; do
  case "$a" in
    --install)      DO_INSTALL=1 ;;
    --uninstall)    DO_UNINSTALL=1 ;;
    --reboot)       DO_REBOOT=1 ;;
    --diagnose)     MODE_ARG=--diagnose ;;
    --no-blacklist) DO_BLACKLIST=0 ;;
    --blacklist=*)  BLACKLIST=${a#*=} ;;
    --help|-h)      usage; exit 0 ;;
    *)              echo "未知参数: $a" >&2; exit 2 ;;
  esac
done

[ -f "$SCRIPT" ] || { echo "找不到 $SCRIPT" >&2; exit 1; }

HOST=${TARGET#*@}
CTL=/tmp/.deploy-bt-$$-%r@%h:%p
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ControlMaster=auto
          -o "ControlPath=$CTL" -o ControlPersist=10m -o ConnectTimeout=15)
cleanup() { ssh "${SSH_OPTS[@]}" -O exit "$TARGET" >/dev/null 2>&1 || true; }
trap cleanup EXIT

rrun() { ssh -t "${SSH_OPTS[@]}" "$TARGET" "$@"; }

echo "== [1] 上传脚本到 $TARGET =="
scp -q "${SSH_OPTS[@]}" "$SCRIPT" "$TARGET:$REMOTE_SCRIPT" || { echo "上传失败" >&2; exit 1; }
echo "   ok -> $REMOTE_SCRIPT"

if [ "$DO_UNINSTALL" = 1 ]; then
  echo "== [2] 回滚持久化改动 =="
  rrun "sudo bash $REMOTE_SCRIPT --uninstall"
  exit $?
fi

echo "== [2] 诊断 + 必要时修复（安全模式：不写文件 / 不重启 / 不碰固件）=="
rrun "sudo bash $REMOTE_SCRIPT ${MODE_ARG}"

if [ "$DO_INSTALL" = 1 ]; then
  echo "== [3] 安装开机自愈 =="
  if [ "$DO_BLACKLIST" = 1 ]; then
    echo "   同时屏蔽外部模块: $BLACKLIST（不想要就加 --no-blacklist）"
    rrun "sudo bash $REMOTE_SCRIPT --install --blacklist $BLACKLIST"
  else
    rrun "sudo bash $REMOTE_SCRIPT --install"
  fi
else
  echo "== [3] 跳过持久化（要装开机自愈加 --install）=="
fi

if [ "$DO_REBOOT" = 1 ]; then
  echo "== [4] 重启并验证持久化 =="
  rrun "sudo systemctl reboot" >/dev/null 2>&1 || true
  cleanup
  echo "   等待 $HOST 回到 SSH..."
  back=0
  for i in $(seq 1 60); do
    if nc -z -G 3 -w 3 "$HOST" 22 >/dev/null 2>&1; then
      echo "   [ok] $((i*5))s 后恢复"; back=1; break
    fi
    sleep 5
  done
  [ "$back" = 1 ] || { echo "   [xx] 120s 内未恢复，请人工确认设备状态" >&2; exit 1; }
  sleep 20
  echo "   开机后状态:"
  rrun 'echo "--- 时序 ---"; dmesg | grep -E "VFS: Mounted root" | head -1; dmesg | grep -E "hci[0-9]+: RTL: (loading|fw version)" | head -3; echo "--- 自愈日志 ---"; sudo cat /var/log/bt-dead-hci0.log 2>/dev/null | tail -3; echo "--- 适配器 ---"; hciconfig 2>/dev/null | head -6; echo "--- 驱动 ---"; lsusb -t 2>/dev/null | grep -i wireless; lsmod | grep -E "rtl_btusb|rtk_btusb" || echo "   无厂商模块"'
fi

echo
echo "== 完成 =="
echo "   判定表: OK=转查应用层 | ZOMBIE+RACE=装 --install | ZOMBIE+MISSING=补固件"
echo "   下次同一台只需: ./deploy-remote.sh $TARGET --diagnose"
