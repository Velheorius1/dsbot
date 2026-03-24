#!/usr/bin/env python3
"""DSBot Briefings — standalone cron script.

Usage:
    python3 send_briefing.py morning   # 07:00 — план на день
    python3 send_briefing.py midday    # 12:00 — напоминание (молчит если всё ок)
    python3 send_briefing.py evening   # 21:00 — итоги дня
    python3 send_briefing.py weekly    # Вс 20:00 — итоги недели
"""

import sys
import os
import json
import subprocess
from datetime import date, timedelta

# Add scripts dir to path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from planner_utils import (
    parse_tasks, get_overdue, get_today, get_delegated,
    count_done_today, count_done_week,
    bitrix_overdue_deals, bitrix_stale_deals,
    bitrix_call, STAGE_NAMES, PRODUCTION_STAGES,
    send_telegram,
)

def get_bitrix_digest():
    """Daily CRM digest: new deals, moved deals, stale deals."""
    yesterday = (date.today() - timedelta(days=1)).strftime("%Y-%m-%dT00:00:00")
    today_str = date.today().strftime("%Y-%m-%dT00:00:00")
    digest_lines = []

    try:
        # New deals created yesterday
        new_resp = bitrix_call("crm.deal.list", {
            "filter": {
                "CATEGORY_ID": 1,
                ">=DATE_CREATE": yesterday,
                "<DATE_CREATE": today_str,
            },
            "select": ["ID", "TITLE", "OPPORTUNITY", "UF_CRM_1733324324"],
        })
        new_deals = new_resp.get("result", [])
        if new_deals:
            total = sum(float(d.get("OPPORTUNITY", 0) or 0) for d in new_deals)
            digest_lines.append("  \u2795 Новых: {} ({:,.0f} сум)".format(len(new_deals), total))
            for d in new_deals[:3]:
                title = d.get("UF_CRM_1733324324") or d.get("TITLE", "")
                digest_lines.append("    \u2022 {}".format(title[:50]))

        # Deals that moved stages yesterday (DATE_MODIFY yesterday, different stage)
        moved_resp = bitrix_call("crm.deal.list", {
            "filter": {
                "CATEGORY_ID": 1,
                ">=DATE_MODIFY": yesterday,
                "<DATE_MODIFY": today_str,
                "!STAGE_ID": ["C1:WON", "C1:LOSE"],
            },
            "select": ["ID", "TITLE", "STAGE_ID", "UF_CRM_1733324324"],
        })
        moved_deals = moved_resp.get("result", [])
        # Exclude new deals (they were just created, not moved)
        new_ids = set(d.get("ID") for d in new_deals) if new_deals else set()
        moved_only = [d for d in moved_deals if d.get("ID") not in new_ids]
        if moved_only:
            digest_lines.append("  \u27A1\uFE0F Двигались: {}".format(len(moved_only)))
            for d in moved_only[:3]:
                title = d.get("UF_CRM_1733324324") or d.get("TITLE", "")
                stage = STAGE_NAMES.get(d.get("STAGE_ID", ""), d.get("STAGE_ID", ""))
                digest_lines.append("    \u2022 {} \u2192 {}".format(title[:35], stage))

        # Stale deals (>5 days without movement)
        stale = bitrix_stale_deals(days=5)
        if stale:
            digest_lines.append("  \u23F3 Зависли (>5д): {}".format(len(stale)))
            for d in stale[:3]:
                digest_lines.append("    \u2022 {} ({}, {}д)".format(
                    d["title"][:35], d["stage"], d["days_stale"]
                ))

        # Won/lost yesterday
        won_resp = bitrix_call("crm.deal.list", {
            "filter": {
                "CATEGORY_ID": 1, "STAGE_ID": "C1:WON",
                ">=CLOSEDATE": yesterday, "<CLOSEDATE": today_str,
            },
            "select": ["ID", "OPPORTUNITY"],
        })
        lost_resp = bitrix_call("crm.deal.list", {
            "filter": {
                "CATEGORY_ID": 1, "STAGE_ID": "C1:LOSE",
                ">=CLOSEDATE": yesterday, "<CLOSEDATE": today_str,
            },
            "select": ["ID"],
        })
        won = won_resp.get("result", [])
        lost = lost_resp.get("result", [])
        if won or lost:
            parts = []
            if won:
                won_sum = sum(float(d.get("OPPORTUNITY", 0) or 0) for d in won)
                parts.append("\u2705 {} won ({:,.0f})".format(len(won), won_sum))
            if lost:
                parts.append("\u274C {} lost".format(len(lost)))
            digest_lines.append("  {}".format(" | ".join(parts)))

    except Exception as e:
        print("Bitrix digest: {}".format(e), file=sys.stderr)

    return digest_lines


