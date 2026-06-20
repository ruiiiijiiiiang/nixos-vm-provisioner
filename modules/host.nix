{
  config,
  lib,
  pkgs,
  inputs,
  options,
  ...
}:

with lib;

let
  cfg = config.virtualisation.nixos-vm-provisioner;
  hasPciGuest = lib.any (guest: guest.pciDevices != [ ]) (attrValues cfg.guests);
  passthroughIds = lib.unique (
    lib.concatMap (guest: map (dev: dev.id) guest.pciDevices) (attrValues cfg.guests)
  );

  parsePciAddress =
    address:
    let
      parts = builtins.match "([0-9a-fA-F]{4}):([0-9a-fA-F]{2}):([0-9a-fA-F]{2})\\.([0-7])" address;
    in
    if parts == null then
      throw "Invalid PCI address: ${address}"
    else
      {
        domain = "0x" + lib.head parts;
        bus = "0x" + lib.elemAt parts 1;
        slot = "0x" + lib.elemAt parts 2;
        function = "0x" + lib.elemAt parts 3;
      };

  guestOpts =
    { name, config, ... }:
    {
      options = {
        cpu = mkOption {
          type = types.ints.positive;
          default = 2;
          description = "Number of CPU cores.";
        };
        memory = mkOption {
          type = types.ints.positive;
          default = 2048;
          description = "Amount of RAM in MiB.";
        };
        storage = {
          type = mkOption {
            type = types.enum [
              "lvm"
              "physical"
              "file"
            ];
            default = "file";
            description = "Storage backend type. Defaults to 'file' for a simple quick start.";
          };
          size = mkOption {
            type = types.str;
            default = "20G";
            description = "Size of the storage (e.g., 20G). Not needed for 'physical'.";
          };
          device = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Path to the physical device (only for 'physical' type).";
          };
          imagePath = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Path for the image file (only for 'file' type). Defaults to cfg.storagePath/name.img.";
          };
        };
        nixosConfig = mkOption {
          type = types.unspecified;
          description = "The NixOS configuration for the guest.";
        };
        flakeRef = mkOption {
          type = types.str;
          default = toString inputs.self.outPath;
          description = "Flake URI or path passed to disko-install for this guest.";
        };
        flakeAttr = mkOption {
          type = types.str;
          default = name;
          description = "NixOS configuration attribute name passed to disko-install.";
        };
        diskoDisk = mkOption {
          type = types.str;
          default = "primary";
          description = "Disko disk name passed to disko-install via --disk.";
        };
        uuid = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Libvirt domain UUID. Defaults to a deterministic value derived from the guest name.";
        };
        pciDevices = mkOption {
          type = types.listOf (
            types.submodule {
              options = {
                address = mkOption {
                  type = types.str;
                  description = "PCI address of the device (e.g. '0000:e5:00.0').";
                };
                id = mkOption {
                  type = types.str;
                  description = "PCI Vendor:Device ID (e.g. '1002:1682').";
                };
              };
            }
          );
          default = [ ];
          description = "PCI devices to pass through to the guest.";
        };
        forceProvision = mkOption {
          type = types.bool;
          default = false;
          description = "Force provisioning/formatting even if the disk already has signatures.";
        };
        autoStart = mkOption {
          type = types.bool;
          default = true;
          description = "Whether the VM should automatically start.";
        };
        nixvirtExtraConfigs = mkOption {
          type = types.attrs;
          default = { };
          description = "Extra NixVirt domain configuration options specific to this guest.";
        };
      };
    };

  getImagePath =
    name: guest:
    if guest.storage.imagePath != null then
      guest.storage.imagePath
    else
      "${cfg.storagePath}/${name}.img";

  getTargetDev =
    name: guest:
    if guest.storage.type == "lvm" then
      "/dev/${cfg.volumeGroup}/${name}"
    else if guest.storage.type == "physical" then
      guest.storage.device
    else
      getImagePath name guest;

  getGuestInstallFlakeRef = _name: guest: "${guest.flakeRef}#${guest.flakeAttr}";

  getGuestProvisionMarker = name: "${cfg.statePath}/${name}.provisioned";

  makeStableUuid =
    seed:
    let
      hash = builtins.hashString "sha256" seed;
    in
    "${substring 0 8 hash}-${substring 8 4 hash}-4${substring 13 3 hash}-a${substring 17 3 hash}-${substring 20 12 hash}";

  getGuestUuid =
    name: guest:
    if guest.uuid != null then guest.uuid else makeStableUuid "nixos-vm-provisioner:${name}";

  makeDomain = name: guest: {
    definition = inputs.NixVirt.lib.domain.writeXML (
      lib.foldl' lib.recursiveUpdate { } [
        (inputs.NixVirt.lib.domain.templates.linux {
          inherit name;
          uuid = getGuestUuid name guest;
          vcpu.count = guest.cpu;
          memory = {
            count = guest.memory;
            unit = "MiB";
          };
          # Use NixVirt's virtio video path without accel3d.
          virtio_video = null;
        })
        cfg.nixvirtDefaults
        {
          vcpu.placement = "static";
          os = {
            loader = {
              readonly = true;
              secure = false;
              type = "pflash";
              path = cfg.loaderCodePath;
            };
            nvram = {
              template = cfg.loaderVarsPath;
              path = "${cfg.statePath}/nvram/${name}_VARS.fd";
            };
            boot = [ { dev = "hd"; } ];
          };
          devices = {
            disk = [
              {
                type = if guest.storage.type == "file" then "file" else "block";
                device = "disk";
                driver = {
                  name = "qemu";
                  type = "raw";
                  cache = "none";
                  io = "native";
                  discard = "unmap";
                };
                source = {
                  dev = if guest.storage.type != "file" then (getTargetDev name guest) else null;
                  file = if guest.storage.type == "file" then (getTargetDev name guest) else null;
                };
                target = {
                  dev = "vda";
                  bus = "virtio";
                };
              }
            ];
            serial = [
              {
                type = "pty";
                target = {
                  type = "isa-serial";
                  port = 0;
                };
              }
            ];
            console = [
              {
                type = "pty";
                target = {
                  type = "serial";
                  port = 0;
                };
              }
            ];
            panic = [ { model = "isa"; } ];
            hostdev = map (dev: {
              mode = "subsystem";
              type = "pci";
              managed = true;
              source = {
                address = parsePciAddress dev.address;
              };
            }) guest.pciDevices;
          };
        }
        guest.nixvirtExtraConfigs
      ]
    );
    active = guest.autoStart;
  };

