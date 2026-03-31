{
  self,
  nixpkgs,
  system,
}:

let
  pkgs = import nixpkgs { inherit system; };

  guestSystem = nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
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

  defaultGuestSystem = nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      self.nixosModules.guest
      (
        { ... }:
        {
          system.stateVersion = "26.05";
          nixos-vm-provisioner.guest.enable = true;
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
    grep -F -- "<loader readonly='yes' secure='no' type='pflash'>/run/libvirt/nix-ovmf/edk2-x86_64-code.fd</loader>" ${domain.definition} >/dev/null
    grep -F -- "<boot dev='hd'/>" ${domain.definition} >/dev/null
    grep -F -- "<source file='/var/lib/libvirt/images/synthetic.img'/>" ${domain.definition} >/dev/null
    grep -F -- "<model type='virtio' heads='1' primary='yes'/>" ${domain.definition} >/dev/null
    if grep -F -- "<kernel>" ${domain.definition} >/dev/null; then
      echo "domain unexpectedly contains a host-managed kernel" >&2
      exit 1
    fi
    if grep -F -- "<initrd>" ${domain.definition} >/dev/null; then
      echo "domain unexpectedly contains a host-managed initrd" >&2
      exit 1
    fi

    grep -F -- "IMAGE_PATH=/var/lib/libvirt/images/synthetic.img" ${prepareScript} >/dev/null

    grep -F -- "#synthetic-guest" ${provisionScript} >/dev/null
    grep -F -- "--disk main" ${provisionScript} >/dev/null
    grep -F -- "TARGET_DEV=/var/lib/libvirt/images/synthetic.img" ${provisionScript} >/dev/null
    grep -F -- "MARKER_PATH=/var/lib/nixos-vm-provisioner/synthetic.provisioned" ${provisionScript} >/dev/null
    grep -F -- 'if [ -e "$MARKER_PATH" ]; then' ${provisionScript} >/dev/null
    grep -F -- '/bin/touch "$MARKER_PATH"' ${provisionScript} >/dev/null
    grep -F -- "already has signatures, but no provisioning marker exists" ${provisionScript} >/dev/null
    if grep -F -- "--no-bootloader" ${provisionScript} >/dev/null; then
      echo "provisioning unexpectedly disables guest bootloader installation" >&2
      exit 1
    fi

    grep -F -- "VG_NAME=vg-test" ${lvmPrepareScript} >/dev/null
    grep -F -- '/bin/vgs "$VG_NAME"' ${lvmPrepareScript} >/dev/null
    grep -F -- "Volume group '\$VG_NAME' does not exist." ${lvmPrepareScript} >/dev/null
    grep -F -- '/bin/lvs "$LV_PATH"' ${lvmPrepareScript} >/dev/null
    grep -F -- '/bin/lvcreate -L 8G -n lvm "$VG_NAME"' ${lvmPrepareScript} >/dev/null
    grep -F -- "TARGET_DEV=/dev/vg-test/lvm" ${lvmProvisionScript} >/dev/null
    test "${
      if
        builtins.elem "d /var/lib/nixos-vm-provisioner 0755 root root -" hostSystem.config.systemd.tmpfiles.rules
      then
        "1"
      else
        "0"
    }" = "1"

    test "${if defaultGuestSystem.config.boot.loader.systemd-boot.enable then "1" else "0"}" = "1"
    test "${if defaultGuestSystem.config.boot.loader.grub.enable then "1" else "0"}" = "0"
    test "${if defaultGuestSystem.config.boot.loader.efi.canTouchEfiVariables then "1" else "0"}" = "0"
    test "${defaultGuestSystem.config.disko.devices.disk.primary.content.partitions.ESP.type}" = "EF00"
    test "${defaultGuestSystem.config.disko.devices.disk.primary.content.partitions.ESP.content.format}" = "vfat"
    test "${defaultGuestSystem.config.disko.devices.disk.primary.content.partitions.ESP.content.mountpoint}" = "/boot"
    test "${defaultGuestSystem.config.disko.devices.disk.primary.content.partitions.root.content.format}" = "ext4"

    touch "$out"
  ''
