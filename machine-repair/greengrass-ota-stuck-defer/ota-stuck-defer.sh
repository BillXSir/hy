#!/usr/bin/env bash
# ==============================================================================
# ota-stuck-defer.sh — Greengrass 部署"永久 defer"死锁：诊断 / 放行 / 回滚
#
# 典型症状: AWS IoT job 已派发、artifact 已下载完、greengrass.log 里
#           "service-update-deferred. deferred for N millis" 每十几秒刷一次，
#           但组件版本永远不更新，job 一直 IN_PROGRESS。
#
# 真实含义: 部署没问题、下载没问题，是**某个组件在用 deferComponentUpdate
#           无限推迟**这次部署。Yarbo 栈上通常是 ota_progress 在等云端下发
#           set_ota_config（更新动作），而那条消息没来，于是 action_ 为空 →
#           "不允许更新" → 每 10s defer 一次，永不放弃。
#
# ---- 安全边界(重要) ----------------------------------------------------------
#  * 默认模式(auto/diagnose/snapshot) 纯只读：不写任何文件、不改数据库、不重启。
#  * --allow 会写一次 sqlite（把 action_ 置为 immediate），**写前自动备份**，
#    可用 --restore 一键还原。放行后部署会真的开始执行（可能含整机重启），
#    这是本脚本唯一"会动到设备"的动作。
#  * --allow-force 写 /home/firefly/.ros/DEPLOY_ALLOWED=999，绕过 DB 判定，
#    影响面更大，默认不做。
#  * 不开机自愈、不装 systemd 服务 —— 这个问题要修的是云端/组件代码，
#    在设备上做持久化只会掩盖问题。
#
# ---- 用法 --------------------------------------------------------------------
#   sudo ota-stuck-defer.sh                  # 无脑模式: 诊断→判定→给结论(只读)
#   sudo ota-stuck-defer.sh --diagnose       # 同上(显式只读)
#   sudo ota-stuck-defer.sh --allow          # 放行当前卡住的部署(改库,自动备份)
#   sudo ota-stuck-defer.sh --allow --deployment-id <id>   # 指定部署
#   sudo ota-stuck-defer.sh --allow-force    # 写 DEPLOY_ALLOWED=999 强制放行
#   sudo ota-stuck-defer.sh --restore        # 从最近一次备份还原 DB
#   sudo ota-stuck-defer.sh --watch          # 放行后跟随日志验证(前台 tail)
#   sudo ota-stuck-defer.sh --snapshot       # 单行机器可读现状(给 deploy-remote 用)
#   附加: --quiet(精简输出)  --no-color  --mqtt(只打印该发的 MQTT 报文)
# ==============================================================================
set -u

BACKUP_DIR=${BACKUP_DIR:-/var/backups/ota-stuck-defer}
DEFER_WINDOW_MIN=5      # 判定"defer 风暴"的时间窗口(分钟)
DEFER_STORM_COUNT=6     # 窗口内出现次数达到这个值就算风暴

MODE=auto
QUIET=0
COLOR=1
DO_MQTT=0
TARGET_DEPLOYMENT=""

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --diagnose)        MODE=diagnose ;;
        --allow)           MODE=allow ;;
        --allow-force)     MODE=allow_force ;;
        --restore)         MODE=restore ;;
        --watch)           MODE=watch ;;
        --snapshot)        MODE=snapshot ;;
        --mqtt)            DO_MQTT=1 ;;
        --deployment-id)   shift; [ $# -gt 0 ] && TARGET_DEPLOYMENT=$1 ;;
        --deployment-id=*) TARGET_DEPLOYMENT=${1#*=} ;;
        --quiet|-q)        QUIET=1 ;;
        --no-color)        COLOR=0 ;;
        --help|-h)         usage; exit 0 ;;
        *)                 echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

