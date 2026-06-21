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

    espSize = mkOption {
      type = types.str;
      default = "512M";
      description = "The size of the EFI System Partition (ESP).";
    };

    rootFormat = mkOption {
      type = types.str;
      default = "ext4";
      description = "The filesystem format for the root partition.";
    };

    swapSize = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "The size of the swap partition. If null, no swap partition is created.";
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
              size = config.nixos-vm-provisioner.guest.espSize;
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = [ "umask=0077" ];
              };
            };
            swap = mkIf (config.nixos-vm-provisioner.guest.swapSize != null) {
              size = config.nixos-vm-provisioner.guest.swapSize;
              content = {
                type = "swap";
                discardPolicy = "both";
              };
            };
            root = {
              size = "100%";
              content = {
                type = "filesystem";
                format = config.nixos-vm-provisioner.guest.rootFormat;
                mountpoint = "/";
              };
            };
          };
        };
      };
    };

    boot.loader.systemd-boot.enable = mkDefault true;
  };
}
