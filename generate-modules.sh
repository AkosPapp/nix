#!/bin/sh
OUTPUT="generated.nix"
NIX_CONFIGS="nixos-configurations.nix"

# imports
echo "{ imports = [" > $OUTPUT

# users
for user in $(ls users); do
    echo "users/${user}" >> $OUTPUT
done

# modules
find modules -type f -name "*.nix" >> $OUTPUT

# profiles
find profiles -type f -name "*.nix" >> $OUTPUT

# finish imports
echo "];" >> $OUTPUT
echo "}" >> $OUTPUT

# hosts
echo "{ nixpkgs, home-manager, ... }@args: {" > $NIX_CONFIGS
for host in $(ls hosts); do
    echo "
    $(basename $host) = nixpkgs.lib.nixosSystem {
        specialArgs = args;
        modules = [ ./${OUTPUT} ./hosts/${host}
        home-manager.nixosModules.home-manager
        {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
        }
        ];
    };
    " >> $NIX_CONFIGS
done
echo "}" >> $NIX_CONFIGS