[ "$QUIET" = 1 ] && COLOR=0
if [ "$COLOR" = 1 ] && [ -t 1 ]; then
    R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[36m'; N=$'\033[0m'
else
    R=; G=; Y=; B=; N=
fi
say()   { printf '%s\n' "$*"; }
head1() { [ "$QUIET" = 1 ] && return 0; say ""; say "${B}== $* ==${N}"; }
# 时间戳用显式格式串，BSD/GNU date 都认（date -Is 在 BSD 上不通用）
now_ts() { date +%Y-%m-%dT%H:%M:%S%z; }
# 文件大小：GNU stat 与 BSD stat 参数不同
fsize()  { stat -c %s "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null || echo '?'; }
# 文件 mtime（ISO）
fmtime() {
    local v=""
    v=$(stat -c %y "$1" 2>/dev/null) || true
    [ -n "$v" ] || v=$(stat -f %Sm -t %Y-%m-%dT%H:%M:%S "$1" 2>/dev/null) || true
    [ -n "$v" ] || v='?'
    printf '%s' "${v:0:19}"
}
ok()    { say "$(now_ts) [OK] $*"; }
warn()  { say "$(now_ts) [!!] $*"; }
bad()   { say "$(now_ts) [XX] $*"; }
info()  { [ "$QUIET" = 1 ] && return 0; say "  [--] $*"; }

[ "$(id -u)" = 0 ] || { echo "必须以 root 运行 (sudo)" >&2; exit 1; }

# ------------------------------------------------------------------ 定位
# 老装机把 /greengrass 做成 /userdata/greengrass 的软链，两者等价。
# GG_ROOT 可覆盖本目录(自测 fixture / 非标准安装路径)，其余路径同理可用环境变量覆盖。
ROOT=""
for c in "${GG_ROOT:-}" /userdata/greengrass/v2 /greengrass/v2; do
    [ -n "$c" ] && [ -d "$c" ] && { ROOT=$(readlink -f "$c"); break; }
done
[ -n "$ROOT" ] || { bad "找不到 Greengrass 根目录(/userdata/greengrass/v2)"; exit 1; }

GG_LOG=$ROOT/logs/greengrass.log
DEPLOY_DIR=$ROOT/deployments
ONGOING=$DEPLOY_DIR/ongoing
CFG=$ROOT/config/effectiveConfig.yaml
OTA_LOG=$ROOT/logs/ota_progress.log
OTA_DB=${OTA_DB:-/userdata/updates_db/updates.db}
ALLOW_FILE=${ALLOW_FILE:-/home/firefly/.ros/DEPLOY_ALLOWED}
DENY_FILE=${DENY_FILE:-/home/firefly/.ros/green_grass_update_deny}
CAM_STATE=${CAM_STATE:-/home/firefly/.ros/ota_update_state}

have() { command -v "$1" >/dev/null 2>&1; }

# 从 effectiveConfig.yaml 读某个组件的 version（别用 grep 硬啃缩进，这里用 python 稳）
cfg_ver() {
    python3 - "$CFG" "$1" <<'PY' 2>/dev/null
import re, sys
want, cur = sys.argv[2], None
for line in open(sys.argv[1]):
    m = re.match(r"^  ([A-Za-z0-9_.-]+):\s*$", line)
    if m:
        cur = m.group(1); continue
    if cur == want and re.match(r"^    version: ", line):
        print(line.split(":", 1)[1].strip().strip('"')); break
PY
}

# 只读查 ota sqlite。设备上不一定有 sqlite3 二进制，但一定有 python3
# (ota_progress 自己就是 python 写的)，所以优先 python + mode=ro
sql_q() {
    if have python3; then
        python3 - "$OTA_DB" "$1" <<'PY'
import sqlite3, sys
db, q = sys.argv[1], sys.argv[2]
try:
    cur = sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=15).cursor()
    cur.execute(q)
    for row in cur.fetchall():
        print("|".join("" if v is None else str(v) for v in row))
except Exception as e:
    sys.stderr.write("sqlite error: %s\n" % e); sys.exit(1)
PY
    elif have sqlite3; then
        sqlite3 -noheader -separator '|' "$OTA_DB" "$1"
    else
        return 1
    fi
}

cutoff_iso() { date -u -d "-${1} minutes" +%Y-%m-%dT%H:%M:%S 2>/dev/null \
               || date -u -v-"${1}"M +%Y-%m-%dT%H:%M:%S; }

# 统计窗口内的 defer 次数（当前日志 + 最近两个轮转文件，按 ISO 时间戳前缀比较）
defer_count() {
    local cut f total=0 n
    cut=$(cutoff_iso "$DEFER_WINDOW_MIN")
    for f in "$GG_LOG" $(ls -1t "$ROOT"/logs/greengrass_*.log 2>/dev/null | head -2); do
        [ -f "$f" ] || continue
        n=$(awk -v cut="$cut" '
            /service-update-deferred/ { ts = substr($0, 1, 19); if (ts >= cut) c++ }
            END { print c + 0 }' "$f")
        total=$((total + n))
    done
    printf '%s' "$total"
}

# ------------------------------------------------------------------ snapshot
if [ "$MODE" = snapshot ]; then
    og=none;   [ -e "$ONGOING" ] && og=$(basename "$(readlink -f "$ONGOING")")
    ps=none;   [ -e "$DEPLOY_DIR/previous-success" ] && ps=$(basename "$(readlink -f "$DEPLOY_DIR/previous-success")")
    st=$(grep -o "DeploymentStatus=[A-Z_]*" "$GG_LOG" 2>/dev/null | tail -1 | cut -d= -f2)
    tot=$(grep -c "service-update-deferred" "$GG_LOG" 2>/dev/null || echo 0)
    printf 'nucleus=%s yarbo=%s ongoing=%s prev_success=%s defer_win=%s defer_total=%s last_status=%s up=%ss\n' \
        "$(cfg_ver aws.greengrass.Nucleus)" "$(cfg_ver yarbo)" "$og" "$ps" \
        "$(defer_count)" "$tot" "${st:-?}" "$(cut -d. -f1 /proc/uptime 2>/dev/null || echo '?')"
    exit 0
fi

# ------------------------------------------------------------------ 采集
head1 "环境"
say "  greengrass root : $ROOT"
say "  nucleus version : $(cfg_ver aws.greengrass.Nucleus)"
say "  yarbo version   : $(cfg_ver yarbo)"
say "  system uptime   : $(uptime | sed 's/^ *//')"
if [ -f "$OTA_DB" ]; then
    say "  ota db          : $OTA_DB ($(fsize "$OTA_DB") bytes)"
else
    say "  ota db          : ${Y}缺失${N} ($OTA_DB) —— 不是 Yarbo 栈或路径不同，本方案不适用"
fi

# ---- 进行中的部署
head1 "部署状态"
HAS_ONGOING=0
DEPLOY_ID=""
if [ -e "$ONGOING" ]; then
    HAS_ONGOING=1
    DEPLOY_ID=$(basename "$(readlink -f "$ONGOING")")
    say "  ${Y}ongoing${N} 存在 -> $DEPLOY_ID"
    if [ -f "$ONGOING/deployment_metadata.json" ]; then
        info "ongoing 部署文档 mtime: $(fmtime "$ONGOING/deployment_metadata.json")"
        say ""
        say "  目标版本 vs 当前版本差异:"
        python3 - "$ONGOING/deployment_metadata.json" "$CFG" <<'PY'
import json, re, sys
meta = json.load(open(sys.argv[1]))
doc  = meta.get("deploymentDocumentObj", {})
pkgs = {p.get("Name"): p.get("ResolvedVersion") for p in doc.get("Packages", [])}
cur, name = {}, None
for line in open(sys.argv[2]):
    m = re.match(r"^  ([A-Za-z0-9_.-]+):\s*$", line)
    if m:
        name = m.group(1); continue
    if name and re.match(r"^    version: ", line):
        cur[name] = line.split(":", 1)[1].strip().strip('"')
diff = [(k, v, cur.get(k, "<未安装>")) for k, v in pkgs.items() if cur.get(k) != v]
if not diff:
    print("    (无差异 —— 目标已达成，卡的是收尾阶段)")
for k, want, got in sorted(diff):
    print("    %-34s %-14s <- 当前 %s" % (k, want, got))
PY
    fi
    [ -f "$ONGOING/bootstrap_task.json" ] && \
        info "bootstrap_task.json 已生成 —— Nucleus 升级走的是'重启后续跑'路径"
else
    say "  无 ongoing 部署"
    [ -e "$DEPLOY_DIR/previous-success" ] && \
        say "  previous-success -> $(basename "$(readlink -f "$DEPLOY_DIR/previous-success")")"
fi

# ---- defer 风暴
head1 "defer 风暴检测（最近 ${DEFER_WINDOW_MIN} 分钟）"
DEFER_COUNT=$(defer_count)
DEFER_MS=$(grep -o "deferred for [0-9]* millis" "$GG_LOG" 2>/dev/null | tail -1 | grep -o "[0-9]*")
LAST_DEFER=$(grep "service-update-deferred" "$GG_LOG" 2>/dev/null | tail -1 \
             | sed 's/.*UpdateSystemPolicyService: //; s/\. {.*//')
if [ "$DEFER_COUNT" -ge "$DEFER_STORM_COUNT" ]; then
    bad "defer 风暴: ${DEFER_COUNT} 次 / ${DEFER_WINDOW_MIN} 分钟 (recheck=${DEFER_MS:-?}ms)"
else
    ok "未见 defer 风暴 (${DEFER_COUNT} 次 / ${DEFER_WINDOW_MIN} 分钟)"
fi
[ -n "${LAST_DEFER:-}" ] && info "最后一条: $LAST_DEFER"

# ---- 门禁链
head1 "门禁判定链（Yarbo 栈 ota_progress）"
DEFER_REASON=""
if [ -f "$ALLOW_FILE" ]; then
    AC=$(tr -d ' \r\n' < "$ALLOW_FILE")
    case "$AC" in
        999)                 say "  DEPLOY_ALLOWED = ${G}999${N} → 强制放行，绕过 DB 判定" ;;
        1|2|3|4|9|10|11|12)  say "  DEPLOY_ALLOWED = ${G}$AC${N} → 允许内容，延迟窗口未拦截" ;;
        "")                  say "  DEPLOY_ALLOWED = ${Y}(空)${N} → 空内容算非允许内容，延迟部署生效" ;;
        *)                   say "  DEPLOY_ALLOWED = ${R}$AC${N} → 非允许内容，延迟部署生效（会拦）" ;;
    esac
