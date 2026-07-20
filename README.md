# NixOS-VM-Provisioner

`nixos-vm-provisioner` is a pair of NixOS modules for host-managed VM installation.

The host creates the guest's backing storage, runs `disko-install` once against an unformatted target, and then boots the guest from its own disk through libvirt and NixVirt.

## Compared to MicroVM-Style Workflows

This project is primarily a first-boot provisioning tool, not a packaging format for tightly host-managed VMs.

Unlike `microvm`-style workflows where the guest runtime is often rebuilt and redeployed as part of the host configuration, this module installs a normal NixOS system onto its own disk and then leaves that disk alone after provisioning. The guest owns its own bootloader, kernel, and initrd, so later guest-side upgrades follow the normal NixOS model.

## Modules

- `nixosModules.host`: defines storage, provisioning services, and libvirt domains on the hypervisor.
- `nixosModules.guest`: prepares a guest system for guest-managed UEFI boot on a libvirt VM disk.

## Quick Start

The simplest setup is:

- one host flake that defines both the hypervisor and the guest
- one guest that uses the default Disko layout
- one file-backed disk image on the host

### 1. Add the modules to your flake

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-vm-provisioner.url = "github:ruiiiijiiiiang/nixos-vm-provisioner";
  };

  outputs = { self, nixpkgs, nixos-vm-provisioner, ... }: {
    nixosConfigurations.hypervisor = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        nixos-vm-provisioner.nixosModules.host
        ./host-config.nix
      ];
    };

    nixosConfigurations.my-guest = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        nixos-vm-provisioner.nixosModules.guest
        ./guest-config.nix
      ];
    };
  };
}
```

### 2. Define the guest

Minimal guest configuration:

```nix
{
  nixos-vm-provisioner.guest.enable = true;
}
```

### 3. Define the host

Minimal host configuration:

```nix
{ inputs, ... }: {
  virtualisation.nixos-vm-provisioner = {
    enable = true;
    guests.my-guest.nixosConfig = inputs.self.nixosConfigurations.my-guest;
  };
}
```

With that configuration, the host will provision and boot `my-guest` with the module defaults.

### Quick Start Defaults

The quick start above uses these defaults:

- guest CPU: `2`
- guest memory: `2048` MiB
- storage backend: `file`
- storage size: `20G`
- file image path: `/var/lib/libvirt/images/<guest-name>.img`
- host state path: `/var/lib/nixos-vm-provisioner`
- guest auto-start: `true`
- guest root device: `/dev/vda`
- guest ESP size: `512M`
- guest root filesystem format: `ext4`
- guest swap size: `null` (disabled)
- provisioning flake target: `inputs.self.outPath#<guest-name>`
- Disko disk name: `primary`
- guest bootloader: `systemd-boot`

The guest module also provides a default Disko layout:

- GPT partition table
- one EFI System Partition mounted at `/boot`
- one root filesystem mounted at `/` (format defined by `rootFormat`)
- optional swap partition (defined by `swapSize`, disabled by default)

So the minimal quick start does not require:

- `volumeGroup`
- a custom `disko.devices`
- a custom `storage.type`

### Common First Tweaks

If you want a slightly less minimal setup, this is a common starting point:

```nix
{ inputs, ... }: {
  virtualisation.nixos-vm-provisioner = {
    enable = true;

    nixvirtDefaults = {
      devices.network = [
        {
          type = "network";
          source.network = "default";
        }
      ];
    };

    guests.my-guest = {
      cpu = 4;
      memory = 8192;
      storage.size = "50G";
      nixosConfig = inputs.self.nixosConfigurations.my-guest;
    };
  };
}
```

## Alternatives

### Storage Backends

`file` is the default because it is the easiest quick-start path.

```nix
guests.my-guest = {
  storage.type = "file";
  storage.size = "50G";
  # Optional: storage.imagePath = "/srv/vms/my-guest.img";
  nixosConfig = inputs.self.nixosConfigurations.my-guest;
};
```

Use `lvm` when the guest disk should be an LV on an existing volume group:

