{
  nixpkgs,
  home-manager,
  sops-nix,
  ...
} @ args: {
  iso = nixpkgs.lib.nixosSystem {
    specialArgs = args;
    modules = [
      ./generated.nix
      ./hosts/iso
      home-manager.nixosModules.home-manager
      {
        home-manager.useGlobalPkgs = true;
        home-manager.useUserPackages = true;
      }
      sops-nix.nixosModules.sops
    ];
  };

  laptop = nixpkgs.lib.nixosSystem {
    specialArgs = args;
    modules = [
      ./generated.nix
      ./hosts/laptop
      home-manager.nixosModules.home-manager
      {
        home-manager.useGlobalPkgs = true;
        home-manager.useUserPackages = true;
      }
      sops-nix.nixosModules.sops
    ];
  };

  laptop-srv = nixpkgs.lib.nixosSystem {
    specialArgs = args;
    modules = [
      ./generated.nix
      ./hosts/laptop-srv
      home-manager.nixosModules.home-manager
      {
        home-manager.useGlobalPkgs = true;
        home-manager.useUserPackages = true;
      }
      sops-nix.nixosModules.sops
    ];
  };

  legion5 = nixpkgs.lib.nixosSystem {
    specialArgs = args;
    modules = [
      ./generated.nix
      ./hosts/legion5
      home-manager.nixosModules.home-manager
      {
        home-manager.useGlobalPkgs = true;
        home-manager.useUserPackages = true;
      }
      sops-nix.nixosModules.sops
    ];
  };
}
