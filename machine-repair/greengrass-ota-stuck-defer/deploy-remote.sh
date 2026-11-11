#!/usr/bin/env bash
# ==============================================================================
# deploy-remote.sh — 给一台设备跑完 Greengrass "OTA 永久 defer" 的诊断/放行/验证
#
# 不带目标时默认连 YARBO@192.168.0.16（实验室台架 IP），所以常态操作就是:
#   ./deploy-remote.sh                      # 只读诊断
#   ./deploy-remote.sh --allow              # 放行 + 自动验证到部署收尾
#
# 用法:
#   ./deploy-remote.sh                                    # 诊断 + 判定(只读)
#   ./deploy-remote.sh --allow                            # 放行卡住的部署并验证
#   ./deploy-remote.sh --allow --deployment-id <id>       # 指定部署
#   ./deploy-remote.sh --allow-force                      # DEPLOY_ALLOWED=999 强制放行
#   ./deploy-remote.sh --restore                          # 还原最近一次 DB 备份
#   ./deploy-remote.sh --no-verify                        # 放行后不等待验证
#
#   换一台设备时把 user@host 作为第一个参数:
#   ./deploy-remote.sh YARBO@10.0.0.6 --allow
#
# 只依赖系统自带 ssh / scp。密码交互输入，靠 ControlMaster 复用，整个流程只输一次。
# 脚本里不含任何凭据。
#
# 注意: --allow 之后设备会真的开始 OTA，过程中**会掉网/重启**（实测掉过 14 分钟），
#       验证阶段能容忍掉网，会一直轮询到设备回来（默认最多 20 分钟）。
# ==============================================================================
set -u

DEFAULT_TARGET="YARBO@192.168.0.16"   # 默认实验室台架 IP；换产线/网段改这一行

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$SELF_DIR/ota-stuck-defer.sh"
REMOTE_SCRIPT=/tmp/ota-stuck-defer.sh
DO_ALLOW=0
DO_ALLOW_FORCE=0
DO_RESTORE=0
DO_VERIFY=1
DEPLOY_ID=""
VERIFY_MAX_SEC=1200

usage() { sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'; }

# 第一个参数若是 user@host 则作为目标，否则用默认目标（这样 --allow 能直接跟在后面）
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

while [ $# -gt 0 ]; do
  case "$1" in
    --allow)             DO_ALLOW=1 ;;
    --allow-force)       DO_ALLOW_FORCE=1 ;;
    --restore)           DO_RESTORE=1 ;;
    --no-verify)         DO_VERIFY=0 ;;
    --deployment-id)     shift; [ $# -gt 0 ] && DEPLOY_ID=$1 ;;
    --deployment-id=*)   DEPLOY_ID=${1#*=} ;;
    --help|-h)           usage; exit 0 ;;
    *)                   echo "未知参数: $1" >&2; exit 2 ;;
  esac
  shift
done

[ -f "$SCRIPT" ] || { echo "找不到 $SCRIPT" >&2; exit 1; }

HOST=${TARGET#*@}
CTL=/tmp/.deploy-ota-$$-%r@%h:%p
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ControlMaster=auto
          -o "ControlPath=$CTL" -o ControlPersist=10m -o ConnectTimeout=15)
cleanup() { ssh "${SSH_OPTS[@]}" -O exit "$TARGET" >/dev/null 2>&1 || true; }
trap cleanup EXIT

rrun()  { ssh -t "${SSH_OPTS[@]}" "$TARGET" "$@"; }
rread() { ssh "${SSH_OPTS[@]}" "$TARGET" "$@"; }
die()   { echo "   [xx] $*" >&2; echo "   [xx] 已中止，未做任何改动" >&2; exit 1; }

SUDO_MODE=unknown
rsudo() {
  if [ "$SUDO_MODE" = n ]; then rread "sudo -n $*"; else rrun "sudo $*"; fi
}
# 紧凑现状：单行机器可读，由远端脚本 --snapshot 产出（含版本/ongoing/defer 计数/uptime）
snapshot() { rsudo "bash $REMOTE_SCRIPT --snapshot" 2>/dev/null; }

