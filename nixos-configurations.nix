{
  nixpkgs,
  sops-nix,
  disko,
  ...
} @ args: {
  akos01 = nixpkgs.lib.nixosSystem {
    specialArgs = args;
    modules = [
      ./generated.nix
      ./hosts/akos01
      sops-nix.nixosModules.sops
      disko.nixosModules.disko
    ];
  };
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
}
