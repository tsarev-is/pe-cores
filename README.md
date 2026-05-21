# pe-cores.sh

Interactively enable/disable Intel hybrid CPU cores (P-cores and E-cores) on Linux to trade performance for battery life — or vice versa.

Useful when you want to:

- **Save battery on a laptop** by running only a couple of E-cores.
- **Reduce heat / fan noise** during light work.
- **Cap peak performance** when on the move and don't need all cores spinning.
- **Bring everything back** to full power for builds, games, or heavy workloads.

Works on any modern Intel CPU that exposes the hybrid topology in sysfs (`/sys/devices/cpu_core` + `/sys/devices/cpu_atom`) — that's **12th gen Core (Alder Lake) and newer**, including Raptor Lake, Meteor Lake, Arrow Lake, Lunar Lake. Falls back to a single "all cores" group on non-hybrid Intel CPUs.

## Usage

```bash
chmod +x cpu-cores.sh
./cpu-cores.sh
```

```
---------------------------------------------
P-cores (performance): 12 / 12 online
E-cores (efficient):   8 / 8 online
---------------------------------------------
How many P-cores to keep online (1-12, empty to skip): 2
How many E-cores to keep online (1-8, empty to skip): 4

Done. New state:
---------------------------------------------
P-cores (performance): 2 / 12 online
E-cores (efficient):   4 / 8 online
---------------------------------------------
```

Empty input on a prompt leaves that group untouched. `cpu0` always stays online (kernel requirement).

## How it works

Cores are toggled via the standard Linux CPU hotplug interface:

```
/sys/devices/system/cpu/cpuN/online   # 0 = offline, 1 = online
/sys/devices/system/cpu/smt/control   # SMT/hyperthreading control
```

The script needs `sudo` because these files are root-writable. The kernel scheduler stops dispatching to offline CPUs immediately, which is what actually cuts power draw.

Settings reset to defaults on reboot — there's no persistent change to your system.

## Requirements

- Linux kernel with CPU hotplug enabled (any mainstream distro).
- `bash`, `sudo`.
- Root privileges (via `sudo`).

## Keywords

intel p-core e-core toggle, alder lake battery saver, raptor lake disable e-cores, linux cpu hotplug script, hybrid cpu power management, laptop battery life linux, disable hyperthreading runtime, intel 12th gen 13th gen 14th gen power saving.

## License

MIT.
