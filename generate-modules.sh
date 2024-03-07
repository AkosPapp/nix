#!/bin/sh

# users
echo "Generating users module..."
echo "{ imports = [" > users.nix
find users -type f -name "*.nix" >> users.nix
echo "]; }" >> users.nix

# modules
echo "Generating modules module..."
echo "{ imports = [" > custom-modules.nix
find modules -type f -name "*.nix" >> custom-modules.nix
echo "]; }" >> custom-modules.nix

# hosts
echo "Generating hosts module..."
echo "{ " > hosts.nix
for host in $(ls hosts); do
  echo "  $(basename $host .nix) = import ./hosts/$host;" >> hosts.nix
done
echo "}" >> hosts.nix