```nix
{
  virtualisation.nixos-vm-provisioner = {
    enable = true;
    volumeGroup = "vg0";

    guests.my-guest = {
      storage.type = "lvm";
      storage.size = "50G";
      nixosConfig = inputs.self.nixosConfigurations.my-guest;
    };
  };
}
```

Use `physical` when the guest should be installed directly onto a block device:

```nix
guests.my-guest = {
  storage.type = "physical";
  storage.device = "/dev/disk/by-id/...";
  nixosConfig = inputs.self.nixosConfigurations.my-guest;
};
```

### Custom Disk Layouts

`nixos-vm-provisioner` uses `disko` for partitioning and formatting. You can customize the layout via modular guest options, by appending custom partitions, or by writing a fully custom `disko.devices` configuration.

#### 1. Guest Module Options

Tweak the default partition layout (GPT with ESP, root, and optional swap) using these guest options:

- `rootDevice` (default: `"/dev/vda"`): Block device inside the VM.
- `espSize` (default: `"512M"`): Size of the EFI system partition (ESP).
- `rootFormat` (default: `"ext4"`): Filesystem type for the root partition.
- `swapSize` (default: `null`): Swap partition size (disabled by default).

#### 2. Adding Extra Partitions (`extraPartitions`)

To define extra partitions without redefining the whole layout, specify them under `extraPartitions` (which takes standard `disko` partition structures):

```nix
nixos-vm-provisioner.guest.extraPartitions.data = {
  size = "10G";
  content = {
    type = "filesystem";
    format = "ext4";
    mountpoint = "/data";
  };
};
```

_Note: ESP is priority 1, swap is 500, and root is 1000. Custom partitions default to alphabetical ordering and are placed sequentially before the `root` partition (which has `size = "100%"`)._

#### 3. Fully Custom Configuration

If you need complex layouts (e.g., Btrfs subvolumes, LUKS, or multiple disks), declare `disko.devices` directly in the guest configuration. Since the default layout is declared with `lib.mkDefault`, your custom declaration will completely override it.

If your custom configuration uses a disk key other than `"primary"` (e.g. `disk.main`), configure `diskoDisk` on the host side:

```nix
guests.my-guest = {
  nixosConfig = inputs.self.nixosConfigurations.my-guest;
  diskoDisk = "main"; # Must match the disk name in guest's disko.devices.disk.<name>
};
```

### Provisioning From Another Flake or Another Attribute

By default, the host provisions `inputs.self.outPath#<guest-name>`.

Override `flakeRef` or `flakeAttr` when:

- the guest lives in another flake
- the guest name on the host does not match the NixOS configuration attribute name

```nix
guests.my-guest = {
  nixosConfig = inputs.self.nixosConfigurations.some-guest;
  flakeRef = "github:example/infra";
  flakeAttr = "some-guest";
};
```

### PCI Device Passthrough

To pass physical PCI devices (like GPUs, NICs, etc.) directly to a guest VM, configure the `pciDevices` option on the host's guest definition:

```nix
guests.my-guest = {
  nixosConfig = inputs.self.nixosConfigurations.my-guest;
  pciDevices = [
    {
      address = "0000:e5:00.0";
      id = "1002:1682";
    }
  ];
};
```

When one or more `pciDevices` are configured:

1. The host's `boot.kernelParams` and `boot.initrd.kernelModules` are automatically updated to bind the specified PCI Vendor:Device IDs to `vfio-pci` at boot.
2. Libvirt QEMU is configured to run as root (required for QEMU to manage VFIO devices).
3. The guest's libvirt XML definition is automatically populated with the corresponding `<hostdev>` blocks.

### Guest Customization

The guest module (`nixosModules.guest`) provides options to customize the partitioning, filesystems, QEMU agent, and kernel parameters directly in the guest configuration:

