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
      sops-nix.nixosModules.sops
      disko.nixosModules.disko
      {
        home-manager.useGlobalPkgs = true;
        home-manager.useUserPackages = true;
      }
    ];
  };
  iso = nixpkgs.lib.nixosSystem {
    specialArgs = args;
    modules = [
      ./generated.nix
      ./hosts/iso
      home-manager.nixosModules.home-manager
      sops-nix.nixosModules.sops
      disko.nixosModules.disko
      {
        home-manager.useGlobalPkgs = true;
        home-manager.useUserPackages = true;
      }
    ];
  };
  legion5 = nixpkgs.lib.nixosSystem {
    specialArgs = args;
    modules = [
      ./generated.nix
      ./hosts/legion5
      home-manager.nixosModules.home-manager
      sops-nix.nixosModules.sops
      disko.nixosModules.disko
      {
        home-manager.useGlobalPkgs = true;
        home-manager.useUserPackages = true;
      }
    ];
  };
}
