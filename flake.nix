{
  description = "My Nixos Configuration";
  inputs = {
    deploy-rs.url = "github:serokell/deploy-rs";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    my-nixvim. url = "github:PPAPSONKA/nixvim";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    nixpkgs-unstable.url = "nixpkgs/nixos-unstable";
    nixpkgs.url = "nixpkgs/nixos-24.11";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = {
    self,
    nixpkgs,
    nixpkgs-unstable,
    my-nixvim,
    disko,
    sops-nix,
    nixos-hardware,
    deploy-rs,
    ...
  } @ inputs: let
    nixos-version = "24.11";
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
        my-nixvim
        disko
        sops-nix
        nixos-hardware
        nixos-version
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
