{
  description = "My Nixos Configuration";
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-23.11";
    nixpkgs-unstable.url = "nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager/release-23.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixvim = {
      url = "github:nix-community/nixvim/nixos-23.11";
      # If using a stable channel you can use `url = "github:nix-community/nixvim/nixos-<version>"`
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = { nixpkgs, nixpkgs-unstable, home-manager, nixvim, ... }:
    let
      system = "x86_64-linux";
      pkgs-unstable = import nixpkgs-unstable { inherit system; };
      pkgs = import nixpkgs {
        system = system;
        config = {
          allowUnfree = true;
          permittedInsecurePackages = [ "nix-2.16.2" "electron-25.9.0" ];
        };
      };
    in {
      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt;
      nixosConfigurations = import ./nixos-configurations.nix {
        inherit nixpkgs system pkgs pkgs-unstable home-manager nixvim;
      };
    };
}
