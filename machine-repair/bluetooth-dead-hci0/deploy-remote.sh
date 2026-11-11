#!/usr/bin/env bash
# ==============================================================================
# deploy-remote.sh — 给一台设备跑完蓝牙僵尸 hci0 的全流程
#
# 不带目标时默认连 YARBO@37.38.39.8（默认有线 IP 地址），所以常态操作就是:
#   ./deploy-remote.sh --install --reboot
#
# 用法:
#   ./deploy-remote.sh                            # 诊断 + 修当次（安全模式，不写文件）
#   ./deploy-remote.sh --install                  # 再加开机自愈（默认顺带屏蔽 rtl_btusb）
#   ./deploy-remote.sh --install --reboot         # 装完重启并验证持久化生效
#   ./deploy-remote.sh --diagnose                 # 纯只读
#   ./deploy-remote.sh --uninstall                # 回滚持久化改动
#   ./deploy-remote.sh --no-blacklist --install   # 不屏蔽厂商模块
#
#   换一台设备时把 user@host 作为第一个参数:
#   ./deploy-remote.sh YARBO@10.0.0.6 --install --reboot
#
# 只依赖系统自带 ssh / scp。密码交互输入，靠 ControlMaster 复用，整个流程只输一次。
# 脚本里不含任何凭据。
# ==============================================================================
set -u

DEFAULT_TARGET="YARBO@37.38.39.8"   # 默认有线 IP 地址

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$SELF_DIR/bt-dead-hci0.sh"
REMOTE_SCRIPT=/tmp/bt-dead-hci0.sh
BLACKLIST=rtl_btusb
DO_BLACKLIST=1
DO_INSTALL=0
DO_UNINSTALL=0
DO_REBOOT=0
MODE_ARG=""

usage() { sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; }

# 第一个参数若是 user@host 则作为目标，否则用默认目标（这样 --install 能直接跟在后面）
if [ $# -ge 1 ] && [ "${1#-}" = "$1" ]; then
  TARGET=$1; shift
else
  TARGET=$DEFAULT_TARGET
fi
# 容忍从文档里连占位符尖括号一起粘过来，例如 YARBO@<10.0.0.5>
TARGET=${TARGET//[<>]/}
case "$TARGET" in
  *@?*) ;;
  *) echo "目标格式应为 user@host，例如 YARBO@10.0.0.5（不要带尖括号）" >&2; exit 2 ;;
esac

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

rrun()  { ssh -t "${SSH_OPTS[@]}" "$TARGET" "$@"; }
rread() { ssh "${SSH_OPTS[@]}" "$TARGET" "$@"; }
die()   { echo "   [xx] $*" >&2; echo "   [xx] 已中止，未做任何改动，未重启" >&2; exit 1; }

# 远端提权形态：能免密就用非交互（cron / 无 tty 也能跑），否则退回交互式 ssh -t
SUDO_MODE=unknown
rsudo() {
  if [ "$SUDO_MODE" = n ]; then rread "sudo -n $*"; else rrun "sudo $*"; fi
}

echo "== [1] 确认目标身份（防止默认 IP 上其实是另一台机器）=="
rrun 'printf "   host=%s  kernel=%s\n" "$(hostname)" "$(uname -r)"
      hciconfig hci0 2>/dev/null | head -2 | sed "s/^/   /"
      if [ -f /etc/systemd/system/bt-dead-hci0-fix.service ]; then echo "   自愈服务: 已安装"; else echo "   自愈服务: 未安装"; fi' \
  || die "连不上 $TARGET"

echo "== [2] 提权预检（密码不对会在这里暴露，不会等到重启后才发现）=="
if rread 'sudo -n true' >/dev/null 2>&1; then
  SUDO_MODE=n; echo "   远端 sudo: 免密（非交互）"
else
  SUDO_MODE=t; echo "   远端 sudo: 需要密码（交互式，会提示一次）"
  rrun 'sudo -v' || die "sudo 校验失败：密码错误，或当前 shell 无终端无法提示密码（请在 Terminal 里运行，或给该账号配免密 sudo）"
fi
echo "   通过"

echo "== [3] 上传脚本 =="
scp -q "${SSH_OPTS[@]}" "$SCRIPT" "$TARGET:$REMOTE_SCRIPT" || die "上传失败"
echo "   ok -> $REMOTE_SCRIPT"

if [ "$DO_UNINSTALL" = 1 ]; then
  echo "== [4] 回滚持久化改动 =="
  rsudo "bash $REMOTE_SCRIPT --uninstall" || die "回滚失败"
  exit 0
fi

echo "== [4] 诊断 + 必要时修复（安全模式：不写文件 / 不重启 / 不碰固件）=="
rsudo "bash $REMOTE_SCRIPT ${MODE_ARG}" || echo "   [!!] 诊断步骤返回非 0，继续但请留意上面的输出"

if [ "$DO_INSTALL" = 1 ]; then
  echo "== [5] 安装开机自愈 =="
  if [ "$DO_BLACKLIST" = 1 ]; then
    echo "   同时屏蔽外部模块: $BLACKLIST（不想要就加 --no-blacklist）"
    rsudo "bash $REMOTE_SCRIPT --install --blacklist $BLACKLIST" || die "安装命令执行失败"
  else
    rsudo "bash $REMOTE_SCRIPT --install" || die "安装命令执行失败"
  fi
  # 断言：unit 必须真的存在且 enabled，否则绝不往下走（尤其不重启）
  rread 'test -f /etc/systemd/system/bt-dead-hci0-fix.service && test "$(systemctl is-enabled bt-dead-hci0-fix.service 2>/dev/null)" = enabled' \
    || die "安装校验未通过：unit 不存在或未启用"
  echo "   [ok] 安装校验通过（unit 存在且 enabled）"

  echo "== [6] 立即修一次当前这台（不用等重启）=="
  rsudo 'systemctl start bt-dead-hci0-fix.service; sleep 8; hciconfig hci0 2>/dev/null | head -3 | sed "s/^/   /"' \
    || echo "   [!!] 立即修复步骤返回非 0，看上面的适配器状态"
else
  echo "== [5] 跳过持久化（要装开机自愈加 --install）=="
fi

if [ "$DO_REBOOT" = 1 ]; then
  echo "== [7] 重启并验证持久化 =="
  rsudo "systemctl reboot" >/dev/null 2>&1 || true
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
  rrun 'echo "--- 时序 ---"; dmesg | grep -E "VFS: Mounted root" | head -1; dmesg | grep -E "hci[0-9]+: RTL: (loading|fw version)" | head -3; echo "--- 自愈日志 ---"; { cat /var/log/bt-dead-hci0.log 2>/dev/null || true; } | tail -3; echo "--- 适配器 ---"; hciconfig 2>/dev/null | head -6; echo "--- 驱动 ---"; lsusb -t 2>/dev/null | grep -i wireless; lsmod | grep -E "rtl_btusb|rtk_btusb" || echo "   无厂商模块"'
fi

echo
echo "== 完成 =="
echo "   判定表: OK=转查应用层 | ZOMBIE+RACE=装 --install | ZOMBIE+MISSING=补固件"
echo "   下次复诊: ./deploy-remote.sh --diagnose        (换设备: ./deploy-remote.sh YARBO@10.0.0.6 --diagnose)"
