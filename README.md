# NixOS-VM-Provisioner

`nixos-vm-provisioner` is a pair of NixOS modules for host-managed VM installation.

The host creates the guest's backing storage, runs `disko-install` once against an unformatted target, and then boots the guest directly with the guest kernel and initrd from the host's Nix store through libvirt and NixVirt.

## Compared to MicroVM-Style Workflows

This project is primarily a first-boot provisioning tool, not a packaging format for tightly host-managed VMs.

Unlike `microvm`-style workflows where the guest runtime is often rebuilt and redeployed as part of the host configuration, this module installs a normal NixOS system onto its own disk and then leaves that disk alone after provisioning. Architecture-wise, the guest remains an independent machine: once installed, its root filesystem lives on its own backing storage and is not rebuilt or replaced by later host rebuilds.

## Modules

- `nixosModules.host`: defines storage, provisioning services, and libvirt domains on the hypervisor.
- `nixosModules.guest`: prepares a guest system for host-managed boot and exports the metadata the host needs.

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
    disko.url = "github:nix-community/disko";
    nixos-vm-provisioner.url = "path:./nixos-vm-provisioner";
  };

  outputs = { self, nixpkgs, disko, nixos-vm-provisioner, ... }: {
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
        disko.nixosModules.disko
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
- guest auto-start: `true`
- guest root device: `/dev/vda`
- provisioning flake target: `inputs.self.outPath#<guest-name>`
- Disko disk name: `primary`

The guest module also provides a default Disko layout:

- GPT partition table
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

If the default GPT + ext4 root layout is not enough, define `disko.devices` in the guest configuration.

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
2. On first boot, a systemd service checks whether the target is already formatted.
3. If not, the host runs `disko-install` against the configured flake target and disk mapping.
4. After that first successful provisioning run, the guest disk is left untouched and is reused as-is on later boots.
5. Libvirt boots the guest directly from the guest kernel and initrd already present in the host's Nix store.

## Requirements

- The guest system must import `disko.nixosModules.disko`.
- The guest system must import `nixos-vm-provisioner.nixosModules.guest`.
- The host system must import `nixos-vm-provisioner.nixosModules.host`.
- The guest root filesystem must be defined by the evaluated NixOS configuration.
- `volumeGroup` is required only for `storage.type = "lvm"`.
