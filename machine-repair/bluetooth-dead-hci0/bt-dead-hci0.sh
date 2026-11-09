#!/usr/bin/env bash
# ==============================================================================
# bt-dead-hci0.sh — 蓝牙"僵尸 hci0"诊断 / 修复 / 持久化
#
# 典型症状: hciconfig 里有 hci0，但 DOWN、BD Address 全零、Features 全零
# 真实含义: 控制器从未初始化成功(绝大多数是固件没加载)，不是射频/硬件坏
#
# ---- 安全边界(重要) ----------------------------------------------------------
#  * 默认模式(auto/diagnose/fix) 只做可逆的运行时操作：不写任何文件、不重启、
#    不碰固件文件、不动内核配置。
#  * 任何持久化改动都必须显式 --install，且改动前自动备份到
#    /var/backups/bt-dead-hci0/<时间戳>/
#  * 唯一会卸载模块的动作(修复阶梯 L2)只针对"当前正绑在故障设备上、且来自
#    /lib/modules 的外部模块"，卸载本身可逆，且不会重启系统。
#  * 固件文件缺失时只报告、不猜测、不下载 —— 交由人工决定固件来源。
#
# ---- 用法 --------------------------------------------------------------------
#   sudo bt-dead-hci0.sh                     # 无脑模式: 诊断→必要时修复→验证→出报告
#   sudo bt-dead-hci0.sh --diagnose          # 只读诊断
#   sudo bt-dead-hci0.sh --fix               # 只修当前这一次(运行时、可逆)
#   sudo bt-dead-hci0.sh --install           # 装开机自愈服务(持久化)
#   sudo bt-dead-hci0.sh --install --blacklist rtl_btusb   # 顺带屏蔽冲突模块
#   sudo bt-dead-hci0.sh --uninstall         # 回滚全部持久化改动
#   附加: --quiet(精简输出)  --no-color
# ==============================================================================
set -u

SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")
ZERO=00:00:00:00:00:00
BACKUP_ROOT=/var/backups/bt-dead-hci0
UNIT_NAME=bt-dead-hci0-fix.service
UNIT_PATH=/etc/systemd/system/$UNIT_NAME
INSTALLED_SCRIPT=/usr/local/sbin/bt-dead-hci0.sh
MAX_ATTEMPT=2

MODE=auto
QUIET=0
COLOR=1
BLACKLIST=()

usage() { sed -n '2,30p' "$SELF" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --diagnose)    MODE=diagnose ;;
        --fix)         MODE=fix ;;
        --install)     MODE=install ;;
        --uninstall)   MODE=uninstall ;;
        --quiet|-q)    QUIET=1 ;;
        --no-color)    COLOR=0 ;;
        --blacklist)   shift; [ $# -gt 0 ] && BLACKLIST+=("$1") ;;
        --blacklist=*) BLACKLIST+=("${1#*=}") ;;
        --help|-h)     usage; exit 0 ;;
        *)             echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

# quiet 模式用于开机自愈日志：只留动作与结论行，去掉大段清单，且不带颜色
[ "$QUIET" = 1 ] && COLOR=0
if [ "$COLOR" = 1 ] && [ -t 1 ]; then
    R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[36m'; N=$'\033[0m'
else
    R=; G=; Y=; B=; N=
fi
say()   { printf '%s\n' "$*"; }
head1() { [ "$QUIET" = 1 ] && return 0; say ""; say "${B}== $* ==${N}"; }
ok()    { say "$(date -Is) [OK] $*"; }
warn()  { say "$(date -Is) [!!] $*"; }
bad()   { say "$(date -Is) [XX] $*"; }
info()  { [ "$QUIET" = 1 ] && return 0; say "  [--] $*"; }

[ "$(id -u)" = 0 ] || { echo "必须以 root 运行 (sudo)" >&2; exit 1; }

# ------------------------------------------------------------------ 采集
bd_of() { hciconfig "$1" 2>/dev/null | awk '/BD Address/{print $3; exit}'; }
state_of() { hciconfig "$1" 2>/dev/null | sed -n 's/^[[:space:]]*\(UP RUNNING[^ ]*\|DOWN[^ ]*\).*/\1/p' | head -1; }
feat_zero() { hciconfig "$1" 2>/dev/null | grep -q 'Features: 0x00 0x00 0x00 0x00 0x00 0x00 0x00 0x00'; }

# 从 /sys/class/bluetooth/hciN/device 反查 USB 设备名(如 7-1.3)，平台设备返回失败
usb_dev_of() {
    local link base
    link=$(readlink -f "/sys/class/bluetooth/$1/device" 2>/dev/null) || return 1
    case "$link" in */usb*) ;; *) return 1 ;; esac
    base=$(basename "$link")
    case "$base" in *:*) echo "${base%%:*}" ;; *) return 1 ;; esac
}

