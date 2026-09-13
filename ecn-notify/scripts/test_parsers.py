#!/usr/bin/env python3
"""ecn_notify.py 解析逻辑的离线自测(不联网、不调 lark-cli)。

    python3 test_parsers.py

样本按官方文档 + SDK 字段名构造:form 是 JSON 字符串,
附件控件 value 是带签名的 URL 数组,实例 Code 挂在 tasks[].process_code 上。
"""

import datetime as dt
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import ecn_notify as ecn  # noqa: E402

FAILED = []
PASS_COUNT = 0


def check(name: str, got, want) -> None:
    global PASS_COUNT
    if got == want:
        PASS_COUNT += 1
        print(f"PASS {name}")
    else:
        FAILED.append(name)
        print(f"FAIL {name}\n  got : {got!r}\n  want: {want!r}")


def test_pick_task_fields() -> None:
    task = {
        "process_code": "ECN2609100003",
        "title": "ECN 变更通知",
        "status": "Todo",
        "topic": "17",
    }
    got = ecn.pick_task_fields(task)
    check("process_code 优先", got["instance_code"], "ECN2609100003")
    check("status 读出", got["status"], "Todo")

    # 兜底:老结构(只有 instance_code)
    check(
        "instance_code 兜底",
        ecn.pick_task_fields({"instance_code": "ECN1"})["instance_code"],
        "ECN1",
    )
    # 数字 status(文档字段表那套)也要能出来
    check("数字 status", ecn.pick_task_fields({"process_status": 1})["status"], "1")


def test_parse_form_and_scrape() -> None:
    form = json.dumps(
        [
            {"id": "w1", "name": "变更内容", "type": "textarea", "value": "Y40P OZT WIFI 模块 BOM 搭建"},
            {"id": "w2", "name": "关联包材", "type": "textarea", "value": "Y40P, Y40X"},
            {
                "id": "w3",
                "name": "附件",
                "type": "attachmentV2",
                "value": [
                    "https://internal-api-drive-stream.feishu.cn/space/api/box/stream/download/authcode/?code=AAA&x=1",
                    "https://internal-api-drive-stream.feishu.cn/space/api/box/stream/download/authcode/?code=BBB&x=1",
                ],
                "ext": "'ECN变更单.pdf,对比表.xlsx'",
            },
        ],
        ensure_ascii=False,
    )
    body = {"form": form, "approval_name": "ECN 变更通知", "serial_number": "20260910003"}
    items = ecn.parse_form(body)
    check("form 解析出控件数", len(items), 3)
    check(
        "取变更内容",
        ecn.scrape_item_value(items, ["变更内容"]),
        "Y40P OZT WIFI 模块 BOM 搭建",
    )
    check("取关联包材", ecn.scrape_item_value(items, ["关联包材", "包材"]), "Y40P, Y40X")
    check("取不到时返回空", ecn.scrape_item_value(items, ["不存在字段"]), "")

    atts = ecn.extract_attachments(items)
    check("附件抽到 2 个", len(atts), 2)
    check("附件值是 URL", atts[0]["value"].startswith("https://"), True)
    check("附件 label 去引号", atts[0]["label"], "ECN变更单.pdf,对比表.xlsx")


def test_form_not_json() -> None:
    check("form 非 JSON 不炸", ecn.parse_form({"form": "not-json"}), [])
    check("form 缺失不炸", ecn.parse_form({}), [])


def test_timeline_files() -> None:
    timeline = [
        {
            "type": "PASS",
            "comment": "ok",
            "files": [{"url": "https://open.feishu.cn/a.pdf", "title": "a.pdf", "type": "pdf"}],
        }
    ]
    found: list[dict] = []
    ecn.collect_timeline_files(timeline, found)
    check("timeline 附件", len(found), 1)
    check("timeline 附件标题", found[0]["label"], "a.pdf")


def test_dedup_attachments() -> None:
    dup = [
        {"value": "https://x.cn/f?a=1", "label": ""},
        {"value": "https://x.cn/f?a=2", "label": ""},  # 同文件不同签名
        {"value": "https://y.cn/g", "label": ""},
    ]
    check("按去签名去重", len(ecn.dedup_attachments(dup)), 2)


def test_json_objects() -> None:
    raw = (
        '[page 1] fetching...\n'
        '{"ok": true, "data": {"tasks": [{"process_code": "ECN1"}]}}\n'
        '{"notice": "update available"}\n'
    )
    objs = ecn.json_objects(raw)
    # 注意:进度行 "[page 1] fetching..." 本身也是合法 JSON 数组(["page 1"]),
    # 所以这里不能断言总数,只能断言带 ok 字段的响应体能被捞出来
    dicts = [o for o in objs if isinstance(o, dict) and "ok" in o]
    check("捞出带 ok 的响应体", len(dicts), 1)
    check("抽到响应本体", dicts[0]["data"]["tasks"][0]["process_code"], "ECN1")