else
    say "  DEPLOY_ALLOWED : ${Y}不存在${N} → 按允许处理（不会拦）"
fi
for f in "$DENY_FILE" "$CAM_STATE"; do
    if [ -e "$f" ]; then
        say "  ${R}$(basename "$f") 存在${N} → 直接延迟部署生效"
        DEFER_REASON="gate-file"
    fi
done

PENDING_ROWS=""
if [ -f "$OTA_DB" ]; then
    PENDING_ROWS=$(sql_q "SELECT id,deployment_id,action_,update_version,status FROM ota WHERE status='WAITING_FOR_UPDATE' ORDER BY id DESC LIMIT 5" 2>/dev/null || true)
    if [ -n "$PENDING_ROWS" ]; then
        say ""
        say "  ota 表里 WAITING_FOR_UPDATE 的记录 (id|deployment_id|action_|update_version|status):"
        printf '%s\n' "$PENDING_ROWS" | sed 's/^/    /'
        EMPTY_ACTION=$(printf '%s\n' "$PENDING_ROWS" | awk -F'|' '$3=="" {print $2}' | head -1)
        if [ -n "$EMPTY_ACTION" ]; then
            bad "action_ 为空 -> ota_progress 每次都走 \"No action found in database\" -> return 0 (不允许更新) -> defer"
            [ "$DEFER_REASON" = "gate-file" ] || DEFER_REASON="empty-action"
            [ -z "$TARGET_DEPLOYMENT" ] && TARGET_DEPLOYMENT=$EMPTY_ACTION
        else
            info "action_ 已设置 —— 下一轮 PreComponentUpdate（<=12s）就会 acknowledge；若仍在 defer 说明卡在别处"
        fi
    else
        ok "ota 表里没有 WAITING_FOR_UPDATE 记录"
    fi
