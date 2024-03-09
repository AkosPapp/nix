{
    description = "My Nixos Configuration";

    inputs = {
        nixpkgs.url = "nixpkgs/nixos-23.11";
        nixpkgs_unstable.url = "nixpkgs/nixos-unstable";
#home-manager.url = "github:nix-community/home-manager";
#home-manager.inputs.nixpkgs.follows = "nixpkgs";
    };

    outputs = { nixpkgs, ... }:
    let
        system = "x86_64-linux";
        pkgs = import nixpkgs {
            system = system;
            config = { allowUnfree = true; 
                permittedInsecurePackages = [ "nix-2.16.2" ]; # CVE-2024-27297

            };
        };
    in {
        nixosConfigurations = import ./nixos-configurations.nix { inherit nixpkgs pkgs system; };
    };

}
