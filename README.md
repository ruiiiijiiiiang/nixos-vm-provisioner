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
- provisioning flake target: `inputs.self.outPath#<guest-name>`
- Disko disk name: `primary`
- guest bootloader: `systemd-boot`

The guest module also provides a default Disko layout:

- GPT partition table
- one EFI System Partition mounted at `/boot`
- one ext4 root filesystem
- mounted at `/`

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

If the default GPT + ESP + ext4 root layout is not enough, define `disko.devices` in the guest configuration.

If your guest uses a Disko disk key other than `primary`, also set `diskoDisk` on the host:

```nix
guests.my-guest = {
  nixosConfig = inputs.self.nixosConfigurations.my-guest;
  diskoDisk = "main";
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

Set per-guest overrides inside the guest with `nixvirtExtraConfigs`:

```nix
{
  nixos-vm-provisioner.guest = {
    enable = true;
    nixvirtExtraConfigs = {
      devices.video = [ { model.type = "qxl"; } ];
    };
  };
}
```

## How It Works

1. The host prepares the guest's backing storage.
2. On first boot, a systemd service checks for a host-managed provisioning marker.
3. If the marker is missing and the target is still blank, the host runs `disko-install` against the configured flake target and disk mapping.
4. The guest installs its own UEFI bootloader onto its disk during provisioning.
5. The host keeps a persistent per-guest NVRAM file under `/var/lib/nixos-vm-provisioner/nvram/`.
6. After the first successful provisioning run, the host records a marker and reuses the guest disk as-is on later boots.
7. Libvirt boots the guest from its own disk through OVMF.

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
