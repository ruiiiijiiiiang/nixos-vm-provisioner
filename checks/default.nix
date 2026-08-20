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

          virtualisation.nixos-vm-provisioner.guest.enable = true;

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
          virtualisation.nixos-vm-provisioner.guest.enable = true;
        }
      )
    ];
  };

  customGuestSystem = nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      self.nixosModules.guest
      (
        { ... }:
        {
          system.stateVersion = "26.05";
          virtualisation.nixos-vm-provisioner.guest.enable = true;
          virtualisation.nixos-vm-provisioner.guest.extraPartitions = {
            data = {
              size = "10G";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/data";
              };
            };
          };
        }
      )
    ];
  };

  disabledGuestSystem = nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      self.nixosModules.guest
      (
        { ... }:
        {
          system.stateVersion = "26.05";
          virtualisation.nixos-vm-provisioner.guest.enable = false;
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

          virtualisation.nixos-vm-provisioner.host = {
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

          virtualisation.nixos-vm-provisioner.host = {
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

  invalidHostSystem = nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      self.nixosModules.host
      (
        { ... }:
        {
          system.stateVersion = "26.05";

          virtualisation.nixos-vm-provisioner.host = {
            enable = true;
            guests.invalid.nixosConfig = disabledGuestSystem;
          };
        }
      )
    ];
  };

  invalidHostEvaluation = builtins.tryEval (
    builtins.deepSeq invalidHostSystem.config.system.build.toplevel true
  );

  makeInvalidStorageHost = guest: {
    inherit system;
    modules = [
      self.nixosModules.host
      (
        { ... }:
        {
          system.stateVersion = "26.05";
          virtualisation.nixos-vm-provisioner.host = {
            enable = true;
            guests.invalid = guest // { nixosConfig = guestSystem; };
          };
        }
      )
    ];
  };

  invalidLvmHostEvaluation = builtins.tryEval (
    builtins.deepSeq
      (nixpkgs.lib.nixosSystem (makeInvalidStorageHost { storage.type = "lvm"; })).config.system.build.toplevel
      true
  );

  invalidPhysicalHostEvaluation = builtins.tryEval (
    builtins.deepSeq
      (nixpkgs.lib.nixosSystem (makeInvalidStorageHost { storage.type = "physical"; })).config.system.build.toplevel
      true
  );

  invalidFileHostEvaluation = builtins.tryEval (
    builtins.deepSeq
      (nixpkgs.lib.nixosSystem (makeInvalidStorageHost { storage.size = ""; })).config.system.build.toplevel
      true
  );

  pciHostSystem = nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      self.nixosModules.host
      (
        { ... }:
        {
          system.stateVersion = "26.05";
          virtualisation.nixos-vm-provisioner.host = {
            enable = true;
            guests.pci = {
              storage.type = "physical";
              storage.device = "/dev/vdb";
              nixosConfig = guestSystem;
              pciDevices = [
                {
                  address = "0000:e5:00.0";
                  id = "1002:1682";
                }
              ];
            };
          };
        }
      )
    ];
  };

  forceHostSystem = nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      self.nixosModules.host
      (
        { ... }:
        {
          system.stateVersion = "26.05";
          virtualisation.nixos-vm-provisioner.host = {
            enable = true;
            guests.forced = {
              nixosConfig = guestSystem;
              forceProvision = true;
              flakeRef = "github:example/infra";
              flakeAttr = "some-guest";
              diskoDisk = "custom-disk";
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
  pciDomain =
    builtins.head
      pciHostSystem.config.virtualisation.libvirt.connections."qemu:///system".domains;
  pciProvisionScript =
    pciHostSystem.config.systemd.services."provision-guest@pci".serviceConfig.ExecStart;
  forceProvisionScript =
    forceHostSystem.config.systemd.services."provision-guest@forced".serviceConfig.ExecStart;
in
pkgs.runCommand "synthetic-host-guest-check"
  {
    nativeBuildInputs = [ pkgs.gnugrep ];
  }
  ''
    grep -F -- "<uuid>" ${domain.definition} >/dev/null
    grep -F -- "<vcpu placement='static'>2</vcpu>" ${domain.definition} >/dev/null
    grep -F -- "<topology sockets='1' dies='1' cores='2' threads='1'/>" ${domain.definition} >/dev/null
    grep -F -- "<loader readonly='yes' secure='no' type='pflash'>/run/libvirt/nix-ovmf/edk2-x86_64-code.fd</loader>" ${domain.definition} >/dev/null
    grep -F -- "<nvram template='/run/libvirt/nix-ovmf/edk2-i386-vars.fd'>/var/lib/nixos-vm-provisioner/nvram/synthetic_VARS.fd</nvram>" ${domain.definition} >/dev/null
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
    grep -F -- 'touch "$MARKER_PATH"' ${provisionScript} >/dev/null
    grep -F -- "already has signatures and forceProvision is disabled" ${provisionScript} >/dev/null
    grep -F -- "losetup" ${provisionScript} >/dev/null
    if grep -F -- "--no-bootloader" ${provisionScript} >/dev/null; then
      echo "provisioning unexpectedly disables guest bootloader installation" >&2
      exit 1
    fi

    grep -F -- "VG_NAME=vg-test" ${lvmPrepareScript} >/dev/null
    grep -F -- 'vgs "$VG_NAME"' ${lvmPrepareScript} >/dev/null
    grep -F -- "Volume group '\$VG_NAME' does not exist." ${lvmPrepareScript} >/dev/null
    grep -F -- 'lvs "$LV_PATH"' ${lvmPrepareScript} >/dev/null
    grep -F -- 'lvcreate -y -L 8G -n lvm "$VG_NAME"' ${lvmPrepareScript} >/dev/null
    grep -F -- "TARGET_DEV=/dev/vg-test/lvm" ${lvmProvisionScript} >/dev/null
    if grep -F -- "losetup" ${lvmProvisionScript} >/dev/null; then
      echo "LVM provisioning unexpectedly uses losetup" >&2
      exit 1
    fi
    test "${
      if
        builtins.elem "d /var/lib/nixos-vm-provisioner 0755 root root -" hostSystem.config.systemd.tmpfiles.rules
      then
        "1"
      else
        "0"
    }" = "1"
    test "${
      if
        builtins.elem "d /var/lib/nixos-vm-provisioner/nvram 0700 root root -" hostSystem.config.systemd.tmpfiles.rules
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

    test "${customGuestSystem.config.disko.devices.disk.primary.content.partitions.data.size}" = "10G"
    test "${customGuestSystem.config.disko.devices.disk.primary.content.partitions.data.content.mountpoint}" = "/data"

    test "${if invalidHostEvaluation.success then "0" else "1"}" = "1"
    test "${if invalidLvmHostEvaluation.success then "0" else "1"}" = "1"
    test "${if invalidPhysicalHostEvaluation.success then "0" else "1"}" = "1"
    test "${if invalidFileHostEvaluation.success then "0" else "1"}" = "1"

    grep -F -- "<source dev='/dev/vdb'/>" ${pciDomain.definition} >/dev/null
    grep -F -- "<hostdev mode='subsystem' type='pci' managed='yes'>" ${pciDomain.definition} >/dev/null
    grep -F -- "<address domain='0' bus='229' slot='0' function='0'/>" ${pciDomain.definition} >/dev/null
    test "${
      if builtins.elem "vfio-pci.ids=1002:1682" pciHostSystem.config.boot.kernelParams then "1" else "0"
    }" = "1"
    if grep -F -- "losetup" ${pciProvisionScript} >/dev/null; then
      echo "physical provisioning unexpectedly uses losetup" >&2
      exit 1
    fi

    grep -F -- "github:example/infra#some-guest" ${forceProvisionScript} >/dev/null
    grep -F -- "--disk custom-disk" ${forceProvisionScript} >/dev/null
    grep -F -- "already has signatures, but forceProvision is enabled" ${forceProvisionScript} >/dev/null

    touch "$out"
  ''