# 当前绑在该 USB 设备上的驱动名(可能是外部模块)
driver_of() {
    local d f n
    for f in /sys/bus/usb/drivers/*/"$1":*; do
        [ -e "$f" ] || continue
        d=${f%/*}; n=$(basename "$d")
        case "$n" in usb|hub|usbfs) continue ;; esac
        echo "$n"; return 0
    done
    return 1
}

tstamp_of() { grep -oE '^\[[[:space:]]*[0-9]+\.[0-9]+\]' | tr -d '[] ' | head -1; }
fw_line()   { dmesg 2>/dev/null | grep -E "hci$1: .*loading .*\.bin" | tail -3; }

collect() {
    ADAPTERS=(); ZOMBIES=(); HEALTHY=(); NOUSB=()
    local h n a
    for h in /sys/class/bluetooth/hci*; do
        [ -e "$h" ] || continue
        n=$(basename "$h")
        # /sys/class/bluetooth/ 下同时有适配器(hci0)和远端连接(hci0:24)，只保留适配器
        case "$n" in *:*) continue ;; esac
        printf '%s' "$n" | grep -qE '^hci[0-9]+$' || continue
        ADAPTERS+=("$n")
        a=$(bd_of "$n")
        if [ -z "$a" ] || [ "$a" = "$ZERO" ]; then
            ZOMBIES+=("$n")
            usb_dev_of "$n" >/dev/null 2>&1 || NOUSB+=("$n")
        else
            HEALTHY+=("$n")
        fi
    done

    FW_PATHS=()
    local p
    for p in $(dmesg 2>/dev/null | grep -oE '(rtl_bt|rtlwifi|brcm|mediatek|intel)/[A-Za-z0-9_.-]+\.bin' | sort -u); do
        FW_PATHS+=("$p")
    done

    ROOT_T=$(dmesg 2>/dev/null | grep 'VFS: Mounted root' | tstamp_of)
    BT_T=$(dmesg 2>/dev/null | grep -E 'Bluetooth: hci[0-9]+: .*(examining|RTL: rom_version)' | head -1 | tstamp_of)
    NO_INITRAMFS=0
    grep -q 'skip_initramfs' /proc/cmdline 2>/dev/null && NO_INITRAMFS=1
    [ -z "$(ls -A /boot 2>/dev/null)" ] && NO_INITRAMFS=1
}

report_hardware() {
    head1 "硬件与驱动"
    info "内核: $(uname -r)   机型: $(uname -m)"
    local d i ifc found=0
    for d in /sys/bus/usb/devices/*/; do
        [ -f "$d/idVendor" ] || continue
        # 蓝牙控制器: 某个接口的 bInterfaceClass = e0 (Wireless), subclass 01 = RF
        for ifc in "$d"*:*/bInterfaceClass; do
            [ -f "$ifc" ] || continue
            if [ "$(cat "$ifc" 2>/dev/null)" = "e0" ]; then
                found=1
                info "USB 蓝牙: $(basename "$d")  $(cat "$d/idVendor"):$(cat "$d/idProduct")  $(cat "$d/product" 2>/dev/null)"
                break
            fi
        done
    done
    [ "$found" = 0 ] && warn "未在 USB 总线上发现蓝牙控制器(class e0)"
    local w
    for w in $(lsusb -t 2>/dev/null | grep -i wireless | grep -oE 'Driver=[^,]+' | sort -u); do
        info "USB 接口驱动: $w"
    done
    local mods
    mods=$(lsmod 2>/dev/null | awk 'NR>1 && ($1 ~ /btusb|blue|hci|btrtl/) {printf "%s ", $1}')
    if [ -n "$mods" ]; then
        info "已加载的蓝牙模块(仅外部模块): $mods"
    else
        info "已加载的蓝牙模块: 无 —— 驱动可能内建于内核(内建模块不会出现在 lsmod)"
    fi
}

