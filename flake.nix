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
        guest = import ./modules/guest.nix;
        default = self.nixosModules.host;
      };

      checks = forAllSystems (
        system: {
          synthetic-host-guest = import ./checks/synthetic-host-guest.nix {
            inherit self inputs nixpkgs system;
          };
        }
      );
    };
}
