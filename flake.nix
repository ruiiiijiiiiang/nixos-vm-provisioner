{
  description = "NixOS-VM-Provisioner: Automated host-managed VM provisioning";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    NixVirt = {
      url = "github:AshleyYakeley/NixVirt";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      NixVirt,
      ...
    }@inputs:
    let
      supportedSystems = [ "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      nixosModules = {
        host =
          { ... }:
          {
            imports = [
              ./modules/host.nix
              NixVirt.nixosModules.default
            ];
            _module.args.inputs = inputs;
          };
        host-base = ./modules/host.nix;
        guest =
          { ... }:
          {
            imports = [
              ./modules/guest.nix
              inputs.disko.nixosModules.disko
            ];
          };
        guest-base = ./modules/guest.nix;
        default = self.nixosModules.host;
      };

      checks = forAllSystems (system: {
        synthetic-host-guest = import ./checks/synthetic-host-guest.nix {
          inherit self nixpkgs system;
        };
      });
    };
}
