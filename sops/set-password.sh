#!/usr/bin/env bash
# Set the password hash of a user account in this repo's sops file
# (sops/secrets.yaml -> passwords.<user>). The NEXT NixOS rebuild / deploy of
# the host picks it up: sops-nix renders it to /run/secrets/passwords/<user>
# and the users-activation script reads it as hashedPasswordFile (see
# users/akos.nix and the hosts' users.* blocks).
#
# Usage:
#   ./sops/set-password.sh          # reset akos's password (the default)
#   ./sops/set-password.sh root     # reset root's password (akos01, hp, legion5)
#   ./sops/set-password.sh <user>   # any <user> a host declares as
#                                   #   sops.secrets."passwords/<user>"
#
# Only the yescrypt HASH is written; the plaintext lives nowhere on disk.
# Runs with the sops key holders' key available (age key or GPG).
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
file="$repo/sops/secrets.yaml"

user="${1:-akos}"
key="[\"passwords\",\"$user\"]"

if ! command -v sops >/dev/null 2>&1; then
    echo "error: sops not on PATH" >&2
    exit 1
fi

mkpasswd_bin="$(command -v mkpasswd || true)"
if [ -z "$mkpasswd_bin" ] && [ -x /run/current-system/sw/bin/mkpasswd ]; then
    mkpasswd_bin=/run/current-system/sw/bin/mkpasswd
fi
if [ -z "$mkpasswd_bin" ]; then
    echo 'error: mkpasswd not found (part of nixpkgs.mkpasswd)' >&2
    exit 1
fi

echo "Resetting ${user}'s login password (sops key ${key})."
echo "Note: mutableUsers = false - the new hash is applied on the next rebuild/deploy ('make switch')."
printf 'New %s password: ' "$user"
read -r -s pw1
echo
printf 'Repeat: '
read -r -s pw2
echo
if [ -z "$pw1" ]; then
    echo "error: empty password; nothing written." >&2
    exit 1
fi
if [ "$pw1" != "$pw2" ]; then
    echo "error: passwords do not match; nothing written." >&2
    exit 1
fi

hash="$("$mkpasswd_bin" -m yescrypt <<<"$pw1")"

# The value must be a JSON string. A yescrypt hash only ever contains
# [A-Za-z0-9./$], all valid inside a JSON string, so plain quoting is enough.
sops set "$file" "$key" "\"$hash\""
echo "Done. ${key} now holds a fresh yescrypt hash - apply with 'make switch'."
