{
    description = "My Nixos Configuration";

    inputs = {
        nixpkgs.url = "nixpkgs/nixos-23.11";
        nixpkgs-unstable.url = "nixpkgs/nixos-unstable";
#home-manager.url = "github:nix-community/home-manager";
#home-manager.inputs.nixpkgs.follows = "nixpkgs";
    };

    outputs = { nixpkgs, nixpkgs-unstable, ... }:
    let
        system = "x86_64-linux";
        pkgs-unstable = import nixpkgs-unstable { inherit system; };
        pkgs = import nixpkgs {
            system = system;
            config = { allowUnfree = true; };
        };
    in {
        nixosConfigurations = import ./nixos-configurations.nix { inherit nixpkgs pkgs-unstable pkgs system; };
    };

}
