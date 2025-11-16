#!/usr/bin/env bash

set -eou pipefail

CONFIGURATION="hp"
IP="192.168.1.183"

# sops
## generate ssh host key
rm -rf tmp
mkdir -p tmp
echo "*" > tmp/.gitignore
ssh-keygen -t ed25519 -f tmp/ssh_host_ed25519_key -N "" -C ""
## generate age key from "/etc/ssh/ssh_host_ed25519_key"
ssh-to-age -i tmp/ssh_host_ed25519_key.pub > tmp/ssh_host_ed25519_key.age
## add key to sops file

if grep -q "^  - &${CONFIGURATION} " sops/.sops.yaml; then
    echo updating existing key for ${CONFIGURATION}
    sed -e "s/^\(  - &${CONFIGURATION}\) age[a-z0-9]*/\1 $(cat tmp/ssh_host_ed25519_key.age)/" -i sops/.sops.yaml
else
    echo adding new key for ${CONFIGURATION}
    sed -e "s/^keys:$/keys:\n  - \&${CONFIGURATION} $(cat tmp/ssh_host_ed25519_key.age)/" -i sops/.sops.yaml
    sed -e "s/^    - age:$/    - age:\n      - *${CONFIGURATION}/" -i sops/.sops.yaml
fi

cd sops && sops updatekeys secrets.yaml || exit 1
echo done updating sops keys

# nixos-anywhere
nix run github:nix-community/nixos-anywhere -- --flake ".#${CONFIGURATION}" --target-host root@${IP}

# copy ssh host key
rsync -avzv tmp/ssh_host_ed25519_key tmp/ssh_host_ed25519_key.pub root@${IP}:/mnt/etc/ssh/

# reboot host
ssh root@${IP} 'systemctl reboot'

# set up tailscale
ssh root@${IP} 'tailscale up'
TS_IP=$(tailscale status | grep "^100.[0-9]*.[0-9]*.[0-9]*    ${CONFIGURATION}" | cut -d' ' -f1)
sed -e "s/\(MODULES.networking.tailscale.hostIP = \)\"100.[0-9]*.[0-9]*.[0-9]*\";/\1\"${TS_IP}\";/" -i hosts/${CONFIGURATION}/default.nix

deploy -s .#${CONFIGURATION}

# cleanup
rm -rf tmp