def test_render() -> None:
    items = [
        {
            "instance_code": "0DFA55D9-4D04-4EC8-A634-0358D9C25F36",
            "serial": "202609100225",
            "ecn_no": "ECN2609100002",
            "submitter": "示例发起人",
            "change": "BOM 搭建",
            "packaging": "Y40P, Y40X",
            "attachments": [{"value": "u", "label": ""}],
        },
        {
            "instance_code": "5E727D5A-9329-4806-B260-D0638426FFCB",
            "serial": "202609110049",
            "ecn_no": "B010010955 B010010959",  # 不是 ECN 号 → 退回审批单号
            "submitter": "",
            "change": "割草头试产 BOM 更新",
            "packaging": "",
            "attachments": [],
        },
    ]
    start = dt.datetime(2026, 9, 10, 10, 55)
    end = dt.datetime(2026, 9, 11, 10, 55)
    text = ecn.render(items, ["ECN2609100009"], start, end)
    lines = text.splitlines()
    check("标题=日期+分钟级时间区间", lines[0], "📋 ECN 发布通知 · 2026-09-10 10:55 ~ 2026-09-11 10:55")
    check("条数", lines[1], "过去 24 小时新增 2 条")
    check("条目 1 只留变更编号", lines[3], "1. ECN2609100002")
    check("条目 2 退回审批单号", "2. 202609110049" in text, True)
    check("不出现 UUID", "0DFA55D9" not in text, True)
    check("不出现 open_id / 发起人", "示例发起人" not in text, True)
    check("删掉附件行", "附件" not in text, True)
    check("变更内容入文", "   • 变更内容:BOM 搭建" in text, True)
    check("空包材写「无」", "   • 关联包材:无" in text, True)
    check("异常说明入文", "ECN2609100009" in text, True)


def test_clean_text() -> None:
    check("表单提示文案当空", ecn.clean_text("非必填选项，产品经理填写"), "")
    check("真实内容保留", ecn.clean_text("Y40P, Y40X"), "Y40P, Y40X")
    check("「无」当空", ecn.clean_text("无"), "")
    check("以「无」开头的真实值不被误杀", ecn.clean_text("无锡工厂专用包材"), "无锡工厂专用包材")


def test_display_id() -> None:
    check(
        "变更编号优先",
        ecn.display_id({"ecn_no": "ecn2609100002", "serial": "202609100225", "instance_code": "X"}),
        "ECN2609100002",
    )
    check(
        "变更编号非 ECN 形态 → 审批单号",
        ecn.display_id({"ecn_no": "B010010955", "serial": "202609110049", "instance_code": "X"}),
        "202609110049",
    )
    check(
        "变更编号乱填 → 用附件名里的 ECN 号",
        ecn.display_id(
            {
                "ecn_no": "B010010955 B010010959 B010010968",
                "serial": "202609110049",
                "instance_code": "X",
                "attachments": [{"filename": "ECN2609110001.pdf", "local_path": None}],
            }
        ),
        "ECN2609110001",
    )
    check(
        "都没有才用 instance_code",
        ecn.display_id({"ecn_no": "", "serial": "0", "instance_code": "UUID-X"}),
        "UUID-X",
    )
    check(
        "下载兜底名:变更编号 → 单号 → 实例码",
        ecn.fallback_stem({"ecn_no": "", "serial": "202609110049", "instance_code": "X"}),
        "202609110049",
    )


def test_filename_from_disposition() -> None:
    # 飞书真实响应头(实测)
    check(
        "filename*=UTF-8 优先",
        ecn.filename_from_disposition(
            "attachment; filename=\"ECN2609100002.pdf\"; filename*=UTF-8''ECN2609100002.pdf",
            "fallback.pdf",
        ),
        "ECN2609100002.pdf",
    )
    check(
        "中文名 URL 解码",
        ecn.filename_from_disposition(
            "attachment; filename*=UTF-8''%E5%8F%98%E6%9B%B4%E5%8D%95.pdf",
            "fallback.pdf",
        ),
        "变更单.pdf",
    )
    check(
        "只有 filename= 也能取",
        ecn.filename_from_disposition('attachment; filename="a b.pdf"', "fallback.pdf"),
        "a b.pdf",
    )
    check("没有头就用兜底名", ecn.filename_from_disposition("", "ECN2609100002.pdf"), "ECN2609100002.pdf")
    traversal = ecn.safe_filename("../../etc/passwd")
    check("路径穿越:分隔符被清", "/" not in traversal and "\\" not in traversal, True)
    check("路径穿越:不以 . 开头", traversal.startswith("."), False)
    check(
        "带中文的兜底名",
        ecn.filename_from_disposition("attachment", "ECN2609100002.pdf"),
        "ECN2609100002.pdf",
    )