fi

# ---- 云端是否发过更新动作
if [ -f "$OTA_LOG" ]; then
    head1 "云端是否下发过 set_ota_config"
    GOT=$(grep -c "Processing action" "$OTA_LOG" 2>/dev/null || true)
    SUB=$(grep -c "Attempting to subscribe to topic: .*set_ota_config" "$OTA_LOG" 2>/dev/null || true)
    say "  订阅 set_ota_config      : ${SUB:-0} 次（订阅本身是好的）"
    say "  真正收到更新动作(state)  : ${GOT:-0} 次"
    if [ "${GOT:-0}" = 0 ]; then
        bad "从未收到过更新动作 —— 云端/App 侧漏发 set_ota_config，这是本次卡死的直接触发点"
    fi
fi

# ------------------------------------------------------------------ 判定
head1 "判定"
if [ "$DEFER_COUNT" -ge "$DEFER_STORM_COUNT" ] && [ "$HAS_ONGOING" = 1 ]; then
    if [ "$DEFER_REASON" = "gate-file" ]; then VERDICT=GATED; else VERDICT=DEFER_DEADLOCK; fi
elif [ "$HAS_ONGOING" = 1 ]; then
    VERDICT=IN_PROGRESS
else
    VERDICT=OK
fi

case "$VERDICT" in
  OK)
    ok "verdict=OK 没有卡住的部署，也没有 defer 风暴"
    say "   如果云图上仍显示没更新，问题不在本机：先确认 IoT job 是否真的派到了这台 thing" ;;
  IN_PROGRESS)
    ok "verdict=IN_PROGRESS 有进行中的部署，但没看到 defer 风暴"
    say "   部署正在正常跑：等它完成，用 --watch 跟日志；长时间无进展再回来跑一次" ;;
  DEFER_DEADLOCK)
    bad "verdict=DEFER_DEADLOCK 部署被组件无限 defer，不会自己好，也不会超时回滚"
    say ""
    say "   正规做法（云端/App 侧，优先）: 往下面这个 topic 下发更新动作"
    say "     topic   : snowbot/<SN>/app/set_ota_config"
    say "     payload : {\"deployment_id\":\"${TARGET_DEPLOYMENT:-<id>}\",\"state\":1,\"timezone\":0}"
    say "               state 1=立即 / 2=稍后(仅 02:00-05:00 放行) / 3=下次"
    if [ -n "$TARGET_DEPLOYMENT" ]; then
        say ""
        say "   设备侧放行（会真的开始执行部署，可能含整机重启）:"
        say "     sudo $0 --allow --deployment-id $TARGET_DEPLOYMENT"
        say "     sudo $0 --watch"
        say "     回滚: sudo $0 --restore"
    fi ;;
  GATED)
    bad "verdict=GATED 被门禁文件挡住（不是 action_ 的问题）"
    say "   先确认这几个文件是否该存在，处理掉才谈放行:"
    [ -e "$DENY_FILE" ] && say "     $DENY_FILE   <-- 更新禁止标记"
    [ -e "$CAM_STATE" ] && say "     $CAM_STATE   <-- 摄像头正在更新" ;;
