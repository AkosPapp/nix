#!/usr/bin/env bash
# Creates the root CA and one intermediate CA per host.
#
#   nix shell nixpkgs#step-cli -c pki/generate.sh ~/pki-secret [host...]     (default: hp akos01 legion5)
#
# The working directory holds the ROOT KEY and every password - keep it OUTSIDE this repo and
# offline (encrypted USB, password manager). Nothing in it is needed at runtime: hosts only get
# an intermediate, and the root key never touches sops or a server.
#
# Re-running reuses the existing root and password, so it's also how you add a host or rotate an
# intermediate (delete that host's intermediate_<host>.* first).
#
# Output:
#   pki/root_ca.crt, pki/intermediate_<host>.crt   public, copied into this repo (git add them)
#   <dir>/sops-snippet.yaml                        secrets to merge into sops/secrets.yaml
set -euo pipefail

out=${1:?usage: generate.sh <secret-dir> [host...]}
shift || true
hosts=("$@")
[ ${#hosts[@]} -gt 0 ] || hosts=(hp akos01 legion5)

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
mkdir -p "$out"
chmod 700 "$out"
cd "$out"

randpw() { head -c 32 /dev/urandom | base64 | tr -d '\n'; }

[ -f root_password ] || { umask 077; randpw >root_password; }
[ -f intermediate_password ] || { umask 077; randpw >intermediate_password; }

if [ ! -f root_ca.crt ]; then
  step certificate create "Akos Root CA" root_ca.crt root_ca.key \
    --profile root-ca --kty EC --curve P-256 \
    --password-file root_password --not-after 175200h # 20 years
fi

for host in "${hosts[@]}"; do
  if [ ! -f "intermediate_$host.crt" ]; then
    step certificate create "Akos $host Intermediate CA" \
      "intermediate_$host.crt" "intermediate_$host.key" \
      --profile intermediate-ca --kty EC --curve P-256 \
      --ca root_ca.crt --ca-key root_ca.key --ca-password-file root_password \
      --password-file intermediate_password --not-after 87600h # 10 years
  fi
  cp "intermediate_$host.crt" "$here/"
done
cp root_ca.crt "$here/"

{
  echo "step-ca:"
  echo "  intermediate_password: \"$(cat intermediate_password)\""
  for host in "${hosts[@]}"; do
    echo "  $host:"
    echo "    intermediate_key: |"
    sed 's/^/      /' "intermediate_$host.key"
  done
} >sops-snippet.yaml
chmod 600 sops-snippet.yaml

cat <<EOF

Public certificates copied to $here - now:
  git add $here/*.crt
  sops sops/secrets.yaml        # merge the contents of $out/sops-snippet.yaml at the top level
Root key + passwords stay in $out. Back that directory up somewhere offline.
Distribute $here/root_ca.crt to devices that aren't NixOS hosts of this flake (phone, browsers).
EOF
