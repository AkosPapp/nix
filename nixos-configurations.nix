{
  nixpkgs,
  sops-nix,
  disko,
  ...
} @ args: {
  hp = nixpkgs.lib.nixosSystem {
    specialArgs = args;
    modules = [
      ./generated.nix
      ./hosts/hp
      sops-nix.nixosModules.sops
      disko.nixosModules.disko
    ];
  };
  iso = nixpkgs.lib.nixosSystem {
    specialArgs = args;
    modules = [
      ./generated.nix
      ./hosts/iso
      sops-nix.nixosModules.sops
      disko.nixosModules.disko
    ];
  };
  legion5 = nixpkgs.lib.nixosSystem {
    specialArgs = args;
    modules = [
      ./generated.nix
      ./hosts/legion5
      sops-nix.nixosModules.sops
      disko.nixosModules.disko
    ];
  };
  minimal = nixpkgs.lib.nixosSystem {
    specialArgs = args;
    modules = [
      ./generated.nix
      ./hosts/minimal
      sops-nix.nixosModules.sops
      disko.nixosModules.disko
    ];
  };
}
