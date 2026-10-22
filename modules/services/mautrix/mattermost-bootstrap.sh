# SPDX-License-Identifier: GPL-3.0-or-later
# One-shot bootstrap for the mautrix-mattermost bridge. Runs as root, before the bridge.
#
#  1. Makes sure the bridge has a Mattermost Personal Access Token to log in with.
#     Reads the account password once (LoadCredential, from sops), logs in to get a session,
#     creates a PAT named like this script's doing, and disables any stale PAT from an earlier
#     run. The result is written to the bridge's EnvironmentFile, owned by the bridge user.
#  2. Joins every public channel of the configured teams with the bridge's own PAT, so new
#     channels appear in Matrix as portals without manual clicks (the bridge opens a portal per
#     channel the account is a member of). DMs need no setup: the bridge creates their portals
#     when a message arrives.
#
# No secret ever appears in the unit file or the journal: the password is only ever read from
# $CREDENTIALS_DIRECTORY, and the PAT is only ever touched inside the mode-0600 state file.
set -eu

CURL=__CURL__
JQ=__JQ__
URL="$MM_URL"
PAT_FILE="$MM_PAT_FILE"
DESC="managed by __SERVICE__"

log() { echo "mautrix-mattermost-bootstrap: $*"; }

# The token the script speaks Mattermost API with: reuse the existing PAT while it validates,
# otherwise do a session login with the password and mint a fresh one.
tok=""
if [ -f "$PAT_FILE" ]; then
  tok="$(sed -n 's/^MATTERMOST_AUTO_TOKEN=//p' "$PAT_FILE" | head -n1)"
fi
if [ -n "$tok" ] && $CURL -sf -o /dev/null -H "Authorization: Bearer $tok" "$URL/api/v4/users/me"; then
  log "existing PAT still valid"
else
  pass="$(cat "$CREDENTIALS_DIRECTORY/mm_password")"
  # Build the login JSON with jq: the password may contain quotes/backslashes
  # that raw string interpolation would turn into a malformed body (server
  # answers "invalid credentials"). Body goes via file, not argv (ps-visible).
  bodyf="$(mktemp)"
  chmod 600 "$bodyf"
  $JQ -cn --arg u "$MM_USER" --arg p "$pass" '{login_id:$u,password:$p}' > "$bodyf"
  # Mattermost delivers the session token in the "Token" response header (docs for
  # v10+; the body is only the user object). Some servers use the MMAUTHTOKEN cookie
  # instead; accept either.
  sess="$($CURL -sf -D - -o /dev/null -X POST "$URL/api/v4/users/login" \
    --data-binary "@$bodyf" \
    | tr -d '\r' \
    | { sed -n 's/^[Tt]oken:[[:space:]]*\([^[:space:]]*\).*/\1/p'
        sed -n 's/^[Ss]et-[Cc]ookie:[[:space:]]*MMAUTHTOKEN=\([^;]*\).*/\1/p'; } \
    | head -n1)"
  rm -f "$bodyf"
  [ -n "$sess" ] || { log "login returned no session token"; exit 1; }
  # Drop our PATs from previous runs (they stay valid in Mattermost until disabled), so the
  # account does not accumulate one token per deploy. Match on our description only.
  $CURL -sf -H "Authorization: Bearer $sess" "$URL/api/v4/users/me/tokens" \
    | $JQ -r --arg d "$DESC" '.tokens[] | select(.description == $d) | .id' \
    | while read -r old; do
        [ -n "$old" ] && $CURL -sf -o /dev/null -X POST "$URL/api/v4/users/tokens/$old/disable" || true
      done
  crf="$(mktemp)"; chmod 600 "$crf"
  code="$($CURL -s -o "$crf" -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $sess" -H 'Content-Type: application/json' \
    "$URL/api/v4/users/me/tokens" \
    -d "{\"friendly_name\":\"mautrix-mattermost\",\"description\":\"$DESC\"}")"
  new="$($JQ -r '.token // empty' "$crf")"
  if [ -z "$new" ]; then
    # Only echo Mattermost's machine-readable error id (safe, never the body:
    # a partial-success body could contain a token).
    err="$(grep -o '"id":"api[.a-z_]*"' "$crf" | head -n1)"
    if [ "$code" = 403 ] && [ "$err" = '"id":"api.context.permissions.app_error"' ]; then
      # The server admin disabled user access tokens (EnableUserAccessTokens=false).
      # The session token from the password login is an equivalent Bearer credential;
      # it expires, but the bootstrap timer re-validates /users/me and re-logins.
      log "user access tokens disabled on server; using the login session token"
      new="$sess"
    else
      log "no PAT in response (http=$code ${err:-no error id})"
      rm -f "$crf"; exit 1
    fi
  fi
  rm -f "$crf"
  old_contents="$(cat "$PAT_FILE" 2>/dev/null || true)"
  umask 0177
printf 'MATTERMOST_AUTO_TOKEN=%s\nMATTERMOST_AUTO_SERVER_URL=%s\nMATTERMOST_AUTO_OWNER_MXID=%s\n' \
    "$new" "$URL" "$MM_OWNER" >"$PAT_FILE.tmp"
  # The file lands in bootstrap's OWN root-owned StateDirectory; systemd reads it as
  # root when starting the bridge, so a plain 0600 root file is all this ever needs.
  chmod 600 "$PAT_FILE.tmp"
  mv -f "$PAT_FILE.tmp" "$PAT_FILE"
  tok="$new"
  log "new token written"
  # Unconditional restart: the old content-compare guard no-ops silently when the
  # previous file was unreadable by root (both sides compared as empty strings).
  systemctl try-restart --no-block __SERVICE__.service || true
fi

# Join all public channels of the configured teams; already-member is a 400, which is fine and
# cheap, but asking first keeps the log honest about what changed this run.
me="$($CURL -sf -H "Authorization: Bearer $tok" "$URL/api/v4/users/me" | $JQ -r .id)"
for team in $MM_TEAMS; do
  teamid="$($CURL -sf -H "Authorization: Bearer $tok" "$URL/api/v4/teams/name/$team" | $JQ -r .id)"
  joined=0
  page=0
  while :; do
    chans="$($CURL -sf -H "Authorization: Bearer $tok" \
      "$URL/api/v4/teams/$teamid/channels?type=O&page=$page&per_page=200" | $JQ -r '.[].id')"
    [ -n "$chans" ] || break
    for ch in $chans; do
      if ! $CURL -sf -o /dev/null -H "Authorization: Bearer $tok" \
        "$URL/api/v4/channels/$ch/members/$me"; then
        if $CURL -sf -o /dev/null -X POST -H "Authorization: Bearer $tok" \
          "$URL/api/v4/channels/$ch/members" -d "{\"user_id\":\"$me\"}"; then
          joined=$((joined + 1))
        fi
      fi
    done
    page=$((page + 1))
  done
  log "team $team: joined $joined new channel(s)"
done
log "done"
