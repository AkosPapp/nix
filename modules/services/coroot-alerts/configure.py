#!/usr/bin/env python3
"""Reconcile Coroot's per-project alerting wiring from the Nix-given facts.

Runs hourly (and at boot) on the Coroot SERVER host as coroot-alert-configure, with the
bearer key of the "alerts-reconciler" service account (coroot-alerts.nix's derived auth
config file creates it; the secret rides LoadCredential). The integration is DB state, not
config-file state: declaring a project through the config file would replace its
UI-generated api_keys and make its settings read-only in the UI (bootstrap.go), which the
fleet does not want - so coroot-alerts.nix keeps only the service account in config and
this script drives the REST API the same way the UI does, idempotently:

  GET  /api/user                               -> every project id
  PUT  /api/project/<id>/integrations          -> base_url (links in notifications)
  PUT  /api/project/<id>/integrations/webhook  -> hp receiver url + token header + JSON
                                                  templates for alerts and incidents
  POST /api/project/<id>/application_categories-> route alerts+incidents to the webhook
                                                  for every category (coroot routes per
                                                  category; the integration's on/off flags
                                                  merely "allow" the destination - without
                                                  this POST nothing is ever sent). The body
                                                  is the GET view echoed back with webhook
                                                  routing forced on.

All settings are DB-persisted, so an occasional failure just retries next hour; exit 0
only when every step succeeded (the unit's Restart=OnFailure drives the backoff).
"""

import json
import os
import pathlib
import sys
import urllib.error
import urllib.request

COROOT = os.environ["COROOT_ALERTS_COROOT_URL"].rstrip("/")
WEBHOOK_URL = os.environ["COROOT_ALERTS_WEBHOOK_URL"].rstrip("/") + os.environ.get("COROOT_ALERTS_WEBHOOK_PATH", "/")
BASE_URL = os.environ.get("COROOT_ALERTS_BASE_URL", COROOT)
TEMPLATE = os.environ.get("COROOT_ALERTS_TEMPLATE", "{{ json . }}")
CREDS = pathlib.Path(os.environ["CREDENTIALS_DIRECTORY"])

KEY = (CREDS / "admin_key").read_text().strip()
TOKEN = (CREDS / "webhook_token").read_text().strip()
if not (KEY and TOKEN):
    raise SystemExit("empty bearer key or webhook token credential")


def call(method, path, body=None):
    req = urllib.request.Request(
        COROOT + path,
        method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={
            "Content-Type": "application/json",
            # api/auth.go GetUser: "Authorization: Bearer <api key>" resolves the service
            # account, and the Admin role covers Settings+Integrations edit everywhere.
            "Authorization": "Bearer " + KEY,
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            raw = r.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:300]
        raise SystemExit(f"{method} {path}: HTTP {e.code}: {detail}") from None
    except OSError as e:
        raise SystemExit(f"{method} {path}: {e}") from None


def main():
    user = call("GET", "/api/user")
    projects = [p["id"] for p in (user or {}).get("projects", [])]
    if not projects:
        raise SystemExit("no projects visible to the reconciler - coroot not ready?")

    for pid in projects:
        call("PUT", f"/api/project/{pid}/integrations", {"base_url": BASE_URL})
        call(
            "PUT",
            f"/api/project/{pid}/integrations/webhook",
            {
                "url": WEBHOOK_URL,
                "custom_headers": [{"key": "x-coroot-token", "value": TOKEN}],
                "alerts": True,
                "incidents": True,
                "deployments": False,
                "alert_template": TEMPLATE,
                "incident_template": TEMPLATE,
            },
        )
        for cat in call("GET", f"/api/project/{pid}/application_categories") or []:
            ns = cat.get("notification_settings") or {}
            for kind in ("alerts", "incidents"):
                block = ns.setdefault(kind, {})
                block["enabled"] = True
                block["webhook"] = {"enabled": True}
            call(
                "POST",
                f"/api/project/{pid}/application_categories",
                {
                    "action": "",
                    "id": cat["name"],
                    "name": cat["name"],
                    "builtin": cat.get("builtin", False),
                    "default": cat.get("default", False),
                    "builtin_patterns": cat.get("builtin_patterns", ""),
                    "custom_patterns": cat.get("custom_patterns", ""),
                    "notification_settings": ns,
                },
            )
    print(f"coroot-alert-configure: wired {len(projects)} project(s) -> {WEBHOOK_URL}", flush=True)


if __name__ == "__main__":
    sys.exit(main())