def test_unique_path() -> None:
    import tempfile as _tf
    from pathlib import Path as _P

    with _tf.TemporaryDirectory() as tmp:
        target = _P(tmp) / "ECN1.pdf"
        check("首次不冲突", ecn.unique_path(target).name, "ECN1.pdf")
        target.write_bytes(b"x")
        check("冲突加序号", ecn.unique_path(target).name, "ECN1-2.pdf")


def test_merge_state() -> None:
    """写回状态永远是并集:补发不能覆盖历史,告警冷却不能被旧记录顶掉。"""
    known = {"sent": {"a": "2026-09-01T10:00:00"}, "alerts": {"x": "2026-09-13T09:00:00"}}
    new = {"sent": {"b": "2026-09-02T10:00:00"}, "alerts": {"x": "2026-09-14T09:00:00"}}
    got = ecn.merge_state(known, new)
    check("去重表并集", sorted(got["sent"]), ["a", "b"])
    check("时间戳冲突取更早(窗口更保守)", got["sent"]["a"], "2026-09-01T10:00:00")
    check("告警记录取更新", got["alerts"]["x"], "2026-09-14T09:00:00")
    check("空新增保留历史", ecn.merge_state({"sent": {"x": "t"}, "alerts": {}}, {"sent": {}, "alerts": {}})["sent"], {"x": "t"})
    check("空历史", ecn.merge_state({"sent": {}, "alerts": {}}, {"sent": {"y": "t"}, "alerts": {}})["sent"], {"y": "t"})


def test_resolve_window_start() -> None:
    """滚动窗口兜底:机器睡了 30h 再唤醒,窗口左界要退到最早未发条目的记录时间。"""
    now = 1_772_000_000
    day = 86400
    # 状态为空 → 固定窗口
    check("空状态用固定窗口", ecn.resolve_window_start(now, day, {}, True)[0], now - day)
    check("关掉 rolling 用固定窗口", ecn.resolve_window_start(now, day, {"x": "whatever"}, False)[0], now - day)

    # 上次成功跑在 32h 前(睡了 30h 的场景):左界退到那时,再留 5 分钟余量
    old = dt.datetime.fromtimestamp(now - 32 * 3600)
    start, note = ecn.resolve_window_start(now, day, {"a": old.isoformat()}, True)
    check("缺口被兜住", start, int(old.timestamp()) - 300)
    check("标注滚动兜底", "滚动兜底" in note, True)

    # 状态记录比固定窗口新(正常一天一跑)→ 不退,保持 24h
    recent = dt.datetime.fromtimestamp(now - 3 * 3600)
    start, note = ecn.resolve_window_start(now, day, {"a": recent.isoformat()}, True)
    check("正常情况不放大窗口", start, now - day)
    check("标注固定窗口", "固定窗口" in note, True)

    # 多条状态时取最早的那条
    older = dt.datetime.fromtimestamp(now - 50 * 3600)
    start, _ = ecn.resolve_window_start(now, day, {"a": recent.isoformat(), "b": older.isoformat()}, True)
    check("取最早记录当左界", start, int(older.timestamp()) - 300)

    # 时间戳坏的不能炸
    check("坏时间戳退回固定窗口", ecn.resolve_window_start(now, day, {"a": "not-a-date"}, True)[0], now - day)


def test_parse_ts() -> None:
    parsed = ecn.parse_ts("2026-09-14T09:15:00")
    check("naive 时间戳补本地时区", parsed.tzinfo is not None, True)
    check("坏值返回 None", ecn.parse_ts("nope"), None)
    check("缺值返回 None", ecn.parse_ts(None), None)


def test_state_roundtrip() -> None:
    """状态文件读写 + 旧格式(纯数组)自动迁移。"""
    import tempfile as _tf
    from pathlib import Path as _P

    with _tf.TemporaryDirectory() as tmp:
        original = ecn.STATE_FILE
        try:
            ecn.STATE_FILE = _P(tmp) / "ecn_sent.json"
            check("文件不存在返回空结构", ecn.load_state(), {"sent": {}, "alerts": {}})

            ecn.STATE_FILE.write_text(json.dumps(["CODE-1", "CODE-2"]), encoding="utf-8")
            migrated = ecn.load_state()
            check("旧格式条目保留", sorted(migrated["sent"]), ["CODE-1", "CODE-2"])
            check("旧格式补时间戳", bool(ecn.parse_ts(migrated["sent"]["CODE-1"])), True)
            check("旧格式无告警记录", migrated["alerts"], {})

            new_state = {"sent": {"CODE-1": "2026-09-01T09:15:00"}, "alerts": {"抄送查询失败": "2026-09-14T09:15:00"}}
            ecn.save_state(new_state)
            check("写回可读", ecn.load_state(), new_state)

            ecn.STATE_FILE.write_text("{ not json", encoding="utf-8")
            check("坏文件不炸", ecn.load_state(), {"sent": {}, "alerts": {}})
        finally:
            ecn.STATE_FILE = original