report_adapters() {
    head1 "控制器状态"
    if [ "${#ADAPTERS[@]}" = 0 ]; then
        bad "系统里没有任何 hci 控制器"
        return
    fi
    local n a s verdict
    for n in "${ADAPTERS[@]}"; do
        a=$(bd_of "$n"); s=$(state_of "$n")
        if [ -z "$a" ] || [ "$a" = "$ZERO" ]; then
            verdict="${R}僵尸(固件/初始化未完成)${N}"
            feat_zero "$n" && verdict="$verdict + Features 全零"
        else
            verdict="${G}正常${N}"
        fi
        info "$n  BD=${a:-none}  状态=${s:-?}  => $verdict"
        if usb_dev_of "$n" >/dev/null 2>&1; then
            info "     USB 路径: $(usb_dev_of "$n")   驱动: $(driver_of "$(usb_dev_of "$n")" || echo 未绑定)"
        else
            info "     非 USB 控制器(平台/UART)，无法用 USB 重新枚举法修复"
        fi
    done
}

classify() {
    VERDICT=none
    if [ "${#ADAPTERS[@]}" = 0 ]; then
        VERDICT=NO_ADAPTER
    elif [ "${#ZOMBIES[@]}" -gt 0 ]; then
        VERDICT=ZOMBIE
    else
        VERDICT=OK
    fi

    FW_REASON=none
    if [ "$VERDICT" = ZOMBIE ]; then
        local missing=0 present=0 p
        for p in "${FW_PATHS[@]}"; do
            if [ -e "/lib/firmware/$p" ] || [ -e "/usr/lib/firmware/$p" ]; then present=1; else missing=1; fi
        done
        if [ "$missing" = 1 ] && [ "$present" = 0 ]; then
            FW_REASON=MISSING
        elif [ -n "$ROOT_T" ] && [ -n "$BT_T" ] && awk -v b="$BT_T" -v r="$ROOT_T" 'BEGIN{exit !(b<r)}'; then
            FW_REASON=RACE
        elif [ "$missing" = 1 ]; then
            FW_REASON=MIXED
        else
            FW_REASON=UNKNOWN
        fi
    fi
}

report_cause() {
    head1 "根因判定"
    case "$VERDICT" in
      OK)
        ok "所有控制器均已正常初始化，无需修复"
        ;;
      NO_ADAPTER)
        bad "没有 hci 控制器 —— 这属于硬件/驱动未加载问题，本脚本的修复阶梯不适用"
        say   "     先查: lsusb -d \$(...)| grep -i blue ; dmesg | grep -iE 'btusb|btrtl|rtl|hci'"
        ;;
      ZOMBIE)
        local d
        for d in "${ZOMBIES[@]}"; do
            bad "$d 是僵尸状态: 控制器存在但从未初始化"
        done
        say "     固件请求记录:"
        fw_line 0 | sed 's/^/       /'
        dmesg 2>/dev/null | grep -E 'firmware file .* not found|Direct firmware load for .* failed' | tail -3 | sed 's/^/       /'
        case "$FW_REASON" in
          RACE)
            say "     ${Y}判定: 开机时序竞速${N}"
            say "     BT 请求固件 @ ${BT_T}s，根文件系统挂载 @ ${ROOT_T}s —— 早读了"
            [ "$NO_INITRAMFS" = 1 ] && say "     且本机无 initramfs(skip_initramfs / /boot 为空)，内建驱动在 initcall 阶段就要固件，"
            [ "$NO_INITRAMFS" = 1 ] && say "     那时内核没有任何文件系统可读 => ENOENT 必然发生，且驱动不会重试。"
            say "     => 对策: 根就绪后重新枚举设备，让驱动重新 probe"
            ;;
          MISSING)
            say "     ${Y}判定: 固件文件确实缺失${N}"
            for p in "${FW_PATHS[@]}"; do
                [ -e "/lib/firmware/$p" ] || say "       缺失: /lib/firmware/$p"
            done
            say "     => 本脚本不下载固件。请先解决固件来源(发行版 firmware 包 / 厂商驱动包)，再重跑。"
            ;;
          MIXED)
            say "     ${Y}判定: 部分固件路径缺失(多控制器场景)，需逐个确认${N}"
            ;;
          *)
            say "     ${Y}判定: 固件已就位但控制器仍未初始化${N}"
            say "     => 可能是固件与芯片不匹配、config 文件错误，或射频/供电问题。先重试一次，再查 dmesg 全量。"
            ;;
        esac
        ;;
    esac
}