```nix
# guest-config.nix
{
  nixos-vm-provisioner.guest = {
    enable = true;

    # Target device for disko (default: "/dev/vda")
    rootDevice = "/dev/vda";

    # EFI System Partition (ESP) size (default: "512M")
    espSize = "1G";

    # Root filesystem format (default: "ext4")
    rootFormat = "btrfs";

    # Optional swap partition size (default: null / disabled)
    swapSize = "4G";

    # Extra partitions to define on the primary disk
    extraPartitions = {
      data = {
        size = "10G";
        content = {
          type = "filesystem";
          format = "ext4";
          mountpoint = "/data";
        };
      };
    };
  };
}
```

### Libvirt and NixVirt Customization

Set host-wide defaults with `nixvirtDefaults`:

```nix
virtualisation.nixos-vm-provisioner.nixvirtDefaults = {
  devices.network = [
    {
      type = "network";
      source.network = "default";
    }
  ];
};
```

Set per-guest overrides on the host with `nixvirtExtraConfigs`:

```nix
guests.my-guest = {
  nixosConfig = inputs.self.nixosConfigurations.my-guest;
  nixvirtExtraConfigs = {
    devices.video = [ { model.type = "qxl"; } ];
  };
};
```

The `cpu` guest option sets the total vCPU count. By default, the provisioner
represents those vCPUs as one socket with `cpu` cores and one thread per core.
Override the topology for a specific guest through `nixvirtExtraConfigs` when
needed, ensuring that the topology product matches `cpu`:

```nix
guests.my-guest = {
  cpu = 8;
  nixvirtExtraConfigs.cpu.topology = {
    sockets = 1;
    dies = 1;
    cores = 4;
    threads = 2;
  };
};
```

## How It Works

1. The host prepares the guest's backing storage.
2. On first boot, a systemd service checks for a host-managed provisioning marker file at `<statePath>/<guest-name>.provisioned` (defaulting to `/var/lib/nixos-vm-provisioner/<guest-name>.provisioned`).
3. If the marker is missing and the target is still blank (or `forceProvision` is enabled), the host runs `disko-install` against the configured flake target and disk mapping.
4. The guest installs its own UEFI bootloader onto its disk during provisioning.
5. The host keeps a persistent per-guest NVRAM file under `/var/lib/nixos-vm-provisioner/nvram/`.
6. After the first successful provisioning run, the host records the marker file and reuses the guest disk as-is on later boots.
7. Libvirt boots the guest from its own disk through OVMF.

## Safety & Re-provisioning

To prevent accidental data loss, `nixos-vm-provisioner` implements multiple guardrails:

1. **Provisioning Marker File**:
   After a guest is successfully provisioned, a marker file is created on the host at `<statePath>/<guest-name>.provisioned` (which defaults to `/var/lib/nixos-vm-provisioner/<guest-name>.provisioned`). If this file exists, the host-managed provisioner always skips formatting and provisioning.
2. **Signature Detection**:
   If the marker file does not exist, the provisioner checks the backing device for existing filesystems/signatures (using `blkid`). If any signature is found, the provisioner will **safely skip provisioning** and create the marker file to prevent formatting an already-used disk.
3. **Force Provisioning (`forceProvision`)**:
   If you want to intentionally overwrite/re-provision a disk that already contains signatures, you can set the `forceProvision` option to `true` on the guest configuration:

   ```nix
   guests.my-guest = {
     nixosConfig = inputs.self.nixosConfigurations.my-guest;
     forceProvision = true;
   };
   ```

   Alternatively, you can manually delete the marker file from the host at `/var/lib/nixos-vm-provisioner/<guest-name>.provisioned` (and ensure the backing disk is blank/wiped or `forceProvision` is enabled) to trigger a clean provisioning run.

## Requirements

- The guest system must import `nixos-vm-provisioner.nixosModules.guest`.
- The host system must import `nixos-vm-provisioner.nixosModules.host`.
- The guest system must match the host architecture.
- The guest configuration must install a UEFI-bootable system onto the configured disk.
- `volumeGroup` is required only for `storage.type = "lvm"`.

## Contributing

Contributions are welcome. Bug reports, design feedback, documentation improvements, and implementation changes are all useful.

## License

This project is released under The Unlicense. See `LICENSE`.