def test_classify_error() -> None:
    """错误分类:决定要不要重试、告警文案怎么写。"""
    check("授权失效", ecn.classify_error("need_user_authorization: user token missing"), "auth")
    check("refresh token 复用", ecn.classify_error("refresh_token_reused"), "auth")
    check("网络超时", ecn.classify_error("lark-cli timeout"), "network")
    check("DNS 解析失败", ecn.classify_error("getaddrinfo ENOTFOUND open.feishu.cn"), "network")
    check("连接被拒", ecn.classify_error("connect ECONNREFUSED 10.0.0.1:443"), "network")
    check("权限被拒", ecn.classify_error("1069303 Access denied"), "permission")
    check("未知出错归 other", ecn.classify_error("something odd"), "other")
    check("空值不炸", ecn.classify_error(""), "other")


def test_alerter() -> None:
    """告警:冷却去重 + dry-run 不发 + 发送失败不抛。"""
    calls: list[list[str]] = []
    original = ecn.run_cli

    def fake_run_cli(args, cwd=None):
        calls.append(list(args))
        return True, {"ok": True, "data": {"message_id": "om_x"}}

    ecn.run_cli = fake_run_cli
    try:
        a = ecn.Alerter(enabled=True, known={})
        check("首次告警发出", a.notify("抄送查询失败", "网络不通"), True)
        check("同类 20h 内不重复", a.notify("抄送查询失败", "网络不通"), False)
        check("实际只调了一次 CLI", len(calls), 1)
        check("发的是私聊接口", calls[0][:4], ["im", "+messages-send", "--user-id", ecn.ALERT_USER_ID])
        check("收件人是 Bill", ecn.ALERT_USER_ID.startswith("ou_"), True)
        check("告警记录落状态", "抄送查询失败" in a.state(), True)

        # 冷却期内的历史记录来自状态文件 → 也不能重复报
        old = (dt.datetime.now() - dt.timedelta(hours=1)).isoformat(timespec="seconds")
        cooled = ecn.Alerter(enabled=True, known={"抄送查询失败": old})
        check("历史记录参与冷却", cooled.notify("抄送查询失败", "x"), False)

        expired = (dt.datetime.now() - dt.timedelta(hours=30)).isoformat(timespec="seconds")
        fresh = ecn.Alerter(enabled=True, known={"抄送查询失败": expired})
        check("超过冷却期可以再报", fresh.notify("抄送查询失败", "x"), True)

        # enabled=False(dry-run / --no-alert)一律不发
        before = len(calls)
        off = ecn.Alerter(enabled=False, known={})
        check("关掉告警不发", off.notify("脚本异常退出", "x"), False)
        check("关掉告警不调 CLI", len(calls), before)

        # CLI 报错时不能抛,也不能写冷却记录
        def failing(args, cwd=None):
            calls.append(list(args))
            return False, "send failed"

        ecn.run_cli = failing
        err = ecn.Alerter(enabled=True, known={})
        check("发送失败不抛", err.notify("简报发送失败", "x"), False)
        check("发送失败不记冷却", err.state(), {})
    finally:
        ecn.run_cli = original


def test_render_without_failure_note() -> None:
    """没有失败条目时不要多出「异常说明」一行。"""
    items = [{
        "instance_code": "X", "serial": "202609100225", "ecn_no": "ECN2609100002",
        "submitter": "", "change": "变更", "packaging": "", "attachments": [],
    }]
    start = dt.datetime(2026, 9, 10, 10, 55)
    end = dt.datetime(2026, 9, 11, 10, 55)
    text = ecn.render(items, [], start, end)
    check("无失败不写异常说明", "异常说明" in text, False)


if __name__ == "__main__":
    test_pick_task_fields()
    test_parse_form_and_scrape()
    test_form_not_json()
    test_timeline_files()
    test_dedup_attachments()
    test_json_objects()
    test_render()
    test_render_without_failure_note()
    test_clean_text()
    test_display_id()
    test_filename_from_disposition()
    test_unique_path()
    test_merge_state()
    test_resolve_window_start()
    test_parse_ts()
    test_state_roundtrip()
    test_classify_error()
    test_alerter()
    print()
    if FAILED:
        print(f"{len(FAILED)} 项失败: {', '.join(FAILED)}")
        sys.exit(1)
    print(f"全部通过({PASS_COUNT} 项)")
