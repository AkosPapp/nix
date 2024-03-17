{
    description = "My Nixos Configuration";

    inputs = {
        nixpkgs.url = "nixpkgs/nixos-23.11";
        nixpkgs-unstable.url = "nixpkgs/nixos-unstable";
        home-manager.url = "github:nix-community/home-manager";
        home-manager.inputs.nixpkgs.follows = "nixpkgs";
    };

    outputs = { nixpkgs, nixpkgs-unstable, home-manager, ... }:
        let
        system = "x86_64-linux";
    pkgs-unstable = import nixpkgs-unstable { inherit system; };
    pkgs = import nixpkgs {
        system = system;
        config = {
            allowUnfree = true;
            permittedInsecurePackages = [
                "nix-2.16.2"
            ];
        };
    };
    in {
        nixosConfigurations = import ./nixos-configurations.nix {
            inherit nixpkgs system pkgs pkgs-unstable home-manager;
        };
    };

}
