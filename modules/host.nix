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
  hasLvmGuest = lib.any (guest: guest.storage.type == "lvm") (attrValues cfg.guests);

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

  makeStableUuid =
    seed:
    let
      hash = builtins.hashString "sha256" seed;
    in
    "${substring 0 8 hash}-${substring 8 4 hash}-4${substring 13 3 hash}-a${substring 17 3 hash}-${substring 20 12 hash}";

  getGuestUuid =
    name: guest:
    if guest.uuid != null then guest.uuid else makeStableUuid "nixos-vm-provisioner:${name}";

  getGuestRootFs =
    name: guest:
    let
      rootFs = guest.nixosConfig.config.fileSystems."/";
    in
    if rootFs ? device then
      rootFs
    else
      throw "Guest VM '${name}' must define fileSystems.\"/\".device so the host can build the kernel command line.";

  getGuestRootParam =
    name: guest:
    let
      rootFs = getGuestRootFs name guest;
      rootFsType = rootFs.fsType or null;
      rootFlags = lib.filter (opt: lib.hasPrefix "subvol=" opt || lib.hasPrefix "subvolid=" opt) (
        rootFs.options or [ ]
      );
      bootArgs =
        if rootFsType == "zfs" then
          [ "zfs=${rootFs.device}" ]
        else
          [ "root=${rootFs.device}" ]
          ++ lib.optional (rootFsType != null && rootFsType != "") "rootfstype=${rootFsType}"
          ++ lib.optional (rootFlags != [ ]) "rootflags=${concatStringsSep "," rootFlags}";
    in
    concatStringsSep " " (bootArgs ++ [ "rw" ] ++ (guest.nixosConfig.config.boot.kernelParams or [ ]));

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
            kernel.path = "${guest.nixosConfig.config.system.build.kernel}/${guest.nixosConfig.config.system.boot.loader.kernelFile}";
            initrd.path = toString guest.nixosConfig.config.system.build.initialRamdisk;
            cmdline.options = getGuestRootParam name guest;
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
          };
        }
        guest.nixosConfig.config.nixos-vm-provisioner.guest.nixvirtExtraConfigs
      ]
    );
    active = guest.nixosConfig.config.nixos-vm-provisioner.guest.autoStart;
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
          assertion = hasAttrByPath [ "config" "fileSystems" "/" "device" ] guest.nixosConfig;
          message = "Guest VM '${name}' must define fileSystems.\"/\".device so the host can determine the kernel root device.";
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

    environment.systemPackages =
      with pkgs;
      [
        libvirt
        qemu
        inputs.disko.packages.${pkgs.system}.disko-install
      ]
      ++ lib.optional hasLvmGuest lvm2;

    virtualisation.libvirtd.enable = true;

    virtualisation.libvirt.connections."qemu:///system".domains = mapAttrsToList (
      name: guest: makeDomain name guest
    ) cfg.guests;

    systemd.services = mkMerge (
      mapAttrsToList (name: guest: {
        "prepare-guest-storage@${name}" = {
          description = "Prepare storage for guest ${name}";
          wantedBy = [ "multi-user.target" ];
          before = [ "provision-guest@${name}.service" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart =
              if guest.storage.type == "lvm" then
                pkgs.writeShellScript "create-lvm-${name}" ''
                  VG_NAME=${escapeShellArg cfg.volumeGroup}
                  LV_PATH=${escapeShellArg "${cfg.volumeGroup}/${name}"}
                  if ! ${pkgs.lvm2}/bin/vgs "$VG_NAME" >/dev/null 2>&1; then
                    echo "Volume group '$VG_NAME' does not exist." >&2
                    exit 1
                  fi
                  if ! ${pkgs.lvm2}/bin/lvs "$LV_PATH" >/dev/null 2>&1; then
                    ${pkgs.lvm2}/bin/lvcreate -L ${escapeShellArg guest.storage.size} -n ${escapeShellArg name} "$VG_NAME"
                  fi
                ''
              else if guest.storage.type == "file" then
                pkgs.writeShellScript "create-file-${name}" ''
                  IMAGE_PATH=${escapeShellArg (getImagePath name guest)}
                  ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$IMAGE_PATH")"
                  if [ ! -f "$IMAGE_PATH" ]; then
                    ${pkgs.qemu}/bin/qemu-img create -f raw "$IMAGE_PATH" ${escapeShellArg guest.storage.size}
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
            blkid
            util-linux
            inputs.disko.packages.${pkgs.system}.disko-install
          ];

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = pkgs.writeShellScript "provision-${name}" ''
              TARGET_DEV=${escapeShellArg (getTargetDev name guest)}
              if ! blkid "$TARGET_DEV" >/dev/null 2>&1; then
                echo "Device $TARGET_DEV is unformatted. Starting disko-install..."
                disko-install --flake ${escapeShellArg (getGuestInstallFlakeRef name guest)} --disk ${escapeShellArg guest.diskoDisk} "$TARGET_DEV" --no-bootloader
              else
                echo "Device $TARGET_DEV already has a partition table. Skipping provisioning."
              fi
            '';
          };
        };
      }) cfg.guests
    );
  };
}