def get_salesbot_stats(report_date=None):
    """Get SalesBot daily stats from salesbot container."""
    if report_date is None:
        report_date = date.today().isoformat()
    try:
        cmd = [
            "docker", "exec", "salesbot", "python3", "-c",
            "from bot.conversation import init_db, get_daily_stats; "
            "import json; "
            "init_db(); "
            "stats = get_daily_stats('{}'); ".format(report_date) +
            "print(json.dumps(stats))"
        ]
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        if result.returncode == 0 and result.stdout.strip():
            return json.loads(result.stdout.strip())
    except Exception as e:
        print("SalesBot stats: {}".format(e), file=sys.stderr)
    return None


def get_salesbot_weekly_stats():
    """Get SalesBot stats for the past 7 days."""
    totals = {"conversations": 0, "messages": 0, "user_messages": 0,
              "escalations": 0, "follow_ups_total": 0, "days_with_data": 0}
    for i in range(7):
        d = (date.today() - timedelta(days=i)).isoformat()
        stats = get_salesbot_stats(d)
        if stats and stats.get("conversations", 0) > 0:
            totals["conversations"] += stats["conversations"]
            totals["messages"] += stats.get("messages", 0)
            totals["user_messages"] += stats.get("user_messages", 0)
            totals["escalations"] += stats.get("escalations", 0)
            totals["days_with_data"] += 1
    # follow_ups_total is cumulative, take latest
    latest = get_salesbot_stats()
    if latest:
        totals["follow_ups_total"] = latest.get("follow_ups_total", 0)
    return totals if totals["days_with_data"] > 0 else None


def get_production_summary(report_date=None):
    """Get production summary from winch-bot container."""
    if report_date is None:
        # Yesterday's report (today's not ready yet at 07:00)
        report_date = (date.today() - timedelta(days=1)).isoformat()
    try:
        cmd = [
            "docker", "exec", "winch-bot", "python3", "-c",
            "import json; "
            "f=open('/app/data/calculated/report_{}.json'); ".format(report_date) +
            "d=json.load(f); "
            "print(json.dumps({"
            "'kpi': d.get('production_kpi', 0), "
            "'workers': len(d.get('workers', [])), "
            "'warnings': len(d.get('warnings', [])), "
            "'total_salary': d.get('total_salary_adjusted', 0), "
            "'top_warnings': d.get('warnings', [])[:3], "
            "'low_kpi': [{'name': w['name'], 'kpi': w.get('kpi',0)} "
            "for w in d.get('workers', []) if w.get('kpi',0) < 50 and w.get('kpi',0) > 0][:3], "
            "'high_kpi': [{'name': w['name'], 'kpi': w.get('kpi',0)} "
            "for w in d.get('workers', []) if w.get('kpi',0) > 200][:3]"
            "}))"
        ]
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        if result.returncode == 0 and result.stdout.strip():
            return json.loads(result.stdout.strip())
    except Exception as e:
        print("Production: {}".format(e), file=sys.stderr)
    return None


CAT_EMOJI = {
    "бизнес": "\U0001F4BC",
    "личное": "\U0001F3E0",
    "обучение": "\U0001F4DA",
    "здоровье": "\U0001F4AA",
    "делегирование": "\U0001F465",
}
PRI_EMOJI = {1: "\U0001F534", 2: "\U0001F7E1", 3: "\U0001F7E2"}


