#!/bin/env bash

set -eou pipefail

CONFIGURATION="hp"
IP="100.125.194.123"

# sops
## generate ssh host key
mkdir -p tmp/ssh-keys
echo "*" > tmp/.gitignore
ssh-keygen -t ed25519 -f tmp/ssh-keys/ssh_host_ed25519_key -N "" -C ""
## generate age key from "/etc/ssh/ssh_host_ed25519_key"
AGE_KEY=$(age-keygen -o - | head -n 1)
echo "${AGE_KEY}" > tmp/age-key.txt

age

# disco

# nixos-install