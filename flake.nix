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
      inputs.nixpkgs.follows = "nixpkgs-unstable";
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
      my-nixvim = import ./nixvim/default.nix {
        pkgs = pkgs-unstable;
        inherit pkgs-unstable;
      };
      nixvimLib = nixvim.lib.${system};
      nixvim' = nixvim.legacyPackages.${system};
      nixvimModule = {
        inherit pkgs;
        module = my-nixvim; # import the module directly
        # You can use `extraSpecialArgs` to pass additional arguments to your module files
        extraSpecialArgs = {
          # inherit (inputs) foo;
        };
      };
      nvim = nixvim'.makeNixvimWithModule nixvimModule;
    in {
      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt;
      nixosConfigurations = import ./nixos-configurations.nix {
        inherit nixpkgs system pkgs pkgs-unstable home-manager nixvim my-nixvim;
      };
      packages = {
        # Lets you run `nix run .` to start nixvim
        default = nvim;
      };

    };
}