def morning():
    """07:00 — план на день + просроченные + Bitrix."""
    tasks = parse_tasks()
    today_tasks = get_today(tasks)
    overdue = get_overdue(tasks)
    delegated = get_delegated(tasks)

    lines = [
        "\u2600\uFE0F *Доброе утро! План на {}*\n".format(
            date.today().strftime("%d.%m.%Y")
        )
    ]

    # Просроченные — ПЕРВЫМИ
    if overdue:
        lines.append("\u23F0 *Просрочено: {}*".format(len(overdue)))
        for t in sorted(overdue, key=lambda x: x["priority"])[:5]:
            days = (date.today() - date.fromisoformat(t["due_date"])).days
            pri = PRI_EMOJI.get(t["priority"], "")
            lines.append("  \u26A0\uFE0F #{} {} ({}д) {}".format(
                t["id"], t["text"], days, pri
            ))
        if len(overdue) > 5:
            lines.append("  ... и ещё {}".format(len(overdue) - 5))
        lines.append("")

    # Задачи на сегодня
    if today_tasks:
        lines.append("\U0001F4CB *На сегодня: {}*".format(len(today_tasks)))
        for i, t in enumerate(today_tasks, 1):
            pri = PRI_EMOJI.get(t["priority"], "")
            cat = CAT_EMOJI.get(t["category"], "")
            lines.append("  {}. #{} {} {}{}".format(i, t["id"], t["text"], pri, cat))
    else:
        lines.append("\U0001F4CB На сегодня задач нет")

    # Делегированные
    if delegated:
        lines.append("\n\U0001F4E4 *Делегировано: {}*".format(len(delegated)))
        for t in delegated[:3]:
            lines.append("  \u2192 {}: #{}  {}".format(
                t["delegate_to"] or "?", t["id"], t["text"]
            ))

    # Календарь — события на сегодня
    try:
        from calendar_utils import get_events_today, format_events_telegram
        cal_events = get_events_today()
        if cal_events:
            lines.append("")
            lines.append(format_events_telegram(cal_events, title="\U0001F4C5 Календарь на сегодня"))
    except Exception as e:
        print("Calendar: {}".format(e), file=sys.stderr)

    # Bitrix — просроченные сделки
    try:
        overdue_deals = bitrix_overdue_deals()
        if overdue_deals > 0:
            lines.append(
                "\n\U0001F525 *CRM: {} сделок с просроченным дедлайном*".format(overdue_deals)
            )
    except Exception:
        pass

    # Производство — вчерашние итоги
    prod = get_production_summary()
    if prod and prod.get("workers", 0) > 0:
        kpi = prod["kpi"]
        if kpi < 10:
            kpi = kpi * 100  # normalize 0.93 -> 93
        lines.append("\n\U0001F3ED *Производство вчера:*")
        lines.append("  Отчитались: {} чел, KPI: {:.0f}%".format(
            prod["workers"], kpi
        ))
        if prod.get("low_kpi"):
            low = ", ".join("{} ({:.0f}%)".format(w["name"], w["kpi"]) for w in prod["low_kpi"])
            lines.append("  \u26A0\uFE0F Низкий KPI: {}".format(low))
        if prod.get("high_kpi"):
            high = ", ".join("{} ({:.0f}%)".format(w["name"], w["kpi"]) for w in prod["high_kpi"])
            lines.append("  \U0001F4A5 Аномально высокий: {}".format(high))
        if prod.get("warnings"):
            lines.append("  \u26A0\uFE0F {} предупреждений".format(prod["warnings"]))

    # SalesBot — вчерашние продажи через бота
    yesterday_str = (date.today() - timedelta(days=1)).isoformat()
    sales = get_salesbot_stats(yesterday_str)
    if sales and sales.get("conversations", 0) > 0:
        lines.append("\n\U0001F916 *SalesBot вчера:*")
        lines.append("  Диалогов: {}, сообщений: {}".format(
            sales["conversations"], sales.get("messages", 0)
        ))
        if sales.get("escalations", 0) > 0:
            lines.append("  \u26A0\uFE0F Эскалаций: {}".format(sales["escalations"]))
        if sales.get("follow_ups_total", 0) > 0:
            lines.append("  \U0001F501 Follow-up: {}".format(sales["follow_ups_total"]))

    # Битрикс-дайджест — новые, двигались, зависли
    digest = get_bitrix_digest()
    if digest:
        lines.append("\n\U0001F4CA *CRM дайджест:*")
        lines.extend(digest)

    # Фокус дня — топ-3 приоритета
    focus_items = sorted(overdue, key=lambda x: x["priority"])[:2]
    focus_items += sorted(today_tasks, key=lambda x: x["priority"])[:1]
    if focus_items:
        lines.append("\n\U0001F3AF *Фокус дня:*")
        for i, t in enumerate(focus_items[:3], 1):
            lines.append("  {}. #{}  {}".format(i, t["id"], t["text"]))

    send_telegram("\n".join(lines))


