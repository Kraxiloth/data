import json
import hashlib
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

API_URL = "https://api.sorcerytcg.com/api/cards"

ROOT = Path(__file__).resolve().parent.parent
CARDS_FILE = ROOT / "cards.json"
META_FILE = ROOT / "cards-meta.json"


def now_iso():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def load_json(path):
    if not path.exists():
        return None

    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def fetch_cards():
    request = urllib.request.Request(
        API_URL,
        headers={
            "User-Agent": "Sorcery-Data-Snapshot/1.0"
        }
    )

    with urllib.request.urlopen(request, timeout=30) as response:
        if response.status != 200:
            raise RuntimeError(
                f"API returned HTTP {response.status}"
            )

        return json.load(response)


def validate_cards(cards, previous_cards=None):
    if not isinstance(cards, list):
        raise RuntimeError("API response is not an array.")

    if not cards:
        raise RuntimeError("API returned an empty card list.")

    required = {"id", "name", "engine", "printings"}

    for i, card in enumerate(cards):
        if not isinstance(card, dict):
            raise RuntimeError(f"Card {i} is not an object.")

        missing = required - card.keys()

        if missing:
            raise RuntimeError(
                f"Card {i} ({card.get('name', 'unknown')}) "
                f"is missing: {', '.join(sorted(missing))}"
            )

        if not isinstance(card["printings"], list):
            raise RuntimeError(
                f"Card {i} has invalid printings data."
            )

    # Sanity check against the previous snapshot.
    if previous_cards:
        previous_count = len(previous_cards)
        minimum = int(previous_count * 0.90)

        if len(cards) < minimum:
            raise RuntimeError(
                f"Suspicious card-count reduction: "
                f"{previous_count} -> {len(cards)}"
            )


def canonical_bytes(cards):
    """
    Stable representation used for change detection.

    This does NOT determine how cards.json itself is formatted.
    """
    return json.dumps(
        cards,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":")
    ).encode("utf-8")


def calculate_hash(cards):
    return hashlib.sha256(canonical_bytes(cards)).hexdigest()


def printing_count(cards):
    return sum(
        len(card.get("printings", []))
        for card in cards
    )


def main():
    previous_cards = load_json(CARDS_FILE)
    previous_meta = load_json(META_FILE) or {}

    cards = fetch_cards()

    validate_cards(cards, previous_cards)

    new_hash = calculate_hash(cards)

    old_hash = (
        calculate_hash(previous_cards)
        if previous_cards
        else None
    )

    checked_at = now_iso()
    changed = new_hash != old_hash

    if changed:
        updated_at = checked_at

        # Human-readable JSON for your other applications.
        with CARDS_FILE.open("w", encoding="utf-8") as f:
            json.dump(
                cards,
                f,
                ensure_ascii=False,
                indent=2
            )
            f.write("\n")

        print(
            f"Catalogue changed: "
            f"{len(cards)} cards, "
            f"{printing_count(cards)} printings."
        )
    else:
        updated_at = previous_meta.get(
            "updatedAt",
            checked_at
        )

        print("No catalogue changes.")

    meta = {
        "schemaVersion": 1,
        "checkedAt": checked_at,
        "updatedAt": updated_at,
        "cardCount": len(cards),
        "printingCount": printing_count(cards),
        "catalogueRevision": f"sha256:{new_hash}"
    }

    with META_FILE.open("w", encoding="utf-8") as f:
        json.dump(
            meta,
            f,
            ensure_ascii=False,
            indent=2
        )
        f.write("\n")


if __name__ == "__main__":
    main()
