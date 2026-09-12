import json
from collections import defaultdict
from datetime import date, datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
CURRENT_FILE = ROOT / "prices.json"
HISTORY_ROOT = ROOT / "prices-history"
DAILY_DIR = HISTORY_ROOT / "daily"
WEEKLY_DIR = HISTORY_ROOT / "weekly"
MONTHLY_DIR = HISTORY_ROOT / "monthly"
YEARLY_DIR = HISTORY_ROOT / "yearly"

DAILY_RETENTION = 31
WEEKLY_RETENTION = 52


def read_json(path):
    with path.open("r", encoding="utf-8-sig") as handle:
        return json.load(handle)


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        json.dump(
            value,
            handle,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        )
        handle.write("\n")


def current_snapshot(cards, snapshot_date):
    prices = {}
    for card in cards:
        for printing in card.get("printings", []):
            price = printing.get("price")
            if not price or not isinstance(price.get("market"), (int, float)):
                continue
            prices[printing["slug"]] = {
                "market": price["market"],
                "low": price.get("low"),
            }

    if not prices:
        raise RuntimeError("prices.json contains no priced printings.")

    return {
        "schemaVersion": 1,
        "date": snapshot_date.isoformat(),
        "source": "TCGPlayer",
        "currency": "USD",
        "prices": prices,
    }


def load_daily_snapshots():
    snapshots = []
    for path in sorted(DAILY_DIR.glob("????-??-??.json")):
        snapshot = read_json(path)
        snapshots.append((date.fromisoformat(snapshot["date"]), snapshot))
    return snapshots


def summarize_daily(period, snapshots):
    values = defaultdict(lambda: {"market": [], "low": []})
    for _, snapshot in snapshots:
        for slug, price in snapshot["prices"].items():
            if isinstance(price.get("market"), (int, float)):
                values[slug]["market"].append(price["market"])
            if isinstance(price.get("low"), (int, float)):
                values[slug]["low"].append(price["low"])

    return {
        "schemaVersion": 1,
        "period": period,
        "startDate": min(day for day, _ in snapshots).isoformat(),
        "endDate": max(day for day, _ in snapshots).isoformat(),
        "source": "TCGPlayer",
        "currency": "USD",
        "prices": {
            slug: {
                metric: {
                    "average": round(sum(items) / len(items), 4),
                    "minimum": min(items),
                    "maximum": max(items),
                    "observations": len(items),
                }
                for metric, items in metrics.items()
                if items
            }
            for slug, metrics in values.items()
        },
    }


def summarize_summaries(period, summaries):
    values = defaultdict(
        lambda: defaultdict(lambda: {"weightedSum": 0.0, "observations": 0, "minimum": None, "maximum": None})
    )
    for summary in summaries:
        for slug, metrics in summary["prices"].items():
            for metric, stats in metrics.items():
                target = values[slug][metric]
                count = stats["observations"]
                target["weightedSum"] += stats["average"] * count
                target["observations"] += count
                target["minimum"] = stats["minimum"] if target["minimum"] is None else min(target["minimum"], stats["minimum"])
                target["maximum"] = stats["maximum"] if target["maximum"] is None else max(target["maximum"], stats["maximum"])

    return {
        "schemaVersion": 1,
        "period": period,
        "startDate": min(item["startDate"] for item in summaries),
        "endDate": max(item["endDate"] for item in summaries),
        "source": "TCGPlayer",
        "currency": "USD",
        "prices": {
            slug: {
                metric: {
                    "average": round(stats["weightedSum"] / stats["observations"], 4),
                    "minimum": stats["minimum"],
                    "maximum": stats["maximum"],
                    "observations": stats["observations"],
                }
                for metric, stats in metrics.items()
            }
            for slug, metrics in values.items()
        },
    }


def remove_old_files(directory, pattern, retain):
    paths = sorted(directory.glob(pattern))
    for path in paths[:-retain]:
        path.unlink()


def main():
    today = datetime.now(timezone.utc).date()
    cards = read_json(CURRENT_FILE)

    write_json(DAILY_DIR / f"{today.isoformat()}.json", current_snapshot(cards, today))
    daily = load_daily_snapshots()

    weeks = defaultdict(list)
    months = defaultdict(list)
    for day, snapshot in daily:
        iso_year, iso_week, _ = day.isocalendar()
        weeks[f"{iso_year}-W{iso_week:02d}"].append((day, snapshot))
        months[day.strftime("%Y-%m")].append((day, snapshot))

    iso_year, iso_week, _ = today.isocalendar()
    current_week = f"{iso_year}-W{iso_week:02d}"
    current_month = today.strftime("%Y-%m")

    # Only rewrite active periods. Recomputing older periods after their first
    # daily observations have expired would silently turn complete summaries
    # into partial ones.
    write_json(
        WEEKLY_DIR / f"{current_week}.json",
        summarize_daily(current_week, weeks[current_week]),
    )
    write_json(
        MONTHLY_DIR / f"{current_month}.json",
        summarize_daily(current_month, months[current_month]),
    )

    remove_old_files(DAILY_DIR, "????-??-??.json", DAILY_RETENTION)
    remove_old_files(WEEKLY_DIR, "????-W??.json", WEEKLY_RETENTION)

    months_by_year = defaultdict(list)
    for path in sorted(MONTHLY_DIR.glob("????-??.json")):
        summary = read_json(path)
        months_by_year[summary["period"][:4]].append(summary)
    for year, summaries in months_by_year.items():
        write_json(YEARLY_DIR / f"{year}.json", summarize_summaries(year, summaries))

    print(
        f"History updated: {len(list(DAILY_DIR.glob('*.json')))} daily, "
        f"{len(list(WEEKLY_DIR.glob('*.json')))} weekly, "
        f"{len(list(MONTHLY_DIR.glob('*.json')))} monthly, and "
        f"{len(list(YEARLY_DIR.glob('*.json')))} yearly files."
    )


if __name__ == "__main__":
    main()