def midday():
    """12:00 — напоминание о просроченных. Молчит если всё ок."""
    tasks = parse_tasks()
    overdue = get_overdue(tasks)

    if not overdue:
        return  # Тишина — значит всё хорошо

    # Самая старая просроченная P1
    p1 = [t for t in overdue if t["priority"] == 1]
    target = p1[0] if p1 else overdue[0]
    days = (date.today() - date.fromisoformat(target["due_date"])).days

    text = "\U0001F514 *Напоминание*\n\n"
    text += "Просроченных задач: {}\n".format(len(overdue))
    text += "Самая важная: *#{}  {}* ({}д)\n".format(
        target["id"], target["text"], days
    )
    if target["notes"]:
        text += "Заметки: {}".format(target["notes"])

    send_telegram(text)


def evening():
    """21:00 — итоги дня."""
    tasks = parse_tasks()
    overdue = get_overdue(tasks)
    done_count = count_done_today()
    active = [t for t in tasks if t["status"] in ("todo", "delegated")]

    lines = ["\U0001F319 *Итоги дня — {}*\n".format(date.today().strftime("%d.%m.%Y"))]

    # Статистика
    lines.append("\u2705 Выполнено сегодня: {}".format(done_count))
    lines.append("\U0001F4CB Активных задач: {}".format(len(active)))
    if overdue:
        lines.append("\u26A0\uFE0F Просрочено: {}".format(len(overdue)))

    # SalesBot — итоги за сегодня
    sales = get_salesbot_stats()
    if sales and sales.get("conversations", 0) > 0:
        lines.append("\n\U0001F916 *SalesBot сегодня:*")
        lines.append("  Диалогов: {}, сообщений: {}".format(
            sales["conversations"], sales.get("messages", 0)
        ))
        if sales.get("escalations", 0) > 0:
            lines.append("  \u26A0\uFE0F Эскалаций: {}".format(sales["escalations"]))

    # Что не сделано из сегодняшних
    today_tasks = get_today(tasks)
    if today_tasks:
        lines.append("\n\U0001F4CC *Не выполнено сегодня:*")
        for t in today_tasks:
            lines.append("  \u2022 #{} {}".format(t["id"], t["text"]))

    # Рекомендация на завтра
    if overdue:
        top = sorted(overdue, key=lambda x: x["priority"])[0]
        lines.append("\n\U0001F3AF *На завтра в первую очередь:*")
        lines.append("  #{} {}".format(top["id"], top["text"]))

    send_telegram("\n".join(lines))


