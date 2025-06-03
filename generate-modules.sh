#!/bin/sh
OUTPUT="generated.nix"
NIX_CONFIGS="nixos-configurations.nix"

# imports
echo "{
  imports = [" > $OUTPUT

# users
for user in $(ls users); do
    echo "    users/${user}" >> $OUTPUT
done

# modules
for module in $(find modules -type f -name "*.nix"); do
    echo "    ${module}" >> $OUTPUT
done

# profiles
for profile in $(find profiles -type f -name "*.nix"); do
    echo "    ${profile}" >> $OUTPUT
done

# finish imports
echo "  ];" >> $OUTPUT
echo "}" >> $OUTPUT

# hosts
echo "{
  nixpkgs,
  sops-nix,
  disko,
  ...
} @ args: {" > $NIX_CONFIGS
for host in $(ls hosts); do
echo "  $(basename $host) = nixpkgs.lib.nixosSystem {
    specialArgs = args;
    modules = [
      ./${OUTPUT}
      ./hosts/${host}
      sops-nix.nixosModules.sops
      disko.nixosModules.disko
    ];
  };" >> $NIX_CONFIGS
done
echo "}" >> $NIX_CONFIGS
