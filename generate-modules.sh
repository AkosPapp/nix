#!/bin/sh
OUTPUT="generated.nix"
NIX_CONFIGS="nixos-configurations.nix"

# imports
echo "{ imports = [" > $OUTPUT

# users
find users -type f -name "*.nix" >> $OUTPUT

# modules
find modules -type f -name "*.nix" >> $OUTPUT

# profiles
find profiles -type f -name "*.nix" >> $OUTPUT

# finish imports
echo "];" >> $OUTPUT
echo "}" >> $OUTPUT

# hosts
echo "{ nixpkgs, system, pkgs, pkgs-unstable, home-manager, ... }: {" > $NIX_CONFIGS
for host in $(ls hosts); do
    echo "
    $(basename $host) = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit system pkgs pkgs-unstable home-manager; };
        modules = [ ./${OUTPUT} ./hosts/${host} ];
    };
    " >> $NIX_CONFIGS
done
echo "}" >> $NIX_CONFIGS
