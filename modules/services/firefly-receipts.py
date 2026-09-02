#!/usr/bin/env python3
"""Read receipt photos with a local vision model and file them into Firefly III.

Runs as a one-shot batch over a spool directory, in two independent stages:

  inbox/   -> pending/   a vision model reads the image; the extracted fields land beside it
  pending/ -> done/      the extraction is posted to Firefly III as a transaction

Splitting them is what lets the queue work before Firefly III has an API token: stage one still
runs, and everything it reads waits in pending/ until a token shows up and stage two drains the
backlog. Anything that fails is moved to failed/ with a .error note rather than being retried
forever, so one unreadable photo can't wedge the queue.
"""

import base64
import hashlib
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import date, datetime
from pathlib import Path

OLLAMA_URL = os.environ["RECEIPTS_OLLAMA_URL"]
MODEL = os.environ["RECEIPTS_MODEL"]
SPOOL = Path(os.environ["RECEIPTS_SPOOL_DIR"])
FIREFLY_URL = os.environ["RECEIPTS_FIREFLY_URL"]
TOKEN_FILE = os.environ.get("RECEIPTS_TOKEN_FILE", "")
ASSET_ACCOUNT = os.environ.get("RECEIPTS_ASSET_ACCOUNT", "")
CURRENCY = os.environ.get("RECEIPTS_CURRENCY", "EUR")
TAG = os.environ.get("RECEIPTS_TAG", "receipt-import")
SETTLE_SECONDS = int(os.environ.get("RECEIPTS_SETTLE_SECONDS", "20"))
MAX_PIXELS = os.environ.get("RECEIPTS_MAX_PIXELS", "1600")
HTTP_TIMEOUT = int(os.environ.get("RECEIPTS_HTTP_TIMEOUT", "1800"))
MAGICK = os.environ.get("RECEIPTS_MAGICK", "magick")

INBOX, PENDING, DONE, FAILED = (SPOOL / d for d in ("inbox", "pending", "done", "failed"))

IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png", ".webp", ".heic", ".heif", ".gif", ".bmp", ".tif", ".tiff", ".pdf"}

# Ollama enforces this as a grammar during decoding, so the reply parses as JSON by construction
# and there is no prose to strip. Everything optional is still declared, so the model has a slot
# to put a value in rather than inventing a key.
SCHEMA = {
    "type": "object",
    "properties": {
        "merchant": {"type": "string"},
        "date": {"type": "string"},
        "total": {"type": "number"},
        "currency": {"type": "string"},
        "category": {"type": "string"},
        "payment_method": {"type": "string"},
        "items": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {"name": {"type": "string"}, "price": {"type": "number"}},
                "required": ["name", "price"],
            },
        },
    },
    "required": ["merchant", "date", "total", "currency"],
}

PROMPT = f"""You are reading a photograph of a purchase receipt. It may be in any language.
Extract these fields:

- merchant: the shop or company name printed on the receipt.
- date: the purchase date as YYYY-MM-DD. If the year is missing, assume {date.today().year}.
  If no date is printed at all, use {date.today().isoformat()}.
- total: the grand total actually paid, as a number. It is normally the largest money figure on
  the receipt, after any discount and including tax. It is NOT a subtotal, NOT a tax or VAT line
  (BTW, AFA, MwSt, TVA, IVA), NOT the cash tendered and NOT the change given; a tax line sits
  near the total but is much smaller, so check which is which before answering. Digits may be
  grouped with spaces, dots or commas: "2 720" and "2.720" both mean 2720, while "27,65" and
  "27.65" both mean 27.65.
- currency: the ISO 4217 code, e.g. EUR, USD, HUF. If no symbol or code is visible, use {CURRENCY}.
- category: a short spending category such as groceries, restaurant, fuel, transport, pharmacy.
- payment_method: "cash" or "card", whichever the receipt says it was paid with. Words such as
  KESZPENZ, BAR, ESPECES, CONTANTI mean cash; PINPAS, KARTYA, CARTE, EC mean card.
- items: the individual line items with the price charged for each line, if they are legible.

Report only what is actually printed on the receipt. Do not guess at values you cannot read."""


def log(msg):
    print(msg, flush=True)


def request_json(url, payload=None, headers=None, method=None, timeout=HTTP_TIMEOUT):
    body = None if payload is None else json.dumps(payload).encode()
    hdrs = {"Accept": "application/json"}
    if body is not None:
        hdrs["Content-Type"] = "application/json"
    hdrs.update(headers or {})
    req = urllib.request.Request(url, data=body, headers=hdrs, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:2000]
        raise RuntimeError(f"{method or 'GET'} {url} -> HTTP {e.code}: {detail}") from None


def token():
    if not TOKEN_FILE:
        return ""
    try:
        return Path(TOKEN_FILE).read_text().strip()
    except OSError:
        return ""