esac

if [ "$DO_MQTT" = 1 ] && [ -n "$TARGET_DEPLOYMENT" ]; then
    head1 "该发的 MQTT 报文"
    SN=$(python3 - "$CFG" <<'PY' 2>/dev/null || echo "<SN>"
import re, sys
for line in open(sys.argv[1]):
    m = re.search(r'thingName:\s*"?([A-Za-z0-9_-]+)"?', line)
    if m:
        print(m.group(1)); break
PY
)
    say "  topic   : snowbot/$SN/app/set_ota_config"
    say "  payload : {\"deployment_id\":\"$TARGET_DEPLOYMENT\",\"state\":1,\"timezone\":0}"
fi

# ------------------------------------------------------------------ 动作
backup_db() {
    mkdir -p "$BACKUP_DIR" || return 1
    local dst
    dst=$BACKUP_DIR/updates.db.$(date +%Y%m%d_%H%M%S)
    cp -a "$OTA_DB" "$dst" || return 1
    ok "已备份 DB -> $dst" >&2
    printf '%s' "$dst"
}

case "$MODE" in
  auto|diagnose) : ;;

  allow)
    [ -f "$OTA_DB" ] || { bad "$OTA_DB 不存在，无从放行"; exit 1; }
    if [ -z "$TARGET_DEPLOYMENT" ]; then
        bad "不知道该放行哪个部署；先跑一次 --diagnose，或显式 --deployment-id <id>"
        exit 1
    fi
    head1 "放行部署 $TARGET_DEPLOYMENT"
    BK=$(backup_db) || { bad "备份失败，已中止，未做任何改动"; exit 1; }
    if have python3; then
        python3 - "$OTA_DB" "$TARGET_DEPLOYMENT" <<'PY'
