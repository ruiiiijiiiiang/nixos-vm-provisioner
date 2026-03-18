{
  self,
  inputs,
  nixpkgs,
  system,
}:

let
  pkgs = import nixpkgs { inherit system; };

  guestSystem = nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      inputs.disko.nixosModules.disko
      self.nixosModules.guest
      (
        { ... }:
        {
          system.stateVersion = "26.05";

          nixos-vm-provisioner.guest.enable = true;

          disko.devices = {
            disk.main = {
              type = "disk";
              device = "/dev/vda";
              content = {
                type = "gpt";
                partitions.root = {
                  size = "100%";
                  content = {
                    type = "btrfs";
                    subvolumes."@root".mountpoint = "/";
                  };
                };
              };
            };
          };
        }
      )
    ];
  };

  hostSystem = nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      self.nixosModules.host
      (
        { ... }:
        {
          system.stateVersion = "26.05";

          virtualisation.nixos-vm-provisioner = {
            enable = true;
            guests.synthetic = {
              storage.size = "10G";
              nixosConfig = guestSystem;
              flakeAttr = "synthetic-guest";
              diskoDisk = "main";
            };
          };
        }
      )
    ];
  };

  lvmHostSystem = nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      self.nixosModules.host
      (
        { ... }:
        {
          system.stateVersion = "26.05";

          virtualisation.nixos-vm-provisioner = {
            enable = true;
            volumeGroup = "vg-test";
            guests.lvm = {
              storage.type = "lvm";
              storage.size = "8G";
              nixosConfig = guestSystem;
            };
          };
        }
      )
    ];
  };

  domain =
    builtins.head
      hostSystem.config.virtualisation.libvirt.connections."qemu:///system".domains;
  prepareScript =
    hostSystem.config.systemd.services."prepare-guest-storage@synthetic".serviceConfig.ExecStart;
  provisionScript =
    hostSystem.config.systemd.services."provision-guest@synthetic".serviceConfig.ExecStart;
  lvmPrepareScript =
    lvmHostSystem.config.systemd.services."prepare-guest-storage@lvm".serviceConfig.ExecStart;
  lvmProvisionScript =
    lvmHostSystem.config.systemd.services."provision-guest@lvm".serviceConfig.ExecStart;
in
pkgs.runCommand "synthetic-host-guest-check"
  {
    nativeBuildInputs = [ pkgs.gnugrep ];
  }
  ''
    grep -F -- "<uuid>" ${domain.definition} >/dev/null
    grep -F -- "<source file='/var/lib/libvirt/images/synthetic.img'/>" ${domain.definition} >/dev/null
    grep -F -- "root=/dev/disk/by-partlabel/disk-main-root" ${domain.definition} >/dev/null
    grep -F -- "rootfstype=btrfs" ${domain.definition} >/dev/null
    grep -F -- "rootflags=subvol=@root" ${domain.definition} >/dev/null
    grep -F -- "<model type='virtio' heads='1' primary='yes'/>" ${domain.definition} >/dev/null

    grep -F -- "IMAGE_PATH=/var/lib/libvirt/images/synthetic.img" ${prepareScript} >/dev/null

    grep -F -- "#synthetic-guest" ${provisionScript} >/dev/null
    grep -F -- "--disk main" ${provisionScript} >/dev/null
    grep -F -- "TARGET_DEV=/var/lib/libvirt/images/synthetic.img" ${provisionScript} >/dev/null

    grep -F -- "VG_NAME=vg-test" ${lvmPrepareScript} >/dev/null
    grep -F -- '/bin/vgs "$VG_NAME"' ${lvmPrepareScript} >/dev/null
    grep -F -- "Volume group '\$VG_NAME' does not exist." ${lvmPrepareScript} >/dev/null
    grep -F -- '/bin/lvs "$LV_PATH"' ${lvmPrepareScript} >/dev/null
    grep -F -- '/bin/lvcreate -L 8G -n lvm "$VG_NAME"' ${lvmPrepareScript} >/dev/null
    grep -F -- "TARGET_DEV=/dev/vg-test/lvm" ${lvmProvisionScript} >/dev/null

    touch "$out"
  ''