echo "== [1] 确认目标身份（防止默认 IP 上其实是另一台机器）=="
rrun 'printf "   host=%s  kernel=%s\n" "$(hostname)" "$(uname -r)"; uptime | sed "s/^/   /"' \
  || die "连不上 $TARGET"
HP=$(rread 'hostname' 2>/dev/null || true)
[ "${HP:-}" = "YARBO" ] || echo "   [!!] hostname 是 '${HP:-?}'，不是预期的 YARBO —— 先确认这是目标设备"

echo "== [2] 提权预检（密码不对会在这里暴露，不会等到放行后才发现）=="
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

CUR=$(snapshot || true)
[ -n "${CUR:-}" ] || die "读取 Greengrass 状态失败（远端脚本 --snapshot 无输出）"
echo "   当前: $CUR"

if [ "$DO_RESTORE" = 1 ]; then
  echo "== [4] 从备份还原 ota DB =="
  rsudo "bash $REMOTE_SCRIPT --restore" || die "还原失败"
  echo "   现在: $(snapshot || true)"
  exit 0
fi

echo "== [4] 诊断（只读：不写文件 / 不改数据库 / 不重启）=="
rsudo "bash $REMOTE_SCRIPT --diagnose" || echo "   [!!] 诊断返回非 0，继续但请留意上面的输出"

if [ "$DO_ALLOW" = 1 ]; then
  echo "== [5] 放行（会自动备份 ota DB）=="
  if [ -n "$DEPLOY_ID" ]; then
    echo "   指定部署: $DEPLOY_ID"
    rsudo "bash $REMOTE_SCRIPT --allow --deployment-id $DEPLOY_ID" || die "放行失败"
  else
    echo "   部署 ID 由脚本从 ota 表自动挑选（action_ 为空的那条）"
    rsudo "bash $REMOTE_SCRIPT --allow" || die "放行失败"
  fi
elif [ "$DO_ALLOW_FORCE" = 1 ]; then
  echo "== [5] 强制放行（DEPLOY_ALLOWED=999）=="
  rsudo "bash $REMOTE_SCRIPT --allow-force" || die "强制放行失败"
else
  echo "== [5] 跳过放行（要放行加 --allow / --allow-force）=="
  exit 0
fi

[ "$DO_VERIFY" = 1 ] || { echo "== [6] 跳过验证（--no-verify）=="; exit 0; }

echo "== [6] 验证（设备会掉网/重启，这里一直等到部署收尾，最多 $((VERIFY_MAX_SEC/60)) 分钟）=="
elapsed=0; online=0; last=""; done_ok=0
while [ "$elapsed" -lt "$VERIFY_MAX_SEC" ]; do
  if cur=$(snapshot 2>/dev/null) && [ -n "$cur" ]; then
    [ "$online" = 0 ] && { echo "   [ok] 设备在线（${elapsed}s）"; online=1; }
    [ "$cur" != "$last" ] && { echo "   ${elapsed}s  $cur"; last=$cur; }
    case "$cur" in
      *"ongoing=none"*)
        # ongoing 清空 = 这次部署收尾（成功则 prev_success 指向本次部署 id）
        echo "   [ok] ongoing 已清空，部署收尾（${elapsed}s）"
        done_ok=1; break ;;
    esac
  else
    if [ "$online" = 1 ]; then
      echo "   [!!] ${elapsed}s 设备掉网（OTA 重启中），继续等..."
      online=0
    fi
  fi
  sleep 15; elapsed=$((elapsed+15))
done

echo
if [ "$done_ok" = 1 ]; then
  echo "== 完成：部署收尾 =="
  echo "   $last"
  case "$last" in
    *"nucleus=2.17"*|*"nucleus=2.1"*) echo "   Nucleus 已升级（看上面 nucleus= 值）" ;;
  esac
  echo "   再确认一次版本: ./deploy-remote.sh"
else
  echo "== [!!] ${VERIFY_MAX_SEC}s 内未收敛，人工确认设备状态 =="
  echo "   设备可能已重启但未回网；恢复后跑 ./deploy-remote.sh 复诊"
fi
echo
echo "   一键复诊: ./deploy-remote.sh                 （换设备: ./deploy-remote.sh YARBO@10.0.0.6）"
echo "   回滚 DB : ./deploy-remote.sh --restore"
