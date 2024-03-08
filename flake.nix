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
            config = { allowUnfree = true; };
        };
        CONFIG = import ./generated.nix { inherit pkgs system; };
    in {
        nixosConfigurations = {
            laptop = nixpkgs.lib.nixosSystem {
                specialArgs = { inherit system; };
                modules = [ CONFIG.laptop ];
            };
            server1 = nixpkgs.lib.nixosSystem {
                specialArgs = { inherit system; };
                modules = [ CONFIG.server1 ];
            };
        }; 
    };

}
