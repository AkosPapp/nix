#!/bin/sh
OUTPUT="generated.nix"

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

# hosts
#for host in $(ls hosts); do
#  echo "  $(basename $host .nix) = import ./hosts/$host;" >> $OUTPUT
#done

echo "}" >> $OUTPUT
