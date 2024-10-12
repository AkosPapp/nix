{
  nixpkgs,
  home-manager,
  sops-nix,
  disko,
  ...
} @ args: {
  hp = nixpkgs.lib.nixosSystem {
    specialArgs = args;
    modules = [
      ./generated.nix
      ./hosts/hp
      home-manager.nixosModules.home-manager
      disko.nixosModules.disko
      {
        home-manager.useGlobalPkgs = true;
        home-manager.useUserPackages = true;
      }
      sops-nix.nixosModules.sops
    ];
  };
  iso = nixpkgs.lib.nixosSystem {
    specialArgs = args;
    modules = [
      ./generated.nix
      ./hosts/iso
      home-manager.nixosModules.home-manager
      disko.nixosModules.disko
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
      disko.nixosModules.disko
      {
        home-manager.useGlobalPkgs = true;
        home-manager.useUserPackages = true;
      }
      sops-nix.nixosModules.sops
    ];
  };
}
