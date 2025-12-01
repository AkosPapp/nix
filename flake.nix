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
    nixpkgs.url = "nixpkgs/nixos-25.11";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    niri = {
      url = "github:sodiboo/niri-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    nixpkgs-unstable,
    disko,
    sops-nix,
    deploy-rs,
    ...
  } @ inputs: let
    nixos-version = builtins.elemAt (builtins.match "([0-9][0-9]\.[0-9][0-9]).*" inputs.nixpkgs.lib.version) 0;

    system = "x86_64-linux";

    pkgs-unstable = import nixpkgs-unstable {
      inherit system;
      config = {
        allowUnfree = true;
        allowBroken = true;
      };
    };

    hosts = builtins.readDir ./hosts;

    module_files =
      builtins.filter
      (path: nixpkgs.lib.hasSuffix ".nix" (builtins.toString path))
      (
        (nixpkgs.lib.filesystem.listFilesRecursive ./modules)
        ++ (nixpkgs.lib.filesystem.listFilesRecursive ./profiles)
        ++ (nixpkgs.lib.filesystem.listFilesRecursive ./users)
      );
  in {
    formatter.${system} = nixpkgs.legacyPackages.${system}.alejandra;

    nixosConfigurations =
      builtins.mapAttrs (host: _: (nixpkgs.lib.nixosSystem {
        specialArgs =
          {
            inherit
              pkgs-unstable
              system
              nixos-version
              ;
            nixosConfigurations = self.nixosConfigurations;
            configName = host;
          }
          // inputs;
        modules =
          [
            ./hosts/${host}
            sops-nix.nixosModules.sops
            disko.nixosModules.disko
          ]
          ++ module_files;
      }))
      hosts;

    deploy.nodes =
      builtins.mapAttrs (host: config: {
        hostname = host;
        profiles.system = {
          sshUser = "root";
          user = "root";
          path = deploy-rs.lib.${system}.activate.nixos config;
          remoteBuild = false;
        };
      })
      (nixpkgs.lib.attrsets.filterAttrs (name: _: name != "iso") self.nixosConfigurations);

    checks = builtins.mapAttrs (system: deployLib: deployLib.deployChecks self.deploy) deploy-rs.lib;
  };
}