# ------------------------------------------------------------------ 修复阶梯
try_reprobe() {
    local h=$1 dev=$2 attempt=$3
    say "  尝试 $attempt: unbind/bind $dev"
    echo "$dev" > /sys/bus/usb/drivers/usb/unbind 2>/dev/null
    sleep 1
    echo "$dev" > /sys/bus/usb/drivers/usb/bind 2>/dev/null
    local i a
    for i in $(seq 1 15); do
        sleep 1
        a=$(bd_of "$h")
        [ -n "$a" ] && [ "$a" != "$ZERO" ] && return 0
    done
    return 1
}

fix_zombies() {
    local h dev drv a attempt fixed=0
    for h in "${ZOMBIES[@]}"; do
        if ! dev=$(usb_dev_of "$h"); then
            warn "$h 不是 USB 控制器，跳过(需人工处理)"
            continue
        fi
        # L1: 纯重新枚举
        attempt=1
        while [ "$attempt" -le "$MAX_ATTEMPT" ]; do
            if try_reprobe "$h" "$dev" "$attempt"; then
                a=$(bd_of "$h")
                ok "$h 恢复: BD=$a"
                fixed=$((fixed+1))
                break
            fi
            # L2: 若有外部模块正绑在故障设备上，卸载后重试(可逆)
            if [ "$attempt" -lt "$MAX_ATTEMPT" ]; then
                if drv=$(driver_of "$dev") && [ "$drv" != "btusb" ] && modinfo -F filename "$drv" >/dev/null 2>&1; then
                    warn "设备被外部模块 $drv 占用，尝试卸载后重试"
                    modprobe -r "$drv" 2>/dev/null && info "已卸载 $drv"
                    case "$drv" in
                      rtl_btusb|rtk_btusb)
                        info "提示: 该模块每次开机都会被 udev 按 modalias 拉起，建议 --install --blacklist $drv" ;;
                    esac
                fi
            fi
            attempt=$((attempt+1))
        done
        [ "$attempt" -gt "$MAX_ATTEMPT" ] && bad "$h 修复失败(未做任何破坏性操作，可安全继续排查)"
    done
    return $(( fixed > 0 ? 0 : 1 ))
}

ensure_powered() {
    local h=$1 a
    a=$(bd_of "$h")
    if [ -z "$a" ] || [ "$a" = "$ZERO" ]; then return 0; fi
    if hciconfig "$h" 2>/dev/null | grep -q ' DOWN'; then
        info "$h 处于 DOWN，尝试上电"
        systemctl try-restart bluetooth.service >/dev/null 2>&1
        sleep 3
        if hciconfig "$h" 2>/dev/null | grep -q ' DOWN'; then
            hciconfig "$h" up 2>/dev/null
        fi
    fi
}

verify() {
    head1 "验证"
    local h scan_ok=0
    for h in "${ADAPTERS[@]}"; do
        local a s
        a=$(bd_of "$h"); s=$(state_of "$h")
        if [ -n "$a" ] && [ "$a" != "$ZERO" ]; then
            ok "$h BD=$a 状态=${s:-?}"
            printf '%s' "$s" | grep -q 'UP RUNNING' && scan_ok=1
        else
            bad "$h 仍未初始化"
        fi
    done
    if [ "$scan_ok" = 1 ] && [ "$QUIET" = 0 ]; then
        info "实扫 12s 验证射频链路..."
        local cnt
        cnt=$({ echo 'scan on'; sleep 10; echo 'devices'; sleep 1; echo quit; } \
              | timeout 20 bluetoothctl 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -c 'Device ')
        if [ "${cnt:-0}" -gt 0 ]; then
            ok "扫到 $cnt 个附近设备(射频正常)"
        else
            warn "12s 内未扫到任何设备 —— 射频/天线/环境(附近无设备)三者之一，需人工判断"
        fi
    fi
}