in
{
  options.virtualisation.nixos-vm-provisioner = {
    enable = mkEnableOption "NixOS-VM-Provisioner host module";
    volumeGroup = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "LVM Volume Group for LVM-backed guests.";
    };
    storagePath = mkOption {
      type = types.str;
      default = "/var/lib/libvirt/images";
      description = "Path for file-backed guest images.";
    };
    statePath = mkOption {
      type = types.str;
      default = "/var/lib/nixos-vm-provisioner";
      description = "Path for provisioning state markers managed by the host module.";
    };
    guests = mkOption {
      type = types.attrsOf (types.submodule guestOpts);
      default = { };
      description = "Guest VM definitions.";
    };
    nixvirtDefaults = mkOption {
      type = types.attrs;
      default = { };
      description = "Default NixVirt domain configuration applied to all guests, overriding the base linux template.";
    };
    loaderCodePath = mkOption {
      type = types.str;
      default =
        let
          arch = pkgs.stdenv.hostPlatform.qemuArch;
          codeArch = if arch == "riscv64" then "riscv" else arch;
        in
        "/run/libvirt/nix-ovmf/edk2-${codeArch}-code.fd";
      description = "Path to the UEFI/OVMF firmware code file.";
    };
    loaderVarsPath = mkOption {
      type = types.str;
      default =
        let
          arch = pkgs.stdenv.hostPlatform.qemuArch;
          varsArch =
            if arch == "x86_64" then
              "i386"
            else if arch == "aarch64" then
              "arm"
            else if arch == "riscv64" then
              "riscv"
            else
              arch;
        in
        "/run/libvirt/nix-ovmf/edk2-${varsArch}-vars.fd";
      description = "Path to the UEFI/OVMF firmware variables template file.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = options.virtualisation ? libvirt;
        message = "NixOS-VM-Provisioner host module requires NixVirt. Ensure NixVirt's NixOS module is imported.";
      }
    ]
    ++ flatten (
      mapAttrsToList (name: guest: [
        {
          assertion =
            guest.nixosConfig ? config
            && guest.nixosConfig.config ? system
            && guest.nixosConfig.config.system ? build;
          message = "Guest VM '${name}' nixosConfig must be a valid NixOS system (e.g., self.nixosConfigurations.name).";
        }
        {
          assertion = guest.nixosConfig.config.nixos-vm-provisioner.guest.enable or false;
          message = "Guest VM '${name}' must have 'nixos-vm-provisioner.guest.enable = true;' set in its configuration.";
        }
        {
          assertion =
            hasAttrByPath [ "pkgs" "stdenv" "hostPlatform" "system" ] guest.nixosConfig
            && guest.nixosConfig.pkgs.stdenv.hostPlatform.system == pkgs.stdenv.hostPlatform.system;
          message = "Guest VM '${name}' system must match the host system.";
        }
        {
          assertion =
            (guest.storage.type == "physical") || (guest.storage.size != "" && guest.storage.size != null);
          message = "Guest VM '${name}' storage.size must be specified for type '${guest.storage.type}'.";
        }
        {
          assertion = (guest.storage.type == "lvm") -> (cfg.volumeGroup != null);
          message = "Host 'volumeGroup' must be specified for LVM-backed guest '${name}'.";
        }
        {
          assertion = (guest.storage.type == "physical") -> (guest.storage.device != null);
          message = "Guest VM '${name}' storage.device must be specified for type 'physical'.";
        }
      ]) cfg.guests
    );

    boot = lib.mkIf hasPciGuest {
      kernelParams = [
        "amd_iommu=on"
        "intel_iommu=on"
        "iommu=pt"
        "vfio"
        "vfio_pci"
        "vfio-pci.ids=${lib.concatStringsSep "," passthroughIds}"
        "vfio_iommu_type1"
        "video=efifb:off"
      ];
      initrd.kernelModules = [
        "vfio"
        "vfio_pci"
        "vfio_iommu_type1"
      ];
    };

    virtualisation = {
      libvirtd = {
        enable = true;
        qemu = {
          package = lib.mkDefault pkgs.qemu_kvm;
        }
        // lib.optionalAttrs hasPciGuest {
          runAsRoot = true;
          verbatimConfig = ''
            user = "root"
            group = "root"
          '';
        };
      };

      libvirt = {
        enable = true;
        connections."qemu:///system".domains = mapAttrsToList (
          name: guest: makeDomain name guest
        ) cfg.guests;
      };
    };

    systemd = {
      services = mkMerge (
        mapAttrsToList (name: guest: {
          "prepare-guest-storage@${name}" = {
            description = "Prepare storage for guest ${name}";
            wantedBy = [ "multi-user.target" ];
            before = [ "provision-guest@${name}.service" ];
            path = with pkgs; [
              coreutils
              config.virtualisation.libvirtd.qemu.package
              lvm2.bin
            ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart =
                if guest.storage.type == "lvm" then
                  pkgs.writeShellScript "create-lvm-${name}" ''
                    VG_NAME=${escapeShellArg cfg.volumeGroup}
                    LV_PATH=${escapeShellArg "${cfg.volumeGroup}/${name}"}
                    if ! vgs "$VG_NAME" >/dev/null 2>&1; then
                      echo "Volume group '$VG_NAME' does not exist." >&2
                      exit 1
                    fi
                    if ! lvs "$LV_PATH" >/dev/null 2>&1; then
                      lvcreate -y -L ${escapeShellArg guest.storage.size} -n ${escapeShellArg name} "$VG_NAME"
                    fi
                  ''
                else if guest.storage.type == "file" then
                  pkgs.writeShellScript "create-file-${name}" ''
                    IMAGE_PATH=${escapeShellArg (getImagePath name guest)}
                    mkdir -p "$(dirname "$IMAGE_PATH")"
                    if [ ! -f "$IMAGE_PATH" ]; then
                      qemu-img create -f raw "$IMAGE_PATH" ${escapeShellArg guest.storage.size}
                    fi
                  ''
                else
                  "true";
            };
          };

          "provision-guest@${name}" = {
            description = "Provision NixOS guest ${name}";
            wantedBy = [ "multi-user.target" ];
            after = [ "prepare-guest-storage@${name}.service" ];
            before = [ "libvirtd.service" ];
            partOf = [ "libvirtd.service" ];
            path = with pkgs; [
              coreutils
              util-linux
              inputs.disko.packages.${pkgs.system}.disko-install
            ];

            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = pkgs.writeShellScript "provision-${name}" ''
                TARGET_DEV=${escapeShellArg (getTargetDev name guest)}
                MARKER_PATH=${escapeShellArg (getGuestProvisionMarker name)}
                mkdir -p "$(dirname "$MARKER_PATH")"

                run_disko_install() {
                  ${
                    if guest.storage.type == "physical" then
                      ''
                        disko-install --flake ${escapeShellArg (getGuestInstallFlakeRef name guest)} --disk ${escapeShellArg guest.diskoDisk} "$TARGET_DEV"
                      ''
                    else
                      ''
                        # We must use a loop device so that partition block devices are created.
                        LOOP_DEV=$(losetup --show -fP "$TARGET_DEV")
                        cleanup() {
                          echo "Cleaning up mounts and loop device $LOOP_DEV"
                          umount -R /mnt/disko-install-root || true
                          losetup -d "$LOOP_DEV" || true
                        }
                        trap cleanup EXIT
                        disko-install --flake ${escapeShellArg (getGuestInstallFlakeRef name guest)} --disk ${escapeShellArg guest.diskoDisk} "$LOOP_DEV"
                      ''
                  }
                }

                if [ -e "$MARKER_PATH" ]; then
                  echo "Guest ${name} was already provisioned by nixos-vm-provisioner. Skipping provisioning."
                elif ! blkid "$TARGET_DEV" >/dev/null 2>&1; then
                  echo "Device $TARGET_DEV is unformatted. Starting disko-install..."
                  run_disko_install
                  touch "$MARKER_PATH"
                elif ${if guest.forceProvision then "true" else "false"}; then
                  echo "Device $TARGET_DEV already has signatures, but forceProvision is enabled. Forcing disko-install..."
                  run_disko_install
                  touch "$MARKER_PATH"
                else
                  echo "Device $TARGET_DEV already has signatures and forceProvision is disabled. Safely skipping provisioning."
                  touch "$MARKER_PATH"
                fi
              '';
            };
          };
        }) cfg.guests
      );

      tmpfiles.rules = [
        "d ${cfg.statePath} 0755 root root -"
        "d ${cfg.statePath}/nvram 0700 root root -"
      ];
    };
  };
}
