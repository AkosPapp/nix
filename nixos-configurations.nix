{
  nixpkgs,
  sops-nix,
  disko,
  pkgs,
  ...
} @ args: {
  hp = nixpkgs.lib.nixosSystem {
    specialArgs = args;
    modules = [
      ./generated.nix
      ./hosts/hp
      sops-nix.nixosModules.sops
      disko.nixosModules.disko
      nixpkgs.nixosModules.readOnlyPkgs
    ];
  };
  iso = nixpkgs.lib.nixosSystem {
    specialArgs = args;
    modules = [
      ./generated.nix
      ./hosts/iso
      sops-nix.nixosModules.sops
      disko.nixosModules.disko
      nixpkgs.nixosModules.readOnlyPkgs
    ];
  };
  legion5 = nixpkgs.lib.nixosSystem {
    specialArgs = args;
    modules = [
      ./generated.nix
      ./hosts/legion5
      sops-nix.nixosModules.sops
      disko.nixosModules.disko
      nixpkgs.nixosModules.readOnlyPkgs
    ];
  };
}
