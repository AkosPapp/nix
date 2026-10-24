#!/usr/bin/env bash
# One-shot Cloudflare setup for this repo (rerunnable as a refresh):
#   nix run .#cloudflare-config
#
# - makes sure you are `cloudflared tunnel login`-ed (opens the browser otherwise)
# - finds the host's tunnel, creating it (name = host name) when missing
# - writes/refreshes the sops secrets: cloudflare.cert_pem + cloudflare.tunnel_credentials
# - writes the tunnel UUID into the host's config (hosts/hp/default.nix)
# - (re)routes every DNS record the config declares (`cloudflared tunnel route dns -f`)
# - flips the enable flags for the tunnel + public matrix once the UUID is in
#
# Commit the result and deploy: `deploy -s --targets .#hp .#akos01 --remote-build`.
set -euo pipefail

HOST="${CLOUDFLARE_CONFIG_HOST:-hp}"
HOSTFILE="hosts/$HOST/default.nix"

cd "$(git rev-parse --show-toplevel)"
[ -f "$HOSTFILE" ] || { echo "not in this repo (missing $HOSTFILE)" >&2; exit 1; }
[ -f sops/secrets.yaml ] || { echo "not in this repo (missing sops/secrets.yaml)" >&2; exit 1; }

TUNNEL_NAME="$HOST"
CFDIR="${CLOUDFLARE_CONFIG_CFDIR:-$HOME/.cloudflared}"

echo "== login"
if cloudflared tunnel list >/dev/null 2>&1; then
  echo "   cert.pem already valid ($CFDIR/cert.pem)"
else
  echo "   no valid origin certificate yet - opening the Cloudflare login in your browser"
  cloudflared tunnel login
fi

echo "== tunnel"
UUID=$(grep -oE 'tunnel\.uuid = "[0-9a-fA-F-]{36}"' "$HOSTFILE" 2>/dev/null | grep -oE '[0-9a-fA-F-]{36}' | head -1 || true)
if [ -z "$UUID" ]; then
  UUID=$(cloudflared tunnel list | awk -v n="$TUNNEL_NAME" '$2 == n {print $1; exit}' || true)
  [ -n "$UUID" ] && echo "   found existing tunnel '$TUNNEL_NAME' ($UUID) on the account"
fi
if [ -z "$UUID" ]; then
  echo "   creating tunnel '$TUNNEL_NAME'"
  cloudflared tunnel create "$TUNNEL_NAME"
  UUID=$(cloudflared tunnel list | awk -v n="$TUNNEL_NAME" '$2 == n {print $1; exit}')
fi
CREDS="$CFDIR/$UUID.json"
if [ ! -f "$CREDS" ]; then
  echo "   credentials file $CREDS not found." >&2
  echo "   it was only shown once at 'cloudflared tunnel create'; run the create on the machine" >&2
  echo "   that holds it, or delete + recreate the tunnel (old records must be re-routed)." >&2
  exit 1
fi
echo "   tunnel $UUID, credentials $CREDS"

echo "== sops secrets (cloudflare.cert_pem, cloudflare.tunnel_credentials)"
(cd sops &&
  sops set secrets.yaml '["cloudflare"]' '{}' &&
  sops set secrets.yaml '["cloudflare"]["tunnel_credentials"]' "$(jq -Rs . "$CREDS")" &&
  sops set secrets.yaml '["cloudflare"]["cert_pem"]' "$(jq -Rs . "$CFDIR/cert.pem")")

echo "== host config: tunnel.uuid"
if grep -qE 'tunnel\.uuid = "[0-9a-fA-F-]{36}"' "$HOSTFILE"; then
  sed -i -E "s/tunnel\.uuid = \"[0-9a-fA-F-]{36}\"/tunnel.uuid = \"$UUID\"/" "$HOSTFILE"
elif grep -qE '# tunnel\.uuid = "<uuid>";' "$HOSTFILE"; then
  sed -i -E "s|# tunnel\.uuid = \"<uuid>\";|tunnel.uuid = \"$UUID\";|" "$HOSTFILE"
else
  sed -i -E "/MODULES.networking.dns.cloudflare = \{/a\\    tunnel.uuid = \"$UUID\";" "$HOSTFILE"
fi

echo "== dns records (declared by the config)"
DOMAIN=$(nix eval ".#nixosConfigurations.$HOST.config.MODULES.networking.dns.cloudflare.domain" --raw)
mapfile -t NAMES < <(nix eval ".#nixosConfigurations.$HOST.config.MODULES.networking.dns.cloudflare._recordNames" --json | jq -r '.[]')
for name in "${NAMES[@]}"; do
  host=$([ "$name" = "@" ] && echo "$DOMAIN" || echo "$name.$DOMAIN")
  cloudflared tunnel route dns --overwrite-dns "$UUID" "$host" 2>&1 | grep -viE "outdated|WRN" | sed 's/^/   /'
done

echo "== enable flags"
sed -i -E '/MODULES\.networking\.dns\.cloudflare = \{/,/\};/ s/enable = false;/enable = true;/' "$HOSTFILE"
if ! grep -qE 'MODULES\.services\.matrix\.public\.enable = true;' "$HOSTFILE"; then
  sed -i -E 's|MODULES.services.matrix.public.enable = false;|MODULES.services.matrix.public.enable = true;|' "$HOSTFILE"
fi

echo
echo "done. Review, commit and deploy:"
echo "  git diff"
echo "  deploy -s --targets .#$HOST .#akos01 --remote-build"