def firefly(path, payload=None, method=None, raw=None, content_type=None):
    headers = {"Authorization": f"Bearer {token()}"}
    url = f"{FIREFLY_URL.rstrip('/')}/api/v1/{path.lstrip('/')}"
    if raw is not None:
        req = urllib.request.Request(
            url, data=raw, method=method or "POST",
            headers={**headers, "Content-Type": content_type or "application/octet-stream"},
        )
        try:
            with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
                return resp.read()
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "replace")[:2000]
            raise RuntimeError(f"POST {url} -> HTTP {e.code}: {detail}") from None
    return request_json(url, payload, headers, method)


def settled(path):
    """True once a file has stopped changing.

    Syncthing writes a receipt in place under its final name while the transfer is still in
    flight, so picking one up the instant it appears means feeding the model half an image.
    """
    try:
        st = path.stat()
    except OSError:
        return False
    return st.st_size > 0 and (time.time() - st.st_mtime) >= SETTLE_SECONDS


def queued_images():
    for path in sorted(INBOX.iterdir()):
        if not path.is_file() or path.name.startswith("."):
            continue
        # Syncthing's own scratch files, which are none of our business
        if path.name.startswith("~syncthing~") or path.suffix == ".tmp":
            continue
        if path.suffix.lower() not in IMAGE_SUFFIXES:
            # Park it rather than skip it: left in place it would be re-reported every single
            # run, and deleting someone's file because we didn't recognise the extension is
            # not ours to do.
            log(f"{path.name} is not a receipt image; moving to {FAILED.name}/")
            move(path, None, FAILED, error=f"unsupported file type {path.suffix!r}")
            continue
        if not settled(path):
            log(f"skip {path.name}: still being written")
            continue
        yield path


def as_jpeg(path):
    """Normalise to a modestly sized upright JPEG.

    Phone cameras produce 12MP HEICs carrying their orientation in EXIF. Downscaling costs
    nothing in receipt legibility and saves a great deal of CPU time, since image tokens are
    what dominate inference here; -auto-orient means a sideways photo is read the right way up.
    """
    out = subprocess.run(
        [MAGICK, str(path) + ("[0]" if path.suffix.lower() == ".pdf" else ""),
         "-auto-orient", "-resize", f"{MAX_PIXELS}x{MAX_PIXELS}>", "-quality", "85", "jpg:-"],
        capture_output=True,
    )
    if out.returncode != 0 or not out.stdout:
        raise RuntimeError(f"could not decode image: {out.stderr.decode('utf-8', 'replace')[:500]}")
    return out.stdout


