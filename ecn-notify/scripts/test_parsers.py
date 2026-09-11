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


def check(name: str, got, want) -> None:
    if got == want:
        print(f"PASS {name}")
    else:
        FAILED.append(name)
        print(f"FAIL {name}\n  got : {got!r}\n  want: {want!r}")


def test_pick_task_fields() -> None:
    task = {
        "process_code": "ECN2601010002",
        "title": "ECN 变更通知",
        "status": "Todo",
        "topic": "17",
    }
    got = ecn.pick_task_fields(task)
    check("process_code 优先", got["instance_code"], "ECN2601010002")
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
            {"id": "w1", "name": "变更内容", "type": "textarea", "value": "示例变更内容 A"},
            {"id": "w2", "name": "关联包材", "type": "textarea", "value": "示例包材 A, 示例包材 B"},
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
    body = {"form": form, "approval_name": "ECN 变更通知", "serial_number": "2026010100003"}
    items = ecn.parse_form(body)
    check("form 解析出控件数", len(items), 3)
    check(
        "取变更内容",
        ecn.scrape_item_value(items, ["变更内容"]),
        "示例变更内容 A",
    )
    check("取关联包材", ecn.scrape_item_value(items, ["关联包材", "包材"]), "示例包材 A, 示例包材 B")
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
            "instance_code": "11111111-1111-4111-8111-111111111111",
            "serial": "2026010100225",
            "ecn_no": "ECN2601010001",
            "submitter": "示例发起人",
            "change": "BOM 搭建",
            "packaging": "示例包材 A, 示例包材 B",
            "attachments": [{"value": "u", "label": ""}],
        },
        {
            "instance_code": "22222222-2222-4222-8222-222222222222",
            "serial": "2026010100049",
            "ecn_no": "B010000001 B010000002",  # 不是 ECN 号 → 退回审批单号
            "submitter": "",
            "change": "示例变更内容 B",
            "packaging": "",
            "attachments": [],
        },
    ]
    start = dt.datetime(2026, 1, 1, 10, 55)
    end = dt.datetime(2026, 1, 2, 10, 55)
    text = ecn.render(items, ["ECN2601010003"], start, end)
    lines = text.splitlines()
    check("标题=日期+分钟级时间区间", lines[0], "📋 ECN 发布通知 · 2026-01-01 10:55 ~ 2026-01-02 10:55")
    check("条数", lines[1], "过去 24 小时新增 2 条")
    check("条目 1 只留变更编号", lines[3], "1. ECN2601010001")
    check("条目 2 退回审批单号", "2. 2026010100049" in text, True)
    check("不出现 UUID", "11111111" not in text, True)
    check("不出现 open_id / 发起人", "示例发起人" not in text, True)
    check("删掉附件行", "附件" not in text, True)
    check("变更内容入文", "   • 变更内容:BOM 搭建" in text, True)
    check("空包材写「无」", "   • 关联包材:无" in text, True)
    check("异常说明入文", "ECN2601010003" in text, True)


def test_clean_text() -> None:
    check("表单提示文案当空", ecn.clean_text("非必填选项，产品经理填写"), "")
    check("真实内容保留", ecn.clean_text("示例包材 A, 示例包材 B"), "示例包材 A, 示例包材 B")
    check("「无」当空", ecn.clean_text("无"), "")
    check("以「无」开头的真实值不被误杀", ecn.clean_text("无尘车间专用包材"), "无尘车间专用包材")


def test_display_id() -> None:
    check(
        "变更编号优先",
        ecn.display_id({"ecn_no": "ecn2601010001", "serial": "2026010100225", "instance_code": "X"}),
        "ECN2601010001",
    )
    check(
        "变更编号非 ECN 形态 → 审批单号",
        ecn.display_id({"ecn_no": "B010000001", "serial": "2026010100049", "instance_code": "X"}),
        "2026010100049",
    )
    check(
        "变更编号乱填 → 用附件名里的 ECN 号",
        ecn.display_id(
            {
                "ecn_no": "B010000001 B010000002 B010000003",
                "serial": "2026010100049",
                "instance_code": "X",
                "attachments": [{"filename": "ECN2601010004.pdf", "local_path": None}],
            }
        ),
        "ECN2601010004",
    )
    check(
        "都没有才用 instance_code",
        ecn.display_id({"ecn_no": "", "serial": "0", "instance_code": "UUID-X"}),
        "UUID-X",
    )
    check(
        "下载兜底名:变更编号 → 单号 → 实例码",
        ecn.fallback_stem({"ecn_no": "", "serial": "2026010100049", "instance_code": "X"}),
        "2026010100049",
    )


def test_filename_from_disposition() -> None:
    # 飞书真实响应头(实测)
    check(
        "filename*=UTF-8 优先",
        ecn.filename_from_disposition(
            "attachment; filename=\"ECN2601010001.pdf\"; filename*=UTF-8''ECN2601010001.pdf",
            "fallback.pdf",
        ),
        "ECN2601010001.pdf",
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
    check("没有头就用兜底名", ecn.filename_from_disposition("", "ECN2601010001.pdf"), "ECN2601010001.pdf")
    traversal = ecn.safe_filename("../../etc/passwd")
    check("路径穿越:分隔符被清", "/" not in traversal and "\\" not in traversal, True)
    check("路径穿越:不以 . 开头", traversal.startswith("."), False)
    check(
        "带中文的兜底名",
        ecn.filename_from_disposition("attachment", "ECN2601010001.pdf"),
        "ECN2601010001.pdf",
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
    """--ignore-state 补发时写回也必须是并集,不能覆盖历史(旧版直接覆盖)。"""
    check("并集去重", ecn.merge_state(["a", "b"], ["b", "c"]), ["a", "b", "c"])
    check("空历史", ecn.merge_state([], ["x"]), ["x"])
    check("空新增保留历史", ecn.merge_state(["x"], []), ["x"])


if __name__ == "__main__":
    test_pick_task_fields()
    test_parse_form_and_scrape()
    test_form_not_json()
    test_timeline_files()
    test_dedup_attachments()
    test_json_objects()
    test_render()
    test_clean_text()
    test_display_id()
    test_filename_from_disposition()
    test_unique_path()
    test_merge_state()
    print()
    if FAILED:
        print(f"{len(FAILED)} 项失败: {', '.join(FAILED)}")
        sys.exit(1)
    print("全部通过")
