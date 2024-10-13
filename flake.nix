{
  description = "My Nixos Configuration";
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-24.05";
    nixpkgs-unstable.url = "nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager/release-24.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    my-nixvim = {
      url = "github:PPAPSONKA/nixvim";
      flake = true;
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    deploy-rs.url = "github:serokell/deploy-rs";
    nixgl.url = "github:nix-community/nixGL";
  };
  outputs = {
    self,
    nixpkgs,
    nixpkgs-unstable,
    home-manager,
    my-nixvim,
    disko,
    sops-nix,
    nixos-hardware,
    deploy-rs,
    nixgl,
    ...
  } @ inputs: let
    system = "x86_64-linux";
    pkgs-unstable = import nixpkgs-unstable {
      system = system;
      config = {
        allowUnfree = true;
        allowBroken = true;
        permittedInsecurePackages = [
          "electron-27.3.11"
        ];
      };
    };
    pkgs = import nixpkgs {
      system = system;
      config = {
        allowUnfree = true;
        allowBroken = true;
        permittedInsecurePackages = [
          "electron-27.3.11"
        ];
        overlays = [nixgl.overlay];
      };
    };
  in {
    formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.alejandra;
    nixosConfigurations = import ./nixos-configurations.nix {
      inherit
        nixpkgs
        system
        pkgs
        pkgs-unstable
        home-manager
        my-nixvim
        disko
        sops-nix
        nixos-hardware
        nixgl
        ;
    };
    #deploy = lib.mkDeploy {inherit (inputs) self;};
    deploy.nodes.hp = {
      hostname = "hp";
      profiles.system = {
        sshUser = "root";
        user = "root";
        path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.hp;
        remoteBuild = false;
      };
    };
    checks = builtins.mapAttrs (system: deployLib: deployLib.deployChecks self.deploy) deploy-rs.lib;
  };
}
