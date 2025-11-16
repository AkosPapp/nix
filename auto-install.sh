#!/bin/env bash

set -eou pipefail

CONFIGURATION="hp"
IP="100.125.194.123"

# sops
## generate ssh host key
mkdir -p tmp
echo "*" > tmp/.gitignore
ssh-keygen -t ed25519 -f tmp/ssh_host_ed25519_key -N "" -C ""
## generate age key from "/etc/ssh/ssh_host_ed25519_key"
ssh-to-age -i tmp/ssh_host_ed25519_key > tmp/ssh_host_ed25519_key.age
## add key to sops file

# disco

# nixos-install