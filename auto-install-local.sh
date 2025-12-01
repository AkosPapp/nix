#!/usr/bin/env bash

set -eou pipefail

CONFIGURATION="akos01zfs"

# disko 
nix --experimental-features "nix-command flakes"run github:nix-community/disko/latest -- --mode destroy,format,mount --flake .#${CONFIGURATION}\" 



nixos-install --flake .#${CONFIGURATION} --no-root-passwd