# ------------------------------------------------------------------ 持久化
do_install() {
    local ts dir f
    ts=$(date +%Y%m%d-%H%M%S); dir=$BACKUP_ROOT/$ts
    mkdir -p "$dir"
    head1 "安装开机自愈服务"
    for f in "$UNIT_PATH" "$INSTALLED_SCRIPT" /etc/modprobe.d/blacklist-bt-conflict.conf; do
        [ -e "$f" ] && { cp -a "$f" "$dir/" 2>/dev/null && info "已备份 $f -> $dir/"; }
    done

    install -m 755 "$SELF" "$INSTALLED_SCRIPT" && ok "安装脚本 -> $INSTALLED_SCRIPT"

    cat > "$UNIT_PATH" <<EOF
[Unit]
Description=Re-probe dead Bluetooth HCI controller (firmware/boot race workaround)
Documentation=file:/var/log/bt-dead-hci0.log
After=bluetooth.service bluetooth.target local-fs.target
Wants=bluetooth.service

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 5
ExecStart=$INSTALLED_SCRIPT --fix --quiet
TimeoutStartSec=180
StandardOutput=append:/var/log/bt-dead-hci0.log
StandardError=append:/var/log/bt-dead-hci0.log
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF
    ok "写入 $UNIT_PATH"

    if [ "${#BLACKLIST[@]}" -gt 0 ]; then
        { echo "# bt-dead-hci0-fix: 屏蔽与内核 btusb 冲突的外部蓝牙模块"
          for f in "${BLACKLIST[@]}"; do
              echo "blacklist $f"
              echo "install $f /bin/false"
          done
        } > /etc/modprobe.d/blacklist-bt-conflict.conf
        ok "写入 /etc/modprobe.d/blacklist-bt-conflict.conf: ${BLACKLIST[*]}"
        for f in "${BLACKLIST[@]}"; do modprobe -r "$f" 2>/dev/null && info "已卸载 $f"; done
    fi

    systemctl daemon-reload
    systemctl enable "$UNIT_NAME" >/dev/null 2>&1 && ok "已 enable $UNIT_NAME"
    info "备份目录: $dir (回滚用 --uninstall)"
}

do_uninstall() {
    head1 "回滚持久化改动"
    systemctl disable --now "$UNIT_NAME" >/dev/null 2>&1 && info "已 disable $UNIT_NAME"
    rm -f "$UNIT_PATH" "$INSTALLED_SCRIPT" /etc/modprobe.d/blacklist-bt-conflict.conf \
      && ok "已删除落盘文件"
    systemctl daemon-reload
    info "运行时状态未改动；如需恢复被屏蔽的模块请手动 modprobe"
}

# ------------------------------------------------------------------ 主流程
collect
report_hardware
report_adapters
classify
report_cause

case "$MODE" in
  diagnose)
    exit 0 ;;
  auto)
    if [ "$VERDICT" = ZOMBIE ]; then
        head1 "执行修复(运行时/可逆)"
        fix_zombies
        for h in "${ZOMBIES[@]}"; do ensure_powered "$h"; done
        collect
        classify
    fi
    case "$VERDICT" in
      NO_ADAPTER) : ;;
      *)          verify ;;
    esac
    head1 "下一步"
    case "$VERDICT" in
      OK)
        info "控制器健康，本次无需持久化改动"
        info "若问题在重启后复现(开机竞速)，装开机自愈:  sudo $SELF --install"
        ;;
      NO_ADAPTER)
        bad "仍无控制器 —— 属硬件/驱动未加载，不在本脚本修复范围"
        ;;
      ZOMBIE)
        if [ "$FW_REASON" = MISSING ]; then
          bad "固件确实缺失，本脚本不下载固件 —— 补齐后重跑"
        elif [ "$FW_REASON" = RACE ]; then
          warn "运行时修复未成功；若确认是开机竞速，装开机自愈:  sudo $SELF --install"
        else
          warn "运行时修复未成功，需人工看 dmesg 全量(可能是固件不匹配/射频/供电)"
        fi
        ;;
    esac
    ;;
  fix)
    if [ "$VERDICT" = ZOMBIE ]; then
        fix_zombies || true
        for h in "${ZOMBIES[@]}"; do ensure_powered "$h"; done
        collect; classify
    fi
    # 开机自愈日志的单行结论
    if [ "$QUIET" = 1 ]; then
        printf '%s summary verdict=%s fw=%s adapters=%s bd=%s\n' \
            "$(date -Is)" "$VERDICT" "$FW_REASON" \
            "$(printf "%s " "${ADAPTERS[*]:-none}")" \
            "$(bd_of "${ADAPTERS[0]:-hci0}")"
    else
        verify
    fi
    ;;
  install)
    do_install
    ;;
  uninstall)
    do_uninstall
    ;;
esac
