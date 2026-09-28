# steamos-nvidia-installer

**Install real SteamOS on any PC with an NVIDIA RTX graphics card.**

[![steamos-nvidia-installer demo](https://img.youtube.com/vi/S3PcLhEXTK4/maxresdefault.jpg)](https://youtu.be/S3PcLhEXTK4)

Valve's SteamOS recovery image only ships drivers for AMD hardware. This
script takes the official recovery image and produces a bootable USB
installer with the NVIDIA driver baked in — including self-healing OS
updates, so updating from inside Steam keeps working afterwards.

Everything is built from the official image on your own machine. Nothing
from Valve is redistributed here.

> Independent hobby project — **not affiliated with or endorsed by Valve or
> NVIDIA.** See [LICENSE](LICENSE).

---

## What you need

**A Linux machine to build the USB image on** (Arch-based recommended):

- ~20 GB free disk space
- `losetup`, `btrfs-progs`, `rsync`, `curl`, `kmod`, `zstd`, `pacman`,
  `python3`, `binutils` (for `readelf`)
- root (`sudo`)

**The target machine** (where SteamOS will be installed):

- NVIDIA **GTX 16 / RTX 20-series or newer** — the open kernel driver only supports
  Turing and later, so GTX 10 series and older will **not** work
- UEFI boot, **Secure Boot disabled**
- A USB stick or external drive of **16 GB or more** to flash the installer to

---

## Step 0 — Get this script

Clone the repo:

```bash
git clone https://github.com/28allday/steamos-nvidia-installer.git
cd steamos-nvidia-installer
```

Or download just the one script:

```bash
curl -O https://raw.githubusercontent.com/28allday/steamos-nvidia-installer/main/steamos-nvidia-installer.sh
chmod +x steamos-nvidia-installer.sh
```

## Step 1 — Download the official SteamOS recovery image

Get it straight from Valve:

**https://help.steampowered.com/en/faqs/view/65B4-2AA3-5F37-4227#install**

Download the recovery image and decompress it — you end up with a `.img` file:

```bash
bunzip2 steamdeck-*.img.bz2
```

## Step 2 — Build the NVIDIA installer image

Put the `.img` next to the script and run it (with no argument it
auto-detects a single recovery image sitting beside it):

```bash
sudo ./steamos-nvidia-installer.sh steamdeck-<version>.img
```

This copies the image (**the original is never modified**), resolves the
NVIDIA open driver from Arch Linux (the current one, or the branch you asked
for with `--driver`), pins it to permanent archive URLs, verifies every binary is compatible with the image's glibc, compiles
the kernel module against the image's exact kernel in a throwaway build
chroot, installs the driver, and adds a one-click installer to the desktop.
Takes roughly 10–20 minutes. The result is:

```
steamdeck-<version>-nvidia-usbinstall.img
```

### Picking a driver branch

By default you get whatever `nvidia-open` current Arch ships. To pin a
specific branch instead — SteamOS itself ships 575.x — pass `--driver`:

```bash
sudo ./steamos-nvidia-installer.sh --driver 580 steamdeck-<version>.img
```

The argument is `latest` (default) or a version prefix: a branch (`580`), a
release (`580.105.08`), or an exact build (`580.105.08-4`). The newest
matching build is taken from
[Arch's package archive](https://archive.archlinux.org/packages/n/nvidia-utils/),
and the matching `nvidia-open-dkms`, `lib32-nvidia-utils` and any support
package the frozen SteamOS image lacks (e.g. `egl-wayland2`, only a
dependency from 590 on) are pinned to the same release. Turing (RTX
20-series) or newer is required on every branch.

Rebuilding with a different branch in the same `--workdir` is fine — the
build overlay is cleared automatically when the cached version doesn't match
(the downloaded packages are kept).

## Step 3 — Flash it to USB

```bash
sudo dd if=steamdeck-<version>-nvidia-usbinstall.img of=/dev/sdX bs=4M status=progress conv=fsync
```

Replace `/dev/sdX` with your USB stick (check with `lsblk` — **everything on
it will be erased**).

## Step 4 — Boot the USB and install

1. Boot the target machine from the USB stick (UEFI boot menu, Secure Boot off).
2. It boots into a SteamOS desktop. Double-click one of the icons:
   - **Install SteamOS (NVIDIA) to Hard Drive** — fresh install; erases the
     chosen disk completely.
   - **Upgrade SteamOS (NVIDIA) — keeps games & data** — reinstalls only the
     OS partitions on a disk that already has SteamOS, preserving your games,
     saves and Steam login.
3. Pick the target disk, confirm, and wait a few minutes. The machine powers
   off when done.
4. Remove the USB stick and boot. First boot lands in the Steam setup
   screen, then it's a normal SteamOS machine — Game Mode, Desktop Mode,
   the lot.

---

## OS updates

Updates from inside Steam **just work** (this is the default). Valve's
updater stages the new OS version as usual, then the driver is
automatically rebuilt for the new version before the reboot prompt appears
(adds 10–20 minutes to an update). If the rebuild fails for any reason,
the update is cancelled and the machine keeps booting the current working
system — it fails safe.

To move to a **different driver** later, rebuild the USB image (each run
re-resolves the driver — latest by default, or whatever `--driver` names)
and reinstall using the **Upgrade** icon. The installed system stays on the
driver it was built with until you do; updates never drift it to another
version.

Alternative update modes at build time:

| Flag | Behaviour |
|---|---|
| *(default)* | Self-healing updates as described above |
| `--hold-updates` | Steam always reports "up to date" — OS is frozen |
| `--no-hold-updates` | Stock updates — **an OS update will remove the driver** |

## Growing rootfs-A/B (optional, off by default)

Valve ships rootfs-A/B at 5GiB, which "no space left on device"s on pretty much any real
driver install or update. Pass `--grow-rootfs` when building the USB (or
`--target-root-mib SIZE`, which implies it) to grow them instead:

- **Fresh install** — with `--grow-rootfs`, Step 4's "Install SteamOS (NVIDIA) to Hard
  Drive" sizes rootfs-A/B at 8GiB (or whatever `--target-root-mib` names) from the start.
- **Repair an existing install** — booting a USB built with `--grow-rootfs` and choosing
  "Upgrade SteamOS (NVIDIA) — keeps games & data" prompts a dialog asking whether to grow
  rootfs-A/B in place (games, saves, and Steam login are untouched either way).

Without either flag, a USB behaves exactly as it always has: Valve's stock 5GiB,
nothing about `repair_device.sh` touched.

The extra room is also what makes
[decky-nvidia-update](https://github.com/moi952/decky-nvidia-update) practical — a Decky
Loader plugin that lets you pick and install any driver version straight from the running
system's Quick Access menu, no USB stick, no repair image, no reinstall, no reboot until
you're actually ready for one. Once the system has the extra headroom, install the plugin
and switch driver versions at will, without ever touching a USB stick again.

## All options

```
--driver SPEC           Driver to install: latest (default), or a branch/version
                        prefix — 580, 580.105.08, 580.105.08-4.
--hold-updates          Hard-hold OS updates instead of self-healing.
--no-hold-updates       Stock update behaviour (driver lost on update!).
--no-installer          Skip the desktop installer — just a bootable patched OS.
--trim-cuda             Drop CUDA/OpenCL/OptiX libraries (~350 MB smaller).
--skip-sigcheck         Disable pacman signature checks in the build chroot.
--workdir DIR           Build cache location (~3 GB, speeds up reruns).
--grow-rootfs           Grow rootfs-A/B beyond Valve's stock 5GiB (off by
                        default; implied by --target-root-mib).
--target-root-mib MIB   Size rootfs-A/B are grown to when --grow-rootfs is
                        active (default 8192 = 8GiB; Valve ships 5120).
```

## Troubleshooting

**Black screen on first boot of the installed system** — power-cycle once
before digging deeper; SteamOS hides its boot console (it lives on tty4–6),
so a working boot can look black for a while. If it persists, press
`Ctrl+Alt+F3`, log in as `deck`, and run `steamos-session-select plasma`
to get a desktop for diagnosis.

**The build says "No repair_device.sh in image home"** — the `.img` you
fed it isn't the recovery/repair image. Use the recovery image from the
link in Step 1.

**pacman signature errors during the build** — rerun with
`--skip-sigcheck` (packages come from Valve's and Arch's own servers over
HTTPS).

**Hybrid graphics laptops (iGPU + RTX)** — desktops with only an RTX card
are the clean path. On hybrids the iGPU may own the boot display; results
vary.

**Screen flickering or artifacts when the cursor is idle** — usually
adaptive sync (VRR). Try, in order: turn off adaptive sync on the
monitor/in display settings; disable VRR for the output
(`kscreen-doctor -o` to find the output ID, then
`kscreen-doctor output.<ID>.vrrpolicy.never` and reboot); set
`KWIN_DRM_NO_DIRECT_SCANOUT=1`; or enable developer settings and toggle
**force composite pipeline**. Lowering Automatic Image Scaling one step
has also worked. (Community fixes from issue #7.)

**Xbox controller pairs but sticks/buttons do nothing** (rumble and
battery status work) — the controller firmware is too old for the kernel's
Bluetooth LE pairing. Connect it to a Windows machine, update its firmware
in the **Xbox Accessories** app, and pair again. (From issue #12.)

**Steam logged out / games gone after a reflash** — images built before
the OOBE steam-wrapper fix wiped Steam's data on every boot of the
installed system until the first OS update. Rebuild with the current
script; the wipe is disabled at build time.

**Games crashing with a SIGSEGV** — MangoHud's 32-bit overlay
(`libMangoHud.so`) has a hard `DT_NEEDED` link on `libxkbcommon.so.0`, but
`lib32-libxkbcommon` isn't in SteamOS's base image or in `lib32-mangohud`'s
own dependencies, so the 32-bit overlay injection fails outright for any
game with a 32-bit component — first diagnosed on Halo MCC, not specific
to it or to anti-cheat. Images built with the current script include
`lib32-libxkbcommon` at build time; on an older install, rebuild or follow
the [full write-up and persistent fix](docs/mangohud-32bit-crash-fix.md).

## Security note

The installed system ships a passwordless-sudo drop-in for the `deck` user
(the desktop installer needs it). Once you've set a password
(`passwd` in Desktop Mode), remove it:

```bash
sudo rm /etc/sudoers.d/zz-deck-nopasswd
```

## Disclaimer

Not affiliated with, authorised by, or endorsed by Valve or NVIDIA. SteamOS
is Valve's; the NVIDIA driver is NVIDIA's. This is an independent hobby
project that wires them together on your own hardware — use at your own
risk. Tested on SteamOS 3.8.10–3.8.14 recovery images with an RTX 5060 Ti
and NVIDIA driver 610.43.03.