import sqlite3, sys
db, did = sys.argv[1], sys.argv[2]
c = sqlite3.connect(db, timeout=15)
cur = c.cursor()
cur.execute("UPDATE ota SET action_='immediate', updated_date=datetime('now')"
            " WHERE deployment_id=?", (did,))
print("rows updated:", cur.rowcount)
c.commit(); c.close()
PY
    else
        sqlite3 "$OTA_DB" "UPDATE ota SET action_='immediate', updated_date=datetime('now') WHERE deployment_id='$TARGET_DEPLOYMENT';" \
            || { bad "写库失败"; exit 1; }
    fi
    say "  现在: $(sql_q "SELECT id,deployment_id,action_,status FROM ota WHERE deployment_id='$TARGET_DEPLOYMENT'" | tr '\n' ' ')"
    ok "已放行。下一次 PreComponentUpdate 轮次（<=12s）就会 acknowledge，编排随即开始"
    say ""
    say "  回滚:  sudo $0 --restore            （还原最近一次备份 ${BK}）"
    say "  验证:  sudo $0 --watch              （跟日志看它是否真的开始升级）" ;;

  allow_force)
    head1 "强制放行（DEPLOY_ALLOWED=999）"
    mkdir -p "$(dirname "$ALLOW_FILE")" "$BACKUP_DIR"
    [ -f "$ALLOW_FILE" ] && cp -a "$ALLOW_FILE" "$BACKUP_DIR/DEPLOY_ALLOWED.$(date +%Y%m%d_%H%M%S)"
    printf '999' > "$ALLOW_FILE" || { bad "写入 $ALLOW_FILE 失败"; exit 1; }
    ok "已写入 $ALLOW_FILE = 999（绕过 DB 判定；deny/camera 门禁文件仍然有效）"
    say "  回滚:  printf '1' > $ALLOW_FILE   （或从 $BACKUP_DIR 还原）" ;;

  restore)
    head1 "从备份还原 DB"
    LAST=$(ls -1t "$BACKUP_DIR"/updates.db.* 2>/dev/null | head -1)
    [ -n "$LAST" ] || { bad "$BACKUP_DIR 下没有备份"; exit 1; }
    cp -a "$LAST" "$OTA_DB" && ok "已还原 $OTA_DB <- $LAST" ;;

  watch)
    head1 "跟随日志（Ctrl-C 退出）"
    say "  关注关键词: update immediate / Acknowledged / Completed all bootstrap tasks / Launch Nucleus / SUCCEEDED"
    say ""
    tail -F "$GG_LOG" "$OTA_LOG" 2>/dev/null \
      | grep --line-buffered -E "service-update-deferred|Acknowledged|bootstrap|Launch Nucleus|Stored deployment status|Progress |Run script exited" ;;
esac

exit 0
