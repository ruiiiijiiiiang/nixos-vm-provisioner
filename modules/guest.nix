{ config, lib, ... }:

with lib;

{
  options.nixos-vm-provisioner.guest = {
    enable = mkEnableOption "NixOS-VM-Provisioner Guest configuration";
    rootDevice = mkOption {
      type = types.str;
      default = "/dev/vda";
      description = "The root device for the guest.";
    };
    autoStart = mkOption {
      type = types.bool;
      default = true;
      description = "Whether the VM should automatically start.";
    };
    nixvirtExtraConfigs = mkOption {
      type = types.attrs;
      default = { };
      description = "Extra NixVirt attribute sets to merge into the domain definition.";
    };
  };

  config = mkIf config.nixos-vm-provisioner.guest.enable {
    disko.devices = mkDefault {
      disk.primary = {
        type = "disk";
        device = config.nixos-vm-provisioner.guest.rootDevice;
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "512M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "umask=0077" ];
              };
            };
            root = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          };
        };
      };
    };

    boot = {
      loader = {
        systemd-boot.enable = mkDefault true;
      };

      kernelParams = [
        "console=ttyS0"
        "console=tty0"
      ];

      initrd.availableKernelModules = [
        "virtio_pci"
        "virtio_blk"
        "virtio_net"
        "virtio_balloon"
        "virtio_console"
      ];
    };
  };
}