def weekly():
    """Вс 20:00 — итоги недели."""
    tasks = parse_tasks()
    overdue = get_overdue(tasks)
    done_count = count_done_week()
    active = [t for t in tasks if t["status"] in ("todo", "delegated")]

    lines = ["\U0001F4CA *Итоги недели*\n"]

    # Статистика
    lines.append("\u2705 Выполнено за неделю: {}".format(done_count))
    lines.append("\U0001F4CB Активных задач: {}".format(len(active)))
    if overdue:
        lines.append("\u26A0\uFE0F Просрочено: {}".format(len(overdue)))

    # По категориям
    categories = {}
    for t in active:
        cat = t["category"] or "без категории"
        categories[cat] = categories.get(cat, 0) + 1
    if categories:
        lines.append("\n*По категориям:*")
        for cat, count in sorted(categories.items(), key=lambda x: -x[1]):
            emoji = CAT_EMOJI.get(cat, "\U0001F4CC")
            lines.append("  {} {}: {}".format(emoji, cat, count))

    # Битрикс
    try:
        stale = bitrix_stale_deals(days=5)
        if stale:
            lines.append("\n\u23F3 *Bitrix — без движения >5д: {}*".format(len(stale)))
            for d in stale[:3]:
                lines.append("  \u2022 {} ({}, {}д)".format(
                    d["title"], d["stage"], d["days_stale"]
                ))
    except Exception:
        pass

    # Производство за неделю
    week_prod = []
    for i in range(7):
        d = (date.today() - timedelta(days=i)).isoformat()
        p = get_production_summary(d)
        if p and p.get("workers", 0) > 0:
            kpi = p["kpi"]
            if kpi < 10:
                kpi = kpi * 100
            week_prod.append({"date": d, "kpi": kpi, "workers": p["workers"]})
    if week_prod:
        avg_kpi = sum(p["kpi"] for p in week_prod) / len(week_prod)
        avg_workers = sum(p["workers"] for p in week_prod) / len(week_prod)
        lines.append("\n\U0001F3ED *Производство за неделю:*")
        lines.append("  Рабочих дней с отчётами: {}".format(len(week_prod)))
        lines.append("  Средний KPI: {:.0f}%".format(avg_kpi))
        lines.append("  Среднее кол-во рабочих: {:.0f}".format(avg_workers))

    # Win/Loss анализ
    try:
        week_start = (date.today() - timedelta(days=7)).strftime("%Y-%m-%dT00:00:00")
        won_resp = bitrix_call("crm.deal.list", {
            "filter": {"CATEGORY_ID": 1, "STAGE_ID": "C1:WON",
                        ">=CLOSEDATE": week_start},
            "select": ["ID", "OPPORTUNITY"],
        })
        lost_resp = bitrix_call("crm.deal.list", {
            "filter": {"CATEGORY_ID": 1, "STAGE_ID": "C1:LOSE",
                        ">=CLOSEDATE": week_start},
            "select": ["ID", "TITLE", "OPPORTUNITY"],
        })
        won_deals = won_resp.get("result", [])
        lost_deals = lost_resp.get("result", [])
        if won_deals or lost_deals:
            won_total = sum(float(d.get("OPPORTUNITY", 0) or 0) for d in won_deals)
            parts = []
            if won_deals:
                parts.append("{} won ({:,.0f} сум)".format(len(won_deals), won_total))
            if lost_deals:
                parts.append("{} lost".format(len(lost_deals)))
            lines.append("\n\U0001F4C8 *Продажи:* {}".format(", ".join(parts)))
            for d in lost_deals[:3]:
                lines.append("  \u2022 {} — {}".format(
                    d.get("TITLE", "?")[:40],
                    d.get("UF_CRM_LOSS_REASON", "причина не указана"),
                ))
    except Exception as e:
        print("Win/Loss: {}".format(e), file=sys.stderr)

    # Pipeline Velocity
    try:
        pipe_resp = bitrix_call("crm.deal.list", {
            "filter": {"CATEGORY_ID": 1,
                        "STAGE_ID": PRODUCTION_STAGES},
            "select": ["ID", "STAGE_ID"],
        })
        pipe_deals = pipe_resp.get("result", [])
        if pipe_deals:
            stage_counts = {}  # type: dict
            for d in pipe_deals:
                sid = d.get("STAGE_ID", "")
                stage_counts[sid] = stage_counts.get(sid, 0) + 1
            bottleneck_id = max(stage_counts, key=lambda k: stage_counts[k])
            bottleneck_name = STAGE_NAMES.get(bottleneck_id, bottleneck_id)
            lines.append("\U0001F4CA *Pipeline:* {} сделок. Bottleneck: {} ({} сделок)".format(
                len(pipe_deals), bottleneck_name, stage_counts[bottleneck_id]
            ))
    except Exception as e:
        print("Pipeline: {}".format(e), file=sys.stderr)

    # SalesBot за неделю
    sales_week = get_salesbot_weekly_stats()
    if sales_week:
        lines.append("\n\U0001F916 *SalesBot за неделю:*")
        lines.append("  Диалогов: {}, сообщений: {}".format(
            sales_week["conversations"], sales_week["messages"]
        ))
        if sales_week["escalations"] > 0:
            lines.append("  \u26A0\uFE0F Эскалаций: {}".format(sales_week["escalations"]))
        if sales_week["follow_ups_total"] > 0:
            lines.append("  \U0001F501 Активных follow-up: {}".format(sales_week["follow_ups_total"]))
        lines.append("  Дней с активностью: {}/7".format(sales_week["days_with_data"]))

    # Просроченные P1
    p1_overdue = [t for t in overdue if t["priority"] == 1]
    if p1_overdue:
        lines.append("\n\U0001F534 *P1 просрочены:*")
        for t in p1_overdue:
            days = (date.today() - date.fromisoformat(t["due_date"])).days
            lines.append("  \u2022 #{} {} ({}д)".format(t["id"], t["text"], days))

    send_telegram("\n".join(lines))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 send_briefing.py [morning|midday|evening|weekly]")
        sys.exit(1)

    cmd = sys.argv[1]
    handlers = {
        "morning": morning,
        "midday": midday,
        "evening": evening,
        "weekly": weekly,
    }

    if cmd not in handlers:
        print("Unknown briefing type: {}. Use: morning|midday|evening|weekly".format(cmd))
        sys.exit(1)

    handlers[cmd]()
