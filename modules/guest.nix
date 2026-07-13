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
    extraPartitions = mkOption {
      type = types.attrsOf types.attrs;
      default = { };
      description = "Extra disko partitions to define on the primary disk.";
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
              priority = mkDefault 1;
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
              priority = mkDefault 500;
              size = config.nixos-vm-provisioner.guest.swapSize;
              content = {
                type = "swap";
                discardPolicy = "both";
              };
            };
            root = {
              priority = mkDefault 1000;
              size = "100%";
              content = {
                type = "filesystem";
                format = config.nixos-vm-provisioner.guest.rootFormat;
                mountpoint = "/";
              };
            };
          }
          // config.nixos-vm-provisioner.guest.extraPartitions;
        };
      };
    };

    boot = {
      loader = {
        systemd-boot.enable = mkDefault true;
      };
      growPartition = mkDefault true;
      kernel = {
        sysctl = {
          "vm.swappiness" = mkDefault 10;
        };
      };
      initrd = {
        availableKernelModules = [
          "virtio_pci"
          "virtio_blk"
          "virtio_net"
          "virtio_fs"
          "virtio_console"
          "sd_mod"
          "sr_mod"
        ];
      };
      kernelParams = [
        "console=tty0"
        "console=ttyS0"
      ];
    };

    fileSystems = {
      "/".autoResize = mkDefault true;
    };

    services = {
      qemuGuest.enable = mkDefault true;
    };
  };
}
