#!/usr/bin/env python3
"""ECN 通知 —— 本机执行脚本(dsh profile #举例)。

流程:拉抄送(topic 17/18, --as user) -> 去重 -> 取实例详情(--as user)
      -> 下载附件并还原真实文件名 -> 渲染总结 -> bot 发到群(--as bot)
      -> 附件按本地文件名 reply-in-thread -> 写回去重表

用法:
    python3 ecn_notify.py                 # 正常跑(无新 ECN 则静默)
    python3 ecn_notify.py --dry-run       # 只渲染,不发消息、不写状态(附件会下载,打印真实文件名)
    python3 ecn_notify.py --window 3600   # 自定义回看窗口(秒)
    python3 ecn_notify.py --dry-run --ignore-state   # 无视去重表重放,核对格式用
                                                      # (写回时与磁盘状态取并集,不会冲掉历史)

格式与命名约定见 skill 文档: ~/.codex/skills/ecn-notify/SKILL.md
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import mimetypes
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
from pathlib import Path

WORKSPACE = Path("/Users/mac/dsh-workspace/ecn-notify")   #举例:运行目录按自己环境改
STATE_FILE = WORKSPACE / "ecn_sent.json"
LOG_FILE = WORKSPACE / "logs" / "run.log"

# 审批定义 code:一串 UUID 形态的内部标识(审批定义列表 / 审批后台里取)。
# 这里不放真实值——换成你自己那条 ECN 审批的定义 code。
APPROVAL_CODE = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
TOPICS = [17, 18]  # 17=未读知会, 18=已读知会
# 目标群 chat_id:oc_ 开头的内部标识(群信息 / chat 列表里取)。这里不放真实值。
CHAT_ID = "oc_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
# 告警私聊对象:告警要发给谁,就填谁的 open_id(ou_ 开头,从消息事件 / 通讯录里取)。
ALERT_USER_ID = "ou_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"


def env(name: str, default: str) -> str:
    """允许用环境变量覆盖常量(便于本地/其他机器试跑),默认值就是本机真值。"""
    value = (os.environ.get(name) or "").strip()
    return value or default


CHAT_ID = env("ECN_CHAT_ID", CHAT_ID)
ALERT_USER_ID = env("ECN_ALERT_USER_ID", ALERT_USER_ID)

ATTACHMENT_URL_RE = re.compile(
    r"https://[^\s\"'\\]*(?:drive-stream|/space/api/box/stream/download)[^\s\"'\\]*"
)
ANY_URL_RE = re.compile(r"https?://[^\s\"'\\]+")
FILE_TOKEN_RE = re.compile(r"^file_[A-Za-z0-9]{10,}$")
ATTACHMENT_TYPES = {"attachment", "attachmentV2", "image", "imageV2", "file", "files"}

# 条目开头的编号:优先表单里的「变更编号」(ECN2609100002 这种,和附件文件名一致),
# 不是 ECN 形态时退回审批单编号 serial_number(202609100225 这种)。
# 想只认审批单号就把这里改成 "serial"。
HEADER_ID_MODE = "ecn"
ECN_NO_RE = re.compile(r"^ECN\d{6,}$", re.IGNORECASE)

# 表单控件的默认提示文案,不是真实数据,当空处理
PLACEHOLDER_PREFIX_RE = re.compile(r"^(?:非必填|选填|请填写|请选择|此项|该字段)")
PLACEHOLDER_EXACT = {"", "无", "/", "-", "—", "n/a", "na", "null", "none"}

# 同一轮里多个 topic 报同一条认证/权限错误时只记一次
QUERY_ERRORS: set[str] = set()


def log(msg: str) -> None:
    line = f"[{dt.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {msg}"
    print(line, flush=True)
    try:
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        with LOG_FILE.open("a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError:
        pass


def clean_text(value: str) -> str:
    """去掉表单默认提示文案(如「非必填选项,产品经理填写」)——那不是数据。"""
    text = (value or "").strip()
    if text.lower() in PLACEHOLDER_EXACT:
        return ""
    if len(text) <= 30 and PLACEHOLDER_PREFIX_RE.match(text):
        return ""
    return text


def display_id(item: dict) -> str:
    """条目开头的编号:一个,短,可检索。

    取值优先级:
    1. 表单里的「变更编号」(填了 ECN 号的正常情况)
    2. 附件文件名里的 ECN 号(有的单子「变更编号」栏被填成 B0 物料码,
       真 ECN 号只在附件名里,如 ECN2609110001.pdf)
    3. 审批单编号 serial_number(兜底,一定有)
    HEADER_ID_MODE = "serial" 时跳过 1/2,直接只认审批单号。
    """
    serial = (item.get("serial") or "").strip()
    if serial == "0":
        serial = ""
    if HEADER_ID_MODE != "ecn" and serial:
        return serial
    candidates = [item.get("ecn_no") or ""]
    candidates += [Path(att.get("filename") or "").stem for att in item.get("attachments", [])]
    for candidate in candidates:
        text = (candidate or "").strip()
        if ECN_NO_RE.match(text):
            return text.upper()
    if serial:
        return serial
    return item.get("instance_code") or "未知流程"


def fallback_stem(item: dict) -> str:
    """下载兜底文件名(Content-Disposition 缺失时用),不含文件名推导,避免循环。"""
    for key in ("ecn_no", "serial", "instance_code"):
        value = str(item.get(key) or "").strip()
        if value and value != "0":
            return safe_filename(value) or "ECN"
    return "ECN"


def safe_filename(name: str) -> str:
    """清掉路径分隔符等不合法字符,保留中文(飞书支持中文文件名)。"""
    name = re.sub(r'[\\/:*?"<>|\r\n\t]+', "_", (name or "").strip().strip('"')).strip(" .")
    return name


def filename_from_disposition(disposition: str, fallback: str) -> str:
    """从 Content-Disposition 取真实文件名。

    必须这么取:飞书附件 URL 的路径末段是 `authcode`,lark-cli 直接吃 URL 上传后
    文件名就叫 `authcode`(无扩展名)——这就是「下载出来是 authcode」的原因。
    优先 RFC 5987 的 filename*=UTF-8''xxx,退回 filename="xxx"。
    """
    for pattern in (r"filename\*\s*=\s*([^;]+)", r"filename\s*=\s*\"([^\"]+)\"", r"filename\s*=\s*([^;]+)"):
        match = re.search(pattern, disposition or "", re.IGNORECASE)
        if not match:
            continue
        raw = match.group(1).strip().strip('"').strip()
        if "''" in raw:  # UTF-8''%E4%B8%AD%E6%96%87.pdf
            charset, _, encoded = raw.partition("''")
            try:
                raw = urllib.parse.unquote(encoded, encoding=charset or "utf-8", errors="replace")
            except LookupError:
                raw = urllib.parse.unquote(encoded, errors="replace")
        else:
            raw = urllib.parse.unquote(raw, errors="replace")
        cleaned = safe_filename(raw)
        if cleaned:
            return cleaned
    return safe_filename(fallback)


def unique_path(path: Path) -> Path:
    if not path.exists():
        return path
    stem, suffix, idx = path.stem, path.suffix, 2
    while True:
        candidate = path.with_name(f"{stem}-{idx}{suffix}")
        if not candidate.exists():
            return candidate
        idx += 1


def download_attachment(url: str, dest_dir: Path, fallback_stem: str) -> Path | None:
    """下载附件到本地并还原真实文件名(签名 URL 约 12h 过期,当轮必须下载)。"""
    request = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    try:
        with urllib.request.urlopen(request, timeout=120) as resp:  # noqa: S310 - 飞书签名下载链接
            ctype = (resp.headers.get("Content-Type") or "").split(";")[0].strip()
            ext = mimetypes.guess_extension(ctype) if ctype else ""
            fallback = f"{fallback_stem}{ext or ''}"
            name = filename_from_disposition(resp.headers.get("Content-Disposition") or "", fallback)
            path = unique_path(dest_dir / name)
            with path.open("wb") as fh:
                shutil.copyfileobj(resp, fh)
    except Exception as exc:  # noqa: BLE001 - 单个附件失败不能拖垮整轮
        log(f"WARN 附件下载失败({type(exc).__name__}: {exc}): {url[:80]}")
        return None
    if path.stat().st_size == 0:
        path.unlink(missing_ok=True)
        log(f"WARN 附件下载为空,跳过: {url[:80]}")
        return None
    return path


def json_objects(raw: str) -> list:
    """从 CLI 输出里抽出所有合法 JSON 值。

    lark-cli 会在同一个流里混排多段 JSON(响应本体、更新提示 _notice)和进度行
    (--page-all 时的 "[page 1] fetching..."),所以不能整段 json.loads;
    从每个 '{' / '[' 起点试 raw_decode。
    """
    if not raw:
        return []
    decoder = json.JSONDecoder()
    found = []
    for idx, char in enumerate(raw):
        if char not in "{[":
            continue
        try:
            value, _ = decoder.raw_decode(raw, idx)
        except json.JSONDecodeError:
            continue
        found.append(value)
    return found


def run_cli(args: list[str], cwd: Path | None = None) -> tuple[bool, dict | str]:
    """跑 lark-cli,返回 (ok, 解析后的 JSON 或错误说明字符串)。

    cwd:lark-cli 的 `--file` 只吃「cwd 相对路径」(绝对路径和 .. 会被拒),
    所以上传本地附件时把 cwd 指到附件目录、只传文件名。

    踩过的坑:
    - 成功响应走 stdout;失败响应(ok:false)走 **stderr**,exit code 非 0
    - 同一个流里还可能跟一段更新提示 JSON(_notice),只有 ok 字段的那段是响应
    - --page-all 会往 stderr 插 "[page N] fetching..." 进度行
    所以判定只看带 "ok" 字段的对象,stdout 优先。
    """
    cmd = ["lark-cli"] + args
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=300, cwd=str(cwd) if cwd else None)
    except subprocess.TimeoutExpired:
        return False, "lark-cli timeout"

    for stream in (proc.stdout or "", proc.stderr or ""):
        for data in json_objects(stream):
            if not isinstance(data, dict) or "ok" not in data:
                continue
            if data.get("ok") is False:
                err = data.get("error") or {}
                return False, str(err.get("message") or err.get("subtype") or data)
            return True, data

    raw = ((proc.stdout or "").strip() or (proc.stderr or "").strip())[:300]
    return False, f"无法解析 CLI 输出(exit={proc.returncode}): {raw}"


def unwrap(data: dict) -> dict:
    """lark-cli 的成功 JSON 可能把 API 响应放在 data 字段里。"""
    inner = data.get("data")
    return inner if isinstance(inner, dict) else data


def check_user_token() -> tuple[bool, float | None, str]:
    """记录 user 身份 token 的剩余寿命,返回 (是否可用, 剩余天数, 说明)。

    飞书口径:user_access_token 2 小时过期,refresh_token 7 天过期。
    7 天是**空闲窗口**不是授权总寿命——每次以 user 身份调用会拿 refresh_token 换新
    token,飞书同时下发新的 refresh_token(旧的作废),7 天重新计时。
    所以只要任务至少每 7 天跑一次(本机每天 9:15)就永不掉线;真正会掉线的是
    「连续 7 天没跑」,那时只能重新走 device flow 授权。

    证据:claude profile 同一账号的授权 grantedAt=2026-08-04,至今(9/11)仍 valid,
    refreshExpiresAt 一直是「最近一次刷新 + 7 天」,就是滚出来的。
    """
    try:
        proc = subprocess.run(
            ["lark-cli", "auth", "status", "--json"],
            capture_output=True, text=True, timeout=60,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        note = f"token 状态读取失败: {type(exc).__name__}: {exc}"
        log(f"WARN {note}")
        return False, None, note

    user = None
    for data in json_objects((proc.stdout or "") + "\n" + (proc.stderr or "")):
        if isinstance(data, dict) and isinstance(data.get("identities"), dict):
            user = data["identities"].get("user")
            break
    if not user:
        note = "读不到 user 身份状态(授权可能已失效)"
        log(f"WARN {note}")
        return False, None, note

    if not user.get("available"):
        note = f"user 身份不可用: {user.get('message') or user.get('status')}"
        log(f"WARN {note}")
        return False, None, note

    raw = user.get("refreshExpiresAt") or ""
    try:
        expires = dt.datetime.fromisoformat(raw)
    except ValueError:
        note = f"refresh token 到期时间无法解析: {raw!r}"
        log(f"user 身份就绪,{note}")
        return True, None, note

    days = (expires - dt.datetime.now(expires.tzinfo)).total_seconds() / 86400
    log(f"user 身份就绪,refresh token 剩余 {days:.1f} 天(到 {expires:%Y-%m-%d %H:%M})")
    if days < 2:
        note = (f"refresh token 只剩 {days:.1f} 天(到 {expires:%Y-%m-%d %H:%M})"
                "—— 连续 7 天没跑过任务才会出现,需要重新授权")
        log(f"WARN {note}")
        return True, days, note
    return True, days, ""


def load_state() -> dict:
    """读状态文件,统一成 {"sent": {code: iso}, "alerts": {key: iso}}。

    兼容旧格式(纯数组,没有时间戳):旧条目补一个 dt.now() 时间戳并记一条 WARN。
    旧格式里没有记录「什么时候发的」,补 now 只会让下次窗口左界偏保守(更小),
    最坏情况是重查一遍已发过的条目——由去重挡住,不会重复推送。
    """
    empty = {"sent": {}, "alerts": {}}
    if not STATE_FILE.exists():
        return empty
    try:
        loaded = json.loads(STATE_FILE.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as exc:
        log(f"WARN 状态文件读取失败,按空处理: {exc}")
        return empty

    now = now_local().isoformat(timespec="seconds")
    if isinstance(loaded, list):  # 旧格式
        sent = {str(x): now for x in loaded}
        log(f"WARN 状态文件是旧格式(纯数组),已迁移 {len(sent)} 条(时间戳补为当前时间)")
        return {"sent": sent, "alerts": {}}
    if not isinstance(loaded, dict):
        log(f"WARN 状态文件结构异常({type(loaded).__name__}),按空处理")
        return empty

    sent = loaded.get("sent") if isinstance(loaded.get("sent"), dict) else {}
    alerts = loaded.get("alerts") if isinstance(loaded.get("alerts"), dict) else {}
    return {
        "sent": {str(k): str(v) for k, v in sent.items()},
        "alerts": {str(k): str(v) for k, v in alerts.items()},
    }


def merge_state(known: dict, new: dict) -> dict:
    """写回状态用:永远是并集。

    `--ignore-state` 补发时也走这里——否则一次补发就把磁盘上的历史记录覆盖掉,
    去重表形同清空(旧版就是这样)。时间戳冲突时保留**更早**的那个:窗口左界要够保守。
    告警冷却记录同样取并集,按时间戳新的那个。
    """
    sent = dict(known.get("sent") or {})
    for code, ts in (new.get("sent") or {}).items():
        old = sent.get(code)
        sent[code] = min(old, ts) if old else ts
    alerts = dict(known.get("alerts") or {})
    for key, ts in (new.get("alerts") or {}).items():
        old = alerts.get(key)
        alerts[key] = max(old, ts) if old else ts
    return {"sent": sent, "alerts": alerts}


def save_state(state: dict) -> None:
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(STATE_FILE)


def parse_ts(raw: str) -> dt.datetime | None:
    """解析状态文件里的 ISO 时间戳;naive 的按本地时区补上,便于统一比较。"""
    try:
        value = dt.datetime.fromisoformat(str(raw))
    except (TypeError, ValueError):
        return None
    return value if value.tzinfo else value.astimezone()


def now_local() -> dt.datetime:
    """带本地时区的当前时间。

    状态文件里的时间戳统一带时区(naive 的读进来补本地时区),
    比较时就不会踩 naive / aware 不能相减的坑。
    """
    return dt.datetime.now().astimezone()


def resolve_window_start(now_ts: int, window: int, sent: dict, rolling: bool) -> tuple[int, str]:
    """窗口左界。

    - rolling(默认开):`min(now-window, 最早未发条目的记录时间)`。
      机器睡了 30 小时再唤醒时,写死的 now-86400 会漏掉最前面那几小时;
      用最早未发条目自己的记录时间当左界,这段缺口也能捞回来。
      末尾再往前留 5 分钟余量,吃掉时钟/记录粒度误差;重复由去重表挡住。
    - rolling 关掉 / 状态为空:退回原始的 now-window(纯 24h 滚动)。

    返回 (起始 unix 秒, 说明)。
    """
    base = now_ts - window
    if not rolling or not sent:
        return base, "固定窗口"
    oldest = min((parse_ts(ts) for ts in sent.values()), default=None)
    if oldest is None:
        return base, "固定窗口(状态时间戳不可用)"
    oldest_ts = int(oldest.timestamp()) - 300
    if oldest_ts >= base:
        return base, "固定窗口(状态记录更新)"
    gap_h = (base - oldest_ts) / 3600
    return oldest_ts, f"滚动兜底(补上次缺口 {gap_h:.1f}h)"


def query_topic(topic: int, start: int, end: int) -> list[dict] | None:
    ok, data = run_cli_retry(
        [
            "approval", "tasks", "query",
            "--definition-code", APPROVAL_CODE,
            "--topic", str(topic),
            "--start-timestamp", str(start),
            "--end-timestamp", str(end),
            "--page-all",
            "--as", "user",
        ]
    )
    if not ok:
        # 认证/权限类错误两个 topic 会重复报,同一条只记一次;
        # 但必须返回 None 让上层区分「查失败」和「查到 0 条」——静默会被误读成今天没有 ECN
        if data not in QUERY_ERRORS:
            log(f"ERROR topic {topic} 查询失败: {data}")
            QUERY_ERRORS.add(str(data))
        return None
    items = unwrap(data).get("tasks") or unwrap(data).get("items") or []
    log(f"topic {topic}: 返回 {len(items)} 条")
    return [x for x in items if isinstance(x, dict)]


# ---------------------------------------------------------------- 告警分类

# user 授权失效类:重试没用,只能重新授权
AUTH_PATTERNS = (
    "need_user_authorization", "token_missing", "invalid_grant", "refresh_token",
    "user_access_token", "unauthorized", "401", "auth login",
)
# 网络/服务端类:大概率是一过性,值得重试几次
NETWORK_PATTERNS = (
    "timeout", "timed out", "connection", "temporary failure", "getaddrinfo",
    "resolve", "unreachable", "network", "econnrefused", "econnreset",
    "tls", "502", "503", "504", "429", "rate limit",
)
# 权限/应用配置类:重试没用,要人处理
PERMISSION_PATTERNS = (
    "access denied", "permission", "1069303", "forbidden", "403", "scope", "not in chat",
)


def classify_error(message: str) -> str:
    """把 lark-cli 的错误文案归类:auth / network / permission / other。

    分类决定告警文案和要不要重试——授权和权限问题重试是白等,网络问题值得再试两次。
    """
    text = str(message or "").lower()
    if any(p in text for p in AUTH_PATTERNS):
        return "auth"
    if any(p in text for p in NETWORK_PATTERNS):
        return "network"
    if any(p in text for p in PERMISSION_PATTERNS):
        return "permission"
    return "other"


ALERT_HINTS = {
    "auth": ("user 授权失效,抄送查询跑不了(不是「今天没有 ECN」)。"
             "重新授权:私聊里走一遍 device flow,10 秒的事。"),
    "network": ("电脑当时没网络 / 飞书接口没通,抄送查询失败,本次没发简报。"
                "网络恢复后我下次照跑;缺口由滚动窗口兜底,不会漏。"),
    "permission": ("应用 scope 或 bot 群成员权限出问题了。要看具体报错,"
                   "一般是 scope 未开 / bot 被移出群。"),
    "other": "抄送查询失败,原因见日志最后几行。",
}


def run_cli_retry(args: list[str], attempts: int = 3, delay: float = 5.0, cwd: Path | None = None):
    """带重试地跑 lark-cli:仅对网络/服务端类错误重试。

    为什么重试:早上 9:15 是 Mac 刚从 DarkWake 醒来、WiFi 正在重连的窗口,
    DNS/连接失败很常见。DarkWake 只有 40~45 秒,所以退避固定 5 秒、最多 3 次。
    """
    result = run_cli(args, cwd=cwd)
    for attempt in range(2, attempts + 1):
        if result[0]:
            return result
        kind = classify_error(result[1])
        if kind not in ("network", "other"):
            return result
        log(f"WARN 调用失败(第 {attempt - 1} 次,{kind}),{delay:.0f}s 后重试: {str(result[1])[:120]}")
        time.sleep(delay)
        result = run_cli(args, cwd=cwd)
    return result


class Alerter:
    """失败/异常主动私聊告警(bot 身份发给 Bill)。

    设计约定(2026-09-14 定):
    - 只在**真失败**时报,日常成功不打扰;同一天里同一类告警最多一条(冷却 20h),
      免得一天收到三五条一样的。
    - 正常静默的两件事**不报警**:今天 0 条 ECN、以及电脑休眠导致跑晚(系统会补跑)。
    - `--dry-run` / `--no-alert` 一律不发,只写日志。
    - 告警失败永远不能影响主流程(发不出去就只记日志)。
    """

    def __init__(self, enabled: bool, known: dict | None = None, cooldown_hours: float = 20.0):
        self.enabled = enabled
        self.cooldown = dt.timedelta(hours=cooldown_hours)
        self.sent: list[str] = []
        now = now_local()
        self.alerts = {
            key: now
            for key, ts in (known or {}).items()
            if (parse_ts(ts) or now) > now - self.cooldown
        }

    def _cooling(self, key: str) -> bool:
        last = parse_ts(self.alerts.get(key, "")) if key in self.alerts else None
        return bool(last and now_local() - last < self.cooldown)

    def notify(self, key: str, body: str) -> bool:
        if not self.enabled:
            log(f"ALERT(skip) [{key}] {body.splitlines()[0] if body else ''}")
            return False
        if self._cooling(key):
            log(f"ALERT(cooled) [{key}] 20h 内已报过同类,不重复打扰")
            return False
        text = f"⚠️ ECN 通知异常 · {key}\n{body}"
        try:
            ok, data = run_cli(
                ["im", "+messages-send", "--user-id", ALERT_USER_ID, "--as", "bot", "--text", text]
            )
        except Exception as exc:  # noqa: BLE001 - 告警失败不能拖垮主流程
            log(f"WARN 告警发送异常: {type(exc).__name__}: {exc}")
            return False
        if not ok:
            log(f"WARN 告警发送失败: {str(data)[:200]}")
            return False
        now = now_local()
        self.alerts[key] = now
        self.sent.append(key)
        log(f"ALERT 已私聊告警 [{key}]")
        return True

    def state(self) -> dict:
        return {key: ts.isoformat(timespec="seconds") for key, ts in self.alerts.items()}


def pick_task_fields(task: dict) -> dict:
    # 关键:审批 tasks[] 里没有 instance_code 字段,实例 Code 挂在 process_code 上
    # (Go SDK 注释:「审批流程 Code,即审批实例 Code」)。其余键做兼容兜底。
    instance = (
        task.get("process_code")
        or task.get("instance_code")
        or task.get("instanceCode")
        or ""
    )
    title = (
        task.get("title")
        or task.get("approval_name")
        or task.get("definition_name")
        or ""
    )
    status = task.get("status") or task.get("process_status") or ""
    return {
        "instance_code": str(instance),
        "title": str(title),
        "status": str(status),
        "topic": task.get("topic"),
    }


def parse_form(body: dict) -> list[dict]:
    """实例详情里的 form 是 **JSON 字符串**,不是对象。解析成控件列表。"""
    raw = body.get("form")
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except json.JSONDecodeError:
            return []
    if isinstance(raw, list):
        return [x for x in raw if isinstance(x, dict)]
    return []


def scrape_item_value(items: list[dict], keywords: list[str]) -> str:
    """按控件 name 关键词取 value(附件类控件的 value 是 URL 数组,这里跳过)。"""
    for kw in keywords:
        for item in items:
            name = str(item.get("name") or "")
            if kw not in name:
                continue
            value = item.get("value")
            if isinstance(value, str) and value.strip():
                return value.strip()
            if isinstance(value, list):
                texts = [v for v in value if isinstance(v, str) and not v.startswith("http")]
                if texts:
                    return "、".join(texts)
    return ""


def extract_attachments(items: list[dict]) -> list[dict]:
    """从 form 控件里抽附件。

    读取方向 attachmentV2 / imageV2 的 value 是**带签名的 URL 数组**(非 file_xxx),
    链接约 12 小时过期 —— 所以必须当天拉当天发,不能缓存 URL。
    """
    found: list[dict] = []
    for item in items:
        ctype = str(item.get("type") or "")
        value = item.get("value")
        if ctype not in ATTACHMENT_TYPES and not isinstance(value, list):
            continue
        names = str(item.get("ext") or "").strip("'\" ")
        for entry in value if isinstance(value, list) else [value]:
            if not isinstance(entry, str):
                continue
            entry = entry.strip()
            if entry.startswith("http"):
                found.append({"value": entry, "label": names})
            elif FILE_TOKEN_RE.match(entry):
                found.append({"value": entry, "label": names})
    return found


def collect_timeline_files(node, found: list, depth: int = 0) -> None:
    """timeline[].files[] / comment_list[].files[] = {url, file_size, title, type}。"""
    if depth > 8:
        return
    if isinstance(node, dict):
        url, title = node.get("url"), node.get("title")
        if isinstance(url, str) and url.startswith("http"):
            found.append({"value": url, "label": str(title or "")})
            return
        for value in node.values():
            collect_timeline_files(value, found, depth + 1)
    elif isinstance(node, list):
        for item in node:
            collect_timeline_files(item, found, depth + 1)


def dedup_attachments(attachments: list[dict]) -> list[dict]:
    seen, uniq = set(), []
    for att in attachments:
        key = att["value"].split("?")[0]
        if key in seen:
            continue
        seen.add(key)
        uniq.append(att)
    return uniq


def fetch_detail(code: str) -> dict | None:
    ok, data = run_cli_retry(
        ["approval", "instances", "get", "--instance-code", code, "--as", "user"]
    )
    if not ok:
        log(f"WARN {code} 详情拉取失败: {data}")
        return None
    body = unwrap(data)

    form_items = parse_form(body)
    attachments = extract_attachments(form_items)
    collect_timeline_files(body.get("timeline"), attachments)

    submitter = ""
    for key in ("user_id", "start_user_id", "open_id", "initiator"):
        val = body.get(key)
        if isinstance(val, str) and val:
            submitter = val
            break
    if not submitter:
        submitter = scrape_item_value(form_items, ["发起人", "申请人", "提交人"])

    return {
        "instance_code": code,
        "title": body.get("approval_name") or body.get("title") or "",
        "serial": str(body.get("serial_number") or ""),
        "ecn_no": clean_text(scrape_item_value(form_items, ["变更编号", "ECN编号", "ECN号"])),
        "submitter": submitter,
        "change": clean_text(
            scrape_item_value(form_items, ["变更内容", "变更描述", "变更说明", "ECN内容"])
            or scrape_item_value(form_items, ["变更"])
        ),
        "packaging": clean_text(scrape_item_value(form_items, ["关联包材", "包材", "涉及包材", "关联物料"])),
        "attachments": dedup_attachments(attachments),
    }


def render(summary_items: list[dict], failed: list[str], start: dt.datetime, end: dt.datetime) -> str:
    """渲染群里的简报。

    格式约定(2026-09-11 按反馈定稿):
    - 标题:日期后面直接跟时间区间,精确到分钟
    - 每条 ECN 开头只放一个编号(变更编号优先,否则审批单号),不写 UUID / open_id / 发起人
    - 不写「附件:N」这类没用的一行(附件本体在话题里)
    """
    hours = max(1, round((end - start).total_seconds() / 3600))
    lines = [
        f"📋 ECN 发布通知 · {start:%Y-%m-%d %H:%M} ~ {end:%Y-%m-%d %H:%M}",
        f"过去 {hours} 小时新增 {len(summary_items)} 条",
        "",
    ]
    for idx, item in enumerate(summary_items, 1):
        lines.append(f"{idx}. {display_id(item)}")
        lines.append(f"   • 变更内容:{item['change'] or '—'}")
        lines.append(f"   • 关联包材:{item['packaging'] or '无'}")
        lines.append("")
    if failed:
        lines.append(f"⚠️ 异常说明:{len(failed)} 条实例详情拉取失败({', '.join(failed)})")
    return "\n".join(lines).rstrip() + "\n"


def send_summary(markdown: str, dry_run: bool) -> str | None:
    if dry_run:
        log("DRY-RUN 不发送。渲染结果:\n" + markdown)
        return "om_dry_run"
    ok, data = run_cli_retry(
        [
            "im", "+messages-send",
            "--chat-id", CHAT_ID,
            "--as", "bot",
            "--markdown", markdown,
        ]
    )
    if not ok:
        log(f"ERROR 发总结失败: {data}")
        return None
    body = unwrap(data)
    message_id = body.get("message_id") or (body.get("data") or {}).get("message_id") or ""
    log(f"总结已发送 message_id={message_id}")
    return message_id or None


def prepare_attachments(items: list[dict], dest_dir: Path) -> None:
    """先把附件落到本地(还原真实文件名),再渲染/发送。

    顺序很重要:附件文件名里往往就是这条单子的 ECN 号,条目开头的编号要用到它;
    而且签名 URL 约 12h 过期,下载必须和发送同一轮完成。
    """
    for item in items:
        for att in item["attachments"]:
            path = download_attachment(att["value"], dest_dir, fallback_stem(item))
            att["local_path"] = path
            att["filename"] = path.name if path else ""


def send_attachments(message_id: str, items: list[dict], dry_run: bool, dest_dir: Path) -> tuple[int, list[str]]:
    """把每个附件 reply 到总结消息的话题里(--reply-in-thread)。

    两个硬约束:
    1. 附件 URL 是带签名的临时链接(约 12h 过期),必须和总结同一轮发,不能隔天补发。
    2. **不能把 URL 直接丢给 `--file`**:URL 末段是 `authcode`,lark-cli 会拿它当文件名,
       群里的文件就叫 `authcode`(还没扩展名)。所以先自己下载、用 Content-Disposition
       里的真实文件名落盘,再用 cwd 相对路径上传。

    返回 (成功数, 失败的 display_id 列表)——失败要能报出来,不能只进日志。
    """
    sent, failed = 0, []
    for item in items:
        for att in item["attachments"]:
            path = att.get("local_path")
            if not path:
                failed.append(display_id(item) + "(下载失败)")
                continue
            size_kb = path.stat().st_size / 1024
            if dry_run:
                log(f"DRY-RUN 附件就绪 {path.name} ({size_kb:.0f} KB) <- {display_id(item)}")
                continue
            # 故意不过滤大小:飞书 IM 上传上限约 30MB,超了 CLI 会报错,日志里能看到
            ok, data = run_cli_retry(
                [
                    "im", "+messages-reply",
                    "--message-id", message_id,
                    "--as", "bot",
                    "--reply-in-thread",
                    "--file", path.name,
                ],
                cwd=dest_dir,
            )
            if ok:
                sent += 1
                log(f"附件已发 {path.name} ({size_kb:.0f} KB)")
            else:
                failed.append(f"{display_id(item)}/{path.name}")
                log(f"WARN 附件发送失败 {path.name}: {data}")
    return sent, failed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--window", type=int, default=86400, help="回看窗口秒数(rolling 关闭时的固定窗口)")
    parser.add_argument(
        "--ignore-state",
        action="store_true",
        help="忽略去重表(重放用)。真实发送时会重复推已发过的 ECN,除非必要别加",
    )
    parser.add_argument(
        "--no-rolling",
        action="store_true",
        help="关掉滚动窗口兜底,只看 now-window(排查用)",
    )
    parser.add_argument(
        "--no-alert",
        action="store_true",
        help="不发私聊告警(手动排查时用)",
    )
    args = parser.parse_args()

    end_ts = int(time.time())
    end_dt = dt.datetime.fromtimestamp(end_ts)
    known = load_state()
    start_ts, window_note = resolve_window_start(end_ts, args.window, known["sent"], not args.no_rolling)
    start_dt = dt.datetime.fromtimestamp(start_ts)

    alerter = Alerter(enabled=not (args.dry_run or args.no_alert), known=known["alerts"])
    log(f"=== 开跑 window={args.window}s ({start_ts} -> {end_ts}) {window_note} dry_run={args.dry_run}")
    exit_code = 0
    pending: dict = {"sent": {}}
    try:
        token_ok, token_days, token_note = check_user_token()
        if not token_ok:
            alerter.notify("授权不可用", f"{token_note}\n\n{ALERT_HINTS['auth']}")
        elif token_days is not None and token_days < 2:
            alerter.notify("授权即将过期", f"{token_note}\n\n"
                           "现在还没掉线,但连着没跑满 7 天就会掉。我会在私聊里发重新授权链接。")

        tasks: list[dict] = []
        query_failed = 0
        for topic in TOPICS:
            result = query_topic(topic, start_ts, end_ts)
            if result is None:
                query_failed += 1
                continue
            tasks.extend(result)

        if query_failed and not tasks:
            kind = classify_error(next(iter(QUERY_ERRORS), ""))
            alerter.notify("抄送查询失败", f"{ALERT_HINTS.get(kind, '')}\n\n"
                           f"窗口 {start_dt:%m-%d %H:%M} ~ {end_dt:%m-%d %H:%M}({window_note})")
            log("ABORT 抄送查询失败,本次不发消息(不是「今天没有 ECN」)")
            return 1
        if query_failed:
            alerter.notify("抄送查询部分失败",
                           f"{query_failed}/{len(TOPICS)} 个 topic 没查通,本次简报可能不全。"
                           "详情见日志。")

        by_code: dict[str, dict] = {}
        for task in tasks:
            fields = pick_task_fields(task)
            if fields["instance_code"]:
                by_code.setdefault(fields["instance_code"], fields)

        # --ignore-state 只影响「本次是否跳过去重」,写回时仍与磁盘上已有的并集,
        # 免得补发一次就把历史去重记录冲掉(旧版就是直接覆盖)。
        sent_state = {} if args.ignore_state else known["sent"]
        fresh = [code for code in by_code if code not in sent_state]
        fresh.sort()
        log(f"窗口内 {len(by_code)} 条去重后 {len(fresh)} 条待处理")

        if not fresh:
            log("无新 ECN,静默退出")
            return 0

        items, failed = [], []
        for code in fresh:
            detail = fetch_detail(code)
            if detail is None:
                failed.append(code)
                continue
            detail["submitter"] = detail["submitter"] or by_code[code].get("title", "")
            items.append(detail)

        if not items:
            alerter.notify("详情全部拉取失败",
                           f"{len(fresh)} 条待处理 ECN 的实例详情一条都没拉到,本次没发简报。"
                           "详情见日志。")
            log("所有详情都拉失败,不发消息")
            return 1

        dest_dir = Path(tempfile.mkdtemp(prefix="ecn-att-"))
        try:
            prepare_attachments(items, dest_dir)
            markdown = render(items, failed, start_dt, end_dt)
            message_id = send_summary(markdown, args.dry_run)
            if not message_id:
                alerter.notify("简报发送失败",
                               f"{len(items)} 条 ECN 已取到,但总结消息没发进群。"
                               "详情见日志。")
                return 1
            attachment_count, attachment_failed = send_attachments(message_id, items, args.dry_run, dest_dir)
            # 只有真发进群了才记去重;dry-run 不写
            if not args.dry_run:
                sent_at = now_local().isoformat(timespec="seconds")
                pending["sent"] = {i["instance_code"]: sent_at for i in items}
        finally:
            shutil.rmtree(dest_dir, ignore_errors=True)
        log(f"附件发送 {attachment_count} 个" + (f",失败 {len(attachment_failed)} 个" if attachment_failed else ""))

        # 部分失败也要报:群里那条简报看着正常,但附件缺了不会有人发现
        notify_failures(alerter, failed, "条 ECN 的详情没拉到,这些条目没进简报")
        notify_failures(alerter, attachment_failed, "个附件没发进话题")
        log("=== 完成")
        return exit_code
    except Exception as exc:  # noqa: BLE001 - 定时任务需要兜住所有异常
        log(f"ERROR 未捕获异常: {type(exc).__name__}: {exc}")
        alerter.notify("脚本异常退出", f"未捕获异常:{type(exc).__name__}: {exc}\n\n见日志。")
        return 1
    finally:
        # 收尾:去重表与告警冷却记录一起落盘(跑成没跑成都要落,否则告警会重复响)
        if not args.dry_run:
            try:
                saved = merge_state(known, {"sent": pending["sent"], "alerts": alerter.state()})
                save_state(saved)
                log(f"状态已写入 {STATE_FILE}"
                    f"(去重 {len(saved['sent'])} 条 / 告警记录 {len(saved['alerts'])} 条)")
            except OSError as exc:
                log(f"WARN 状态写入失败: {exc}")


def notify_failures(alerter: "Alerter", failures: list[str], tail: str) -> None:
    """把「部分条目失败」也报出来——这类失败群里看不出痕迹,不报就没人知道。"""
    if not failures:
        return
    detail = "、".join(failures[:5]) + ("…" if len(failures) > 5 else "")
    alerter.notify("部分条目异常", f"{len(failures)} {tail}:{detail}")


if __name__ == "__main__":
    sys.exit(main())