def extract(path):
    started = time.monotonic()
    payload = {
        "model": MODEL,
        "stream": False,
        "format": SCHEMA,
        "options": {"temperature": 0},
        "messages": [{"role": "user", "content": PROMPT, "images": [base64.b64encode(as_jpeg(path)).decode()]}],
    }
    # The schema is enforced during decoding, so a reply that still won't parse means the model
    # put everything in its reasoning channel and left the answer empty - rare, and it does not
    # repeat. One retry is worth it before condemning a receipt to failed/.
    for attempt in (1, 2):
        reply = request_json(f"{OLLAMA_URL.rstrip('/')}/api/chat", payload)
        content = (reply.get("message", {}).get("content") or "").strip()
        if content:
            try:
                fields = json.loads(content)
                break
            except json.JSONDecodeError:
                pass
        if attempt == 2:
            raise RuntimeError(f"model returned no usable JSON (content={content[:200]!r})")
        log(f"retrying {path.name}: model returned no usable JSON")
    fields["_model"] = MODEL
    fields["_source_file"] = path.name
    fields["_extracted_at"] = datetime.now().astimezone().isoformat(timespec="seconds")
    fields["_sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
    log(f"read {path.name} in {time.monotonic() - started:.0f}s: "
        f"{fields.get('merchant')!r} {fields.get('total')} {fields.get('currency')} on {fields.get('date')}")
    return fields


def validate(fields):
    total = float(fields["total"])
    if total <= 0:
        raise ValueError(f"total is {total}, which is not a purchase amount")
    try:
        when = datetime.strptime(str(fields["date"]).strip(), "%Y-%m-%d").date()
    except ValueError:
        raise ValueError(f"date {fields['date']!r} is not YYYY-MM-DD") from None
    # A model that misreads the year can otherwise file a 2019 receipt under 2119.
    if not date(2000, 1, 1) <= when <= date.today():
        raise ValueError(f"date {when} is outside the plausible range")
    currency = str(fields.get("currency") or CURRENCY).strip().upper()
    if len(currency) != 3:
        currency = CURRENCY
    merchant = str(fields.get("merchant") or "").strip() or "Unknown merchant"
    return total, when, currency, merchant


def asset_account_id():
    accounts = firefly("accounts?type=asset&limit=100")["data"]
    if not accounts:
        raise RuntimeError("Firefly III has no asset accounts to book this against")
    if ASSET_ACCOUNT:
        for account in accounts:
            if account["attributes"]["name"] == ASSET_ACCOUNT:
                return account["id"]
        names = ", ".join(repr(a["attributes"]["name"]) for a in accounts)
        raise RuntimeError(f"no asset account named {ASSET_ACCOUNT!r}; this instance has: {names}")
    return accounts[0]["id"]


def attach(journal_id, path):
    created = firefly("attachments", {
        "filename": path.name,
        "attachable_type": "TransactionJournal",
        "attachable_id": str(journal_id),
        "title": f"Receipt {path.name}",
    })
    firefly(f"attachments/{created['data']['id']}/upload", raw=path.read_bytes())


def total_below_items(total, items):
    """The line items add up to materially more than the total claims was paid.

    When a model grabs the wrong number off a receipt it grabs a neighbouring one, and the tax
    line sitting just under the total is the classic - which is how a 2720 HUF cafe bill gets
    filed as its 578 HUF VAT. The line items are an independent reading of the same purchase,
    so a total far below their sum is the cheapest evidence available that this happened.

    Only that direction is worth flagging. Items summing to *less* than the total is routine and
    means nothing: tax added at the end, or a "2x 1.15" line whose printed price is per unit and
    not the 2.30 charged. Discounts can legitimately trip this the other way, which is why it
    annotates rather than rejects.
    """
    if not items:
        return None
    total_of_items = sum(float(i.get("price") or 0) for i in items)
    return total_of_items if total < 0.9 * total_of_items else None


def import_one(image, fields, source_id):
    total, when, currency, merchant = validate(fields)
    items = fields.get("items") or []
    tags = [TAG]
    notes = [f"Imported from {image.name} by {fields.get('_model', MODEL)}."]
    if fields.get("payment_method"):
        notes.append(f"Paid by {fields['payment_method']}.")

    understated = total_below_items(total, items)
    if understated is not None:
        tags.append(f"{TAG}-check")
        notes.append(f"CHECK: the line items add up to {understated:.2f} {currency}, well above the "
                     f"{total:.2f} {currency} read as the total. Confirm the amount against the photo.")

    if items:
        notes.append("")
        notes += [f"- {i.get('name')}: {i.get('price')}" for i in items]

    created = firefly("transactions", {
        "apply_rules": True,
        "fire_webhooks": True,
        "transactions": [{
            "type": "withdrawal",
            "date": when.isoformat(),
            "amount": f"{total:.2f}",
            "currency_code": currency,
            "description": merchant,
            "source_id": source_id,
            "destination_name": merchant,
            "tags": tags,
            "notes": "\n".join(notes),
            "external_id": f"receipt-{fields.get('_sha256', '')[:16]}",
            # Only sent when the model actually read one - Firefly III rejects an explicit null
            # here rather than treating it as "uncategorised".
            **({"category_name": category} if (category := (fields.get("category") or "").strip()) else {}),
        }],
    })
    journal_id = created["data"]["attributes"]["transactions"][0]["transaction_journal_id"]
    attach(journal_id, image)
    return created["data"]["id"], journal_id


def move(image, sidecar, target, error=None):
    target.mkdir(parents=True, exist_ok=True)
    destination = target / image.name
    # Two receipts photographed the same second would otherwise overwrite each other.
    stem, suffix, n = destination.stem, destination.suffix, 1
    while destination.exists():
        destination = target / f"{stem}-{n}{suffix}"
        n += 1
    image.replace(destination)
    if sidecar and sidecar.exists():
        sidecar.replace(destination.with_suffix(".json"))
    if error:
        destination.with_suffix(".error").write_text(error + "\n")
    return destination


def stage_extract():
    failures = 0
    for image in queued_images():
        try:
            fields = extract(image)
        except Exception as e:
            log(f"FAILED to read {image.name}: {e}")
            move(image, None, FAILED, error=str(e))
            failures += 1
            continue
        # Move first, then write the extraction beside it: the sidecar must never be created
        # inside inbox/, or Syncthing would push it back out to the phone before it moves.
        destination = move(image, None, PENDING)
        destination.with_suffix(".json").write_text(json.dumps(fields, indent=2, ensure_ascii=False))
    return failures


def stage_import():
    waiting = sorted(p for p in PENDING.iterdir() if p.suffix == ".json") if PENDING.is_dir() else []
    if not waiting:
        return 0
    if not token():
        log(f"{len(waiting)} receipt(s) waiting in {PENDING}: no Firefly III API token configured yet")
        return 0

    source_id = asset_account_id()
    failures = 0
    for sidecar in waiting:
        images = [p for p in PENDING.iterdir() if p.stem == sidecar.stem and p != sidecar]
        if not images:
            log(f"FAILED {sidecar.name}: extraction is here but its image is not")
            failures += 1
            continue
        image = images[0]
        try:
            fields = json.loads(sidecar.read_text())
            group_id, journal_id = import_one(image, fields, source_id)
        except Exception as e:
            log(f"FAILED to import {image.name}: {e}")
            move(image, sidecar, FAILED, error=str(e))
            failures += 1
            continue
        log(f"imported {image.name} as transaction {group_id} (journal {journal_id})")
        fields["_firefly_transaction_id"] = group_id
        sidecar.write_text(json.dumps(fields, indent=2, ensure_ascii=False))
        move(image, sidecar, DONE)
    return failures


def main():
    for d in (INBOX, PENDING, DONE, FAILED):
        d.mkdir(parents=True, exist_ok=True)
    failures = stage_extract() + stage_import()
    if failures:
        log(f"{failures} receipt(s) failed; see {FAILED}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
