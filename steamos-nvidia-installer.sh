#!/bin/bash
#
# steamos-nvidia-installer.sh — turn a CLEAN SteamOS OOBE repair image into a
# one-click USB installer with NVIDIA (RTX) driver support baked in.
#
# Installs the CURRENT Arch Linux nvidia-open driver (Valve's own mirror only
# pins an older 575.x). The version is resolved once at build time, pinned to
# permanent archive.archlinux.org URLs, and the on-device self-heal repatch
# reuses those exact packages, so the installed system stays on one known
# driver even across OS updates. Safety: NVIDIA's userspace
# blobs target ancient glibc, and the single Arch-compiled helper the new
# driver needs (egl-wayland2) is small — but the build still extracts every
# downloaded package and verifies no binary needs a newer glibc than the
# image ships (frozen SteamOS 3.8 = glibc 2.41; current Arch = 2.43, so
# blind installs of Arch-compiled libs are NOT safe in general).
#
#   sudo ./steamos-nvidia-installer.sh steamdeck-oobe-repair-<ver>.img
#
# Output: <image>-nvidia-usbinstall.img  →  dd to a USB stick, boot it on the
# target machine (UEFI, Secure Boot off), double-click
# "Install SteamOS (NVIDIA) to Hard Drive", pick a disk, done.
# The input image is copied first and never modified.
#
# What it does, in one pass over one copy:
#   1. Builds nvidia-open (DKMS) against the image's exact neptune kernel in
#      a throwaway overlayfs chroot, using Valve's frozen Arch mirror — the
#      toolchain/headers never enter the image. Copies only the driver
#      payload (modules, nvidia-utils, lib32, egl-*, GSP firmware) into the
#      rootfs and registers it in the pacman db.
#   2. Blacklists nouveau + enables nvidia-drm KMS via modprobe.d AND the
#      kernel cmdline (grub.cfg on the efi partition + /etc/default/grub —
#      the latter is what the installed system's regenerated grub uses).
#   3. Makes OS updates SELF-HEALING (default): updating from within Steam
#      works — Valve's updater stages the new OS in the spare A/B slot as
#      usual, then a wrapper around steamos-update rebuilds the NVIDIA
#      driver for the new OS (in a chroot on the new slot, from that
#      version's own repo branch) before the reboot prompt appears. If the
#      rebuild fails, the update is cancelled and the machine keeps booting
#      the current working system. Alternatives: --hold-updates makes Steam
#      always report "up to date" (old behaviour), --no-hold-updates leaves
#      stock update behaviour (an OS update then removes the driver!).
#   4. Adds the one-click installer: Valve's own repair_device.sh (which
#      installs by CLONING the running system, so the driver propagates)
#      patched for generic hardware — target-disk override, /dev/sdX
#      partition-suffix autodetect, NVMe-sanitize skipped on non-NVMe —
#      plus a zenity disk-picker wrapper, a desktop icon, and NOPASSWD sudo
#      for deck (remove /etc/sudoers.d/zz-deck-nopasswd on the installed
#      system once you set a password).
#
# Options:
#   --hold-updates     Hard-hold OS updates instead of self-healing (Steam
#                      always shows "up to date").
#   --no-hold-updates  Stock update behaviour — DANGER: an OS update boots an
#                      unpatched system (A/B fallback saves you, driver lost).
#   --no-installer     Skip step 4 (produce a plain bootable patched OS).
#   --trim-cuda        Drop CUDA/OpenCL/NVVM/OptiX libs (~350 MB smaller).
#   --skip-sigcheck    Disable pacman signature checks in the build chroot.
#   --workdir DIR      Build dir (~3 GB; default: alongside the output).
#                      Kept between runs — caches the driver build.
#
# Host needs: Arch-ish Linux, losetup, btrfs-progs, rsync, curl, kmod, zstd,
# python3, readelf (binutils).
# Notes: nvidia-open = RTX 20xx+ (Turing) only. Target machines need UEFI +
# Secure Boot off. First boot of an installed system lands in the gamescope
# Steam setup; if it black-screens: Ctrl+Alt+F3 → steamos-session-select plasma.

set -euo pipefail

# ---------------------------------------------------------------- helpers
log()  { printf '\e[1;35m[nvidia-usb]\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m[warn]\e[0m %s\n' "$*" >&2; }
die()  { printf '\e[1;31m[fail]\e[0m %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------- args
UPDATE_MODE=selfheal   # selfheal | hold | stock
ADD_INSTALLER=1
TRIM_CUDA=0
SKIP_SIG=0
WORKDIR=""
IMG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hold-updates)    UPDATE_MODE=hold ;;
    --no-hold-updates) UPDATE_MODE=stock ;;
    --no-installer)    ADD_INSTALLER=0 ;;
    --trim-cuda)       TRIM_CUDA=1 ;;
    --skip-sigcheck)   SKIP_SIG=1 ;;
    --workdir)         WORKDIR="${2:?--workdir needs an argument}"; shift ;;
    -h|--help)         sed -n '2,66p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)                die "Unknown option: $1" ;;
    *)                 IMG="$1" ;;
  esac
  shift
done

[[ $EUID -eq 0 ]] || die "Run as root (sudo)."
if [[ -z "$IMG" ]]; then
  # No image given — look for exactly one clean repair image next to the script.
  script_dir="$(dirname "$(realpath "$0")")"
  mapfile -t candidates < <(find "$script_dir" -maxdepth 1 -name '*.img' ! -name '*-nvidia*.img' | sort)
  case ${#candidates[@]} in
    0) die "No image given and no *.img found in $script_dir. Usage: $0 [options] <clean-oobe-repair.img>" ;;
    1) IMG="${candidates[0]}"; log "Auto-detected image: $IMG" ;;
    *) die "Multiple images in $script_dir — pass one explicitly:$(printf '\n  %s' "${candidates[@]}")" ;;
  esac
fi
[[ -f "$IMG" ]] || die "Image not found: $IMG"
for tool in losetup blkid btrfs rsync curl depmod sed awk tar zstd pacman python3 readelf; do
  command -v "$tool" >/dev/null || die "Missing host tool: $tool"
done

IMG="$(realpath "$IMG")"
OUT="${IMG%.img}-nvidia-usbinstall.img"
# match the FILENAME only — the containing dir may itself be called
# "steamos-nvidia-installer" (the repo clone), which must not trip this guard
[[ "$(basename "$IMG")" == *-nvidia*.img ]] && die "Input looks like an already-patched image — start from the clean repair image."
[[ -e "$OUT" ]] && { warn "Removing previous output $OUT"; rm -f "$OUT"; }

[[ -n "$WORKDIR" ]] || WORKDIR="$(dirname "$OUT")/.nvidia-usb-work"
MNT="$WORKDIR/mnt"          # rootfs mount
EFIMNT="$WORKDIR/efi"       # efi-A mount
HOMEMNT="$WORKDIR/home"     # home mount
UPPER="$WORKDIR/upper"      # overlay upper (build residue, cached)
OVLWORK="$WORKDIR/ovlwork"
MERGED="$WORKDIR/merged"
LOOPDEV=""
UDEV_RULE=/run/udev/rules.d/90-steamos-nvidia-installer.rules

# ---------------------------------------------------------------- cleanup
cleanup() {
  set +e
  for m in "$MERGED"/dev/pts "$MERGED"/dev "$MERGED"/sys "$MERGED"/proc \
           "$MERGED" "$EFIMNT" "$HOMEMNT" "$MNT"; do
    if mountpoint -q "$m" 2>/dev/null; then
      umount -R "$m" 2>/dev/null || umount -Rl "$m" 2>/dev/null
    fi
  done
  # sweep any udisks automounts of OUR loop device only
  if [[ -n "$LOOPDEV" ]]; then
    findmnt -rn -o TARGET,SOURCE | awk -v l="$LOOPDEV" '$2 ~ "^"l {print $1}' \
      | tac | while read -r m; do umount "$m" 2>/dev/null; done
    losetup -d "$LOOPDEV" 2>/dev/null
  fi
  if [[ -f "$UDEV_RULE" ]]; then
    rm -f "$UDEV_RULE"
    udevadm control --reload 2>/dev/null
  fi
}
trap cleanup EXIT

in_chroot() { chroot "$MERGED" /bin/bash -c "$*"; }

mkdir -p "$MNT" "$EFIMNT" "$HOMEMNT" "$UPPER" "$OVLWORK" "$MERGED"

# stale mounts from an interrupted previous run
for m in "$MERGED" "$EFIMNT" "$HOMEMNT" "$MNT"; do
  if mountpoint -q "$m" 2>/dev/null; then
    warn "Stale mount from a previous run at $m — unmounting"
    umount -R "$m" 2>/dev/null || umount -Rl "$m"
  fi
done

# keep udisks/desktop automounters away from loop partitions during the run
mkdir -p /run/udev/rules.d
echo 'SUBSYSTEM=="block", KERNEL=="loop*", ENV{UDISKS_IGNORE}="1"' > "$UDEV_RULE"
udevadm control --reload

# ------------------------------------------------------------- copy image
log "Copying image → $OUT (~8 GB)"
cp --reflink=auto "$IMG" "$OUT"

# ------------------------------------------------------------- loop mount
LOOPDEV="$(losetup -f --show -P "$OUT")"
log "Loop device: $LOOPDEV"

ROOTPART="" EFIPART="" HOMEPART=""
for part in "$LOOPDEV"p*; do
  case "$(blkid -p -s PART_ENTRY_NAME -o value "$part" 2>/dev/null)" in
    rootfs-A) ROOTPART="$part" ;;
    efi-A)    EFIPART="$part" ;;
    home)     HOMEPART="$part" ;;
  esac
done
[[ -n "$ROOTPART" && -n "$EFIPART" && -n "$HOMEPART" ]] \
  || die "rootfs-A/efi-A/home partitions not found — is this a SteamOS image?"

FSUUID="$(blkid -p -s UUID -o value "$ROOTPART")"
findmnt -rn -S "UUID=$FSUUID" >/dev/null 2>&1 \
  && die "A filesystem with UUID $FSUUID is already mounted (another copy of this image?). Unmount it first."

log "Mounting rootfs + efi + home"
mount -o compress-force=zstd:3 "$ROOTPART" "$MNT"
mount "$EFIPART" "$EFIMNT"
mount "$HOMEPART" "$HOMEMNT"

if [[ "$(btrfs property get "$MNT" ro)" == "ro=true" ]]; then
  log "Clearing btrfs read-only property"
  btrfs property set "$MNT" ro false
fi

# ------------------------------------------------- discover image details
KVER=""
for d in "$MNT/usr/lib/modules/"*neptune*; do
  [[ -d "$d" ]] && KVER="$(basename "$d")" && break
done
[[ -n "$KVER" ]] || die "No neptune kernel found in image"
log "Image kernel: $KVER"

PACDB="$MNT/usr/lib/holo/pacmandb/local"
KPKG_DIR=""
for d in "$PACDB"/linux-neptune-*-[0-9]*; do
  [[ -d "$d" ]] || continue
  case "$(basename "$d")" in
    *-headers-*|*firmware*|*rtw*) continue ;;
  esac
  KPKG_DIR="$d"; break
done
[[ -n "$KPKG_DIR" ]] || die "Could not find installed kernel package in pacman db"
KPKG_FULL="$(basename "$KPKG_DIR")"
KPKG_NAME="${KPKG_FULL%-*-*}"
KPKG_VERREL="${KPKG_FULL#"$KPKG_NAME"-}"
log "Kernel package: $KPKG_NAME $KPKG_VERREL"

JUPITER_REPO="$(awk -F'[][]' '/^\[jupiter-/{print $2; exit}' "$MNT/etc/pacman.conf")"
[[ -n "$JUPITER_REPO" ]] || die "No jupiter repo in image pacman.conf"
MIRROR="$(awk '/^Server/{print $3; exit}' "$MNT/etc/pacman.d/mirrorlist")"
HDR_URL="${MIRROR/\$repo/$JUPITER_REPO}"
HDR_URL="${HDR_URL/\$arch/x86_64}/${KPKG_NAME}-headers-${KPKG_VERREL}-x86_64.pkg.tar.zst"
curl -sfIL "$HDR_URL" -o /dev/null \
  || die "Exact-match headers not found in Valve's pool: $HDR_URL"
log "Headers package: $(basename "$HDR_URL")"

# ------------------------------------- resolve latest Arch driver packages
# The driver set comes from CURRENT Arch, not Valve's frozen mirror. Version
# is resolved here once, then pinned via permanent archive.archlinux.org
# URLs (mirror URLs die when Arch bumps the version) — the same URLs are
# recorded in the image for the self-heal repatch.
log "Resolving latest NVIDIA driver from Arch Linux"
PKG_URLS=""            # pinned URLs, space-separated (also goes in driver.conf)
PKG_FILES=()           # local filenames in $WORKDIR/pkgs
DRIVER_VERSION=""      # nvidia-utils pkgver-pkgrel
NV_PKGVER=""           # pkgver only, for cross-package consistency check
for spec in extra/nvidia-open-dkms extra/nvidia-utils multilib/lib32-nvidia-utils extra/egl-wayland2; do
  repo="${spec%/*}"; pkg="${spec#*/}"
  line="$(curl -sfL "https://archlinux.org/packages/$repo/x86_64/$pkg/json/" \
          | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["pkgver"]+"-"+d["pkgrel"], d["filename"])')" \
    || die "Could not resolve $pkg from archlinux.org"
  ver="${line%% *}"; file="${line#* }"
  [[ "$pkg" == nvidia-utils ]] && { DRIVER_VERSION="$ver"; NV_PKGVER="${ver%-*}"; }
  url="https://archive.archlinux.org/packages/${pkg:0:1}/$pkg/$file"
  if ! curl -sfIL "$url" -o /dev/null; then
    url="https://geo.mirror.pkgbuild.com/$repo/os/x86_64/$file"
    curl -sfIL "$url" -o /dev/null || die "$pkg $ver not on archive.archlinux.org nor the mirror"
    warn "$pkg not yet in the Arch archive — pinning mirror URL (may go stale)"
  fi
  PKG_URLS+="${PKG_URLS:+ }$url"
  PKG_FILES+=("$file")
  log "  $pkg $ver"
done
# all three nvidia packages must be the same driver release (mirror mid-bump
# skew would make pacman -U fail on the versioned dependency)
for f in "${PKG_FILES[@]}"; do
  case "$f" in
    nvidia-open-dkms-*|lib32-nvidia-utils-*)
      [[ "$f" == *"$NV_PKGVER"* ]] || die "Version skew between nvidia packages (mirror mid-update?) — retry in an hour" ;;
  esac
done
log "Driver pinned: nvidia-open $DRIVER_VERSION"

mkdir -p "$WORKDIR/pkgs"
i=0
for url in $PKG_URLS; do
  f="${PKG_FILES[$i]}"; i=$((i+1))
  if [[ -s "$WORKDIR/pkgs/$f" ]]; then
    log "Cached: $f"
  else
    log "Downloading $f"
    curl -sfL "$url" -o "$WORKDIR/pkgs/$f.part" || die "download failed: $url"
    mv "$WORKDIR/pkgs/$f.part" "$WORKDIR/pkgs/$f"
  fi
done

# ---------------------------------------------------- glibc compatibility
# Current Arch compiles against a newer glibc than frozen SteamOS ships.
# NVIDIA's own blobs target ancient glibc so they're fine, but anything
# Arch-compiled (egl-wayland2, and whoever joins the dep list in future
# driver releases) can silently require symbols the image doesn't have.
# Extract everything and refuse to build if any ELF needs more than the
# image's glibc.
IMG_GLIBC="$(basename "$(echo "$PACDB"/glibc-[0-9]*)" | sed -E 's/^glibc-([0-9]+\.[0-9]+).*/\1/')"
[[ "$IMG_GLIBC" =~ ^[0-9]+\.[0-9]+$ ]] || die "Could not determine image glibc version"
log "Checking payload glibc requirements against image glibc $IMG_GLIBC"
SCAN="$WORKDIR/glibc-scan"
rm -rf "$SCAN"; mkdir -p "$SCAN"
for f in "${PKG_FILES[@]}"; do
  mkdir -p "$SCAN/${f%%.pkg.tar.zst}"
  tar -xf "$WORKDIR/pkgs/$f" -C "$SCAN/${f%%.pkg.tar.zst}"
done
# readelf fails on non-ELF executables (scripts) — mustn't kill the pipeline
MAX_GLIBC="$({ find "$SCAN" -type f \( -name '*.so*' -o -perm -111 \) \
  -exec readelf -V {} + 2>/dev/null || true; } | grep -o 'GLIBC_[0-9.]*' \
  | sed 's/^GLIBC_//' | sort -uV | tail -1)"
[[ -n "$MAX_GLIBC" ]] || die "glibc scan found no ELF version references — scan broken?"
if [[ "$(printf '%s\n' "$MAX_GLIBC" "$IMG_GLIBC" | sort -V | tail -1)" != "$IMG_GLIBC" ]]; then
  die "Driver payload needs glibc $MAX_GLIBC but the image only has $IMG_GLIBC — current Arch has drifted too far; this needs the .run-installer approach instead"
fi
log "OK: payload needs at most glibc $MAX_GLIBC (image has $IMG_GLIBC)"
rm -rf "$SCAN"

# --------------------------------------------------------- overlay chroot
log "Setting up overlay build chroot (build residue stays out of the image)"
# index=off: allows reusing the upperdir even if a lazily-unmounted overlay
# from an interrupted previous run still references it (enables resume).
mount -t overlay overlay \
  -o "index=off,lowerdir=$MNT,upperdir=$UPPER,workdir=$OVLWORK" "$MERGED"
mount -t proc proc "$MERGED/proc"
mount --rbind /sys "$MERGED/sys";  mount --make-rslave "$MERGED/sys"
mount --rbind /dev "$MERGED/dev";  mount --make-rslave "$MERGED/dev"
rm -f "$MERGED/etc/resolv.conf"          # whiteout in upper only
cp -L /etc/resolv.conf "$MERGED/etc/resolv.conf"

PACOPTS="--noconfirm --needed"
PACCONF="/etc/pacman.conf"
if [[ $SKIP_SIG -eq 1 ]]; then
  sed 's/^SigLevel.*/SigLevel = Never/' "$MERGED/etc/pacman.conf" \
    > "$MERGED/tmp/pacman-nosig.conf"
  PACCONF="/tmp/pacman-nosig.conf"
  warn "pacman signature verification DISABLED for the build"
fi

if [[ $SKIP_SIG -eq 0 && ! -d "$MERGED/etc/pacman.d/gnupg/private-keys-v1.d" ]]; then
  log "Initialising pacman keyring in chroot"
  in_chroot "pacman-key --init && pacman-key --populate" \
    || die "Keyring init failed — rerun with --skip-sigcheck if you accept unsigned installs"
fi

# Resume: if a previous run already built everything in the overlay for THIS
# driver version, skip the download/compile and go straight to payload
# extraction. (Version check matters: Arch may have bumped since the cached
# build — then the overlay must be brought up to the newly pinned version.)
if compgen -G "$UPPER/usr/lib/modules/$KVER/updates/dkms/nvidia.ko*" >/dev/null \
   && [[ "$(in_chroot "pacman -Q nvidia-utils 2>/dev/null" | awk '{print $2}')" == "$DRIVER_VERSION" ]]; then
  log "Overlay already contains a built nvidia $DRIVER_VERSION module — reusing previous build"
else
  log "Downloading exact-match kernel headers"
  in_chroot "curl -sfL '$HDR_URL' -o /tmp/headers.pkg.tar.zst"

  log "Refreshing pacman databases"
  in_chroot "pacman --config $PACCONF -Sy"

  log "Installing headers + dkms (from Valve's mirror)"
  in_chroot "pacman --config $PACCONF -U $PACOPTS /tmp/headers.pkg.tar.zst"
  in_chroot "pacman --config $PACCONF -S $PACOPTS dkms"

  log "Installing pinned Arch driver packages (compiles the module, takes a few minutes)"
  rm -rf "$MERGED/tmp/nvpkgs"; mkdir -p "$MERGED/tmp/nvpkgs"
  for f in "${PKG_FILES[@]}"; do cp "$WORKDIR/pkgs/$f" "$MERGED/tmp/nvpkgs/"; done
  in_chroot "pacman --config $PACCONF -U $PACOPTS /tmp/nvpkgs/*.pkg.tar.zst" \
    || die "pacman -U failed. If it was a signature/keyring error (frozen image keyring vs current Arch packagers), rerun with --skip-sigcheck — the packages came over HTTPS from Arch infrastructure."

  if ! compgen -G "$MERGED/usr/lib/modules/$KVER/updates/dkms/nvidia.ko*" >/dev/null; then
    log "DKMS hook didn't build for $KVER — forcing"
    in_chroot "dkms autoinstall -k $KVER"
    compgen -G "$MERGED/usr/lib/modules/$KVER/updates/dkms/nvidia.ko*" >/dev/null \
      || die "nvidia module failed to build for $KVER (check output above)"
  fi
fi
NVIDIA_VER="$(in_chroot "pacman -Q nvidia-utils" | awk '{print $2}')"
[[ "$NVIDIA_VER" == "$DRIVER_VERSION" ]] \
  || die "Chroot has nvidia-utils $NVIDIA_VER but $DRIVER_VERSION was pinned — stale overlay? Delete $WORKDIR and rerun."
log "Built nvidia-open $NVIDIA_VER for $KVER"

# "Before" = the pristine image's own pacman db (read directly, host-side) —
# NOT the chroot's, whose db carries installs cached in the overlay upper
# layer from previous runs and would make the diff come out empty.
pacman -Qq --dbpath "$MNT/usr/lib/holo/pacmandb" | LC_ALL=C sort > "$WORKDIR/pkgs-before.txt"
in_chroot "pacman -Qq" | LC_ALL=C sort > "$WORKDIR/pkgs-after.txt"

# ----------------------------------------------------- compute the payload
# New packages minus build-only toolchain = what ships in the image.
# nvidia-open-dkms is build-only too: it's the module SOURCE (~70 MB); the
# compiled module is copied from /usr/lib/modules separately.
BUILD_ONLY_RE='^(dkms|nvidia-open-dkms|patch|gcc|gcc-libs|make|binutils|libisl|libmpc|mpfr|pahole|python-setuptools|linux-neptune.*-headers|.*-headers)$'
mapfile -t NEW_PKGS < <(LC_ALL=C comm -13 "$WORKDIR/pkgs-before.txt" "$WORKDIR/pkgs-after.txt" \
                        | grep -Ev "$BUILD_ONLY_RE")
[[ ${#NEW_PKGS[@]} -gt 0 ]] || die "Payload package list came out empty — check $WORKDIR/pkgs-*.txt"
log "Payload packages: ${NEW_PKGS[*]}"

FILELIST="$WORKDIR/payload-files.txt"
: > "$FILELIST"
for pkg in "${NEW_PKGS[@]}"; do
  in_chroot "pacman -Qlq $pkg" >> "$FILELIST"
done

if [[ $TRIM_CUDA -eq 1 ]]; then
  log "Trimming CUDA/OpenCL/NVVM/OptiX libraries"
  grep -Ev 'libcuda|libcudadebugger|libnvidia-nvvm|libnvidia-opencl|libnvoptix|nvidia-cuda-mps|OpenCL' \
    "$FILELIST" > "$FILELIST.trim" && mv "$FILELIST.trim" "$FILELIST"
fi
sed 's|^/||' "$FILELIST" > "$FILELIST.rel"

# Space check: pacman -Qlq lists directories too — size only files/symlinks.
PAYLOAD_MB="$(set +o pipefail; cd "$MERGED" && while IFS= read -r p; do
    if [[ -f "$p" || -L "$p" ]]; then printf '%s\0' "$p"; fi
  done < "$FILELIST.rel" | { du -scm --no-dereference --files0-from=- 2>/dev/null || true; } | tail -1 | cut -f1)"
[[ "$PAYLOAD_MB" =~ ^[0-9]+$ ]] || die "Could not size the payload"
MODULES_MB="$(du -sm "$UPPER/usr/lib/modules/$KVER/updates" | cut -f1)"
AVAIL_MB="$(df -m --output=avail "$MNT" | tail -1 | tr -d ' ')"
log "Payload ≈ ${PAYLOAD_MB} MB files + ${MODULES_MB} MB modules (before btrfs zstd); rootfs has ${AVAIL_MB} MB free"
if (( PAYLOAD_MB + MODULES_MB > AVAIL_MB * 2 )); then   # zstd roughly halves it
  die "Not enough space in rootfs. Rerun with --trim-cuda."
fi

# --------------------------------------------------- install into rootfs
log "Copying driver payload into the image rootfs"
rsync -a --files-from="$FILELIST.rel" "$MERGED/" "$MNT/"
rsync -a "$UPPER/usr/lib/modules/$KVER/updates" "$MNT/usr/lib/modules/$KVER/"

log "Registering payload packages in the image's pacman db"
for pkg in "${NEW_PKGS[@]}"; do
  for ENTRY in "$UPPER/usr/lib/holo/pacmandb/local/$pkg"-[0-9]*; do
    [[ -d "$ENTRY" ]] && rsync -a "$ENTRY" "$MNT/usr/lib/holo/pacmandb/local/" && break
  done
done

log "Running depmod + ldconfig in the image"
chroot "$MNT" depmod "$KVER"
chroot "$MNT" ldconfig

log "Writing modprobe config (blacklist nouveau, enable nvidia KMS)"
cat > "$MNT/etc/modprobe.d/99-nvidia-patch.conf" <<'EOF'
# Added by steamos-nvidia-installer
blacklist nouveau
options nouveau modeset=0
options nvidia-drm modeset=1 fbdev=1
options nvidia NVreg_PreserveVideoMemoryAllocations=1
EOF

log "Enabling nvidia suspend/resume services"
chroot "$MNT" systemctl enable nvidia-suspend nvidia-resume nvidia-hibernate 2>/dev/null \
  || warn "Could not enable nvidia power services (non-fatal)"

# --------------------------------------------------------- update strategy
# OOBE day-1 auto-migration stays masked in all modes except stock — a
# surprise multi-GB update mid-first-boot is bad UX even when self-healing.
if [[ $UPDATE_MODE != stock ]]; then
  [[ -f "$MNT/usr/lib/systemd/system/steamos-finish-oobe-migration.service" ]] \
    && ln -sf /dev/null "$MNT/etc/systemd/system/steamos-finish-oobe-migration.service"
fi

if [[ $UPDATE_MODE == hold ]]; then
  log "Holding OS updates: masking updater services, stubbing CLIs"
  [[ -f "$MNT/usr/lib/systemd/system/atomupd.service" ]] \
    && ln -sf /dev/null "$MNT/etc/systemd/system/atomupd.service"
  for bin in steamos-update steamos-update-os steamos-atomupd-client; do
    [[ -f "$MNT/usr/bin/$bin" && ! -f "$MNT/usr/bin/$bin.orig" ]] || continue
    mv "$MNT/usr/bin/$bin" "$MNT/usr/bin/$bin.orig"
    cat > "$MNT/usr/bin/$bin" <<'EOF'
#!/bin/bash
# Stubbed by steamos-nvidia-installer: an OS update would replace the rootfs
# and remove the NVIDIA driver. Original saved as $0.orig.
echo "OS updates are held on this system (NVIDIA-patched image)." >&2
# 7 = "no update available" to keep the Steam UI happy
exit 7
EOF
    chmod 755 "$MNT/usr/bin/$bin"
  done
fi

if [[ $UPDATE_MODE == selfheal ]]; then
  log "Installing self-healing update machinery"
  mkdir -p "$MNT/usr/lib/steamos-nvidia"

  # pinned driver record — repatch installs these exact packages (instead of
  # the slot's frozen repo, which is what the valve-driver variant does)
  cat > "$MNT/usr/lib/steamos-nvidia/driver.conf" <<EOF
# Written by steamos-nvidia-installer at image build time.
# repatch.sh installs the driver from these pinned URLs; to move to a newer
# driver later, rebuild the USB image with the latest script and reinstall
# (or update this file by hand with matching-version package URLs).
DRIVER_VERSION="$DRIVER_VERSION"
PKG_URLS="$PKG_URLS"
EOF
  chmod 644 "$MNT/usr/lib/steamos-nvidia/driver.conf"

  # ---- on-device re-patch tool: rebuilds the driver inside the OTHER slot
  cat > "$MNT/usr/lib/steamos-nvidia/repatch.sh" <<'REPATCH'
#!/bin/bash
# steamos-nvidia repatch — rebuild + install the NVIDIA driver into another
# partition set (normally "other", right after an OS update staged there).
# Run as root. Idempotent: exits 0 immediately if the slot already has the
# driver for its kernel. Logs to stdout (the update wrapper redirects).
set -euo pipefail

PARTSET="${1:-other}"
log() { echo "[repatch] $*"; }
die() { echo "[repatch] FAIL: $*" >&2; exit 1; }

ROOTDEV="/dev/disk/by-partsets/$PARTSET/rootfs"
EFIDEV="/dev/disk/by-partsets/$PARTSET/efi"
[[ -b "$ROOTDEV" && -b "$EFIDEV" ]] || die "partset '$PARTSET' not found (single-slot system?)"

NEWROOT="$(mktemp -d /tmp/repatch-root.XXXXXX)"
# SteamOS /home is ext4 with casefold enabled, which overlayfs rejects as an
# upperdir — so the build workspace lives inside a plain ext4 loopback image
# on /home (space for the build, no casefold).
WORKIMG=/home/.steamos-nvidia-work.img
WORK="$(mktemp -d /tmp/repatch-work.XXXXXX)"
UPPER="$WORK/upper"; OVLWORK="$WORK/ovlwork"; MERGED="$WORK/merged"

cleanup() {
  set +e
  for m in "$MERGED"/dev/pts "$MERGED"/dev "$MERGED"/sys "$MERGED"/proc "$MERGED" \
           "$NEWROOT"/efi "$NEWROOT"/dev/pts "$NEWROOT"/dev "$NEWROOT"/sys "$NEWROOT"/proc "$NEWROOT" \
           "$WORK"; do
    mountpoint -q "$m" 2>/dev/null && { umount -R "$m" 2>/dev/null || umount -Rl "$m" 2>/dev/null; }
  done
  rmdir "$NEWROOT" "$WORK" 2>/dev/null
  rm -f "$WORKIMG"
}
trap cleanup EXIT

rm -f "$WORKIMG"
truncate -s 8G "$WORKIMG"
mkfs.ext4 -q -F "$WORKIMG"
mount -o loop "$WORKIMG" "$WORK"
mkdir -p "$UPPER" "$OVLWORK" "$MERGED"

log "Mounting $ROOTDEV"
mount -o compress-force=zstd:3 "$ROOTDEV" "$NEWROOT"
WAS_RO=0
if [[ "$(btrfs property get "$NEWROOT" ro)" == "ro=true" ]]; then
  WAS_RO=1; btrfs property set "$NEWROOT" ro false
fi

KVER=""
for d in "$NEWROOT/usr/lib/modules/"*neptune*; do
  [[ -d "$d" ]] && KVER="$(basename "$d")" && break
done
[[ -n "$KVER" ]] || die "no neptune kernel in $PARTSET rootfs"
log "Target kernel: $KVER"

if compgen -G "$NEWROOT/usr/lib/modules/$KVER/updates/dkms/nvidia.ko*" >/dev/null; then
  log "Driver already present for $KVER — nothing to do"
  [[ $WAS_RO -eq 1 ]] && btrfs property set "$NEWROOT" ro true
  exit 0
fi

PACDB="$NEWROOT/usr/lib/holo/pacmandb/local"
KPKG_DIR=""
for d in "$PACDB"/linux-neptune-*-[0-9]*; do
  [[ -d "$d" ]] || continue
  case "$(basename "$d")" in *-headers-*|*firmware*|*rtw*) continue ;; esac
  KPKG_DIR="$d"; break
done
[[ -n "$KPKG_DIR" ]] || die "kernel package not found in new slot's pacman db"
KPKG_FULL="$(basename "$KPKG_DIR")"
KPKG_NAME="${KPKG_FULL%-*-*}"
KPKG_VERREL="${KPKG_FULL#"$KPKG_NAME"-}"
JUPITER_REPO="$(awk -F'[][]' '/^\[jupiter-/{print $2; exit}' "$NEWROOT/etc/pacman.conf")"
MIRROR="$(awk '/^Server/{print $3; exit}' "$NEWROOT/etc/pacman.d/mirrorlist")"
HDR_URL="${MIRROR/\$repo/$JUPITER_REPO}"
HDR_URL="${HDR_URL/\$arch/x86_64}/${KPKG_NAME}-headers-${KPKG_VERREL}-x86_64.pkg.tar.zst"
log "Headers: $(basename "$HDR_URL")"
curl -sfIL "$HDR_URL" -o /dev/null || die "matching headers not in Valve's pool: $HDR_URL"

log "Building driver in overlay chroot (this takes 10-20 minutes)"
mount -t overlay overlay -o "index=off,lowerdir=$NEWROOT,upperdir=$UPPER,workdir=$OVLWORK" "$MERGED"
mount -t proc proc "$MERGED/proc"
mount --rbind /sys "$MERGED/sys"; mount --make-rslave "$MERGED/sys"
mount --rbind /dev "$MERGED/dev"; mount --make-rslave "$MERGED/dev"
rm -f "$MERGED/etc/resolv.conf"; cp -L /etc/resolv.conf "$MERGED/etc/resolv.conf"
in_chroot() { chroot "$MERGED" /bin/bash -c "$*"; }

[[ -d "$MERGED/etc/pacman.d/gnupg/private-keys-v1.d" ]] \
  || in_chroot "pacman-key --init && pacman-key --populate"
in_chroot "curl -sfL '$HDR_URL' -o /tmp/headers.pkg.tar.zst"
in_chroot "pacman -Sy"
in_chroot "pacman -Qq" | LC_ALL=C sort > "$WORK/before.txt"
in_chroot "pacman -U --noconfirm --needed /tmp/headers.pkg.tar.zst"
in_chroot "pacman -S --noconfirm --needed dkms"

# Driver = the exact pinned Arch packages this image was built with (NOT the
# slot's frozen repo — that only has Valve's older driver).
source /usr/lib/steamos-nvidia/driver.conf
[[ -n "${PKG_URLS:-}" ]] || die "driver.conf has no PKG_URLS"
log "Installing pinned driver $DRIVER_VERSION"
in_chroot "mkdir -p /tmp/nvpkgs"
for u in $PKG_URLS; do
  in_chroot "curl -sfL '$u' -o /tmp/nvpkgs/\$(basename '$u')" || die "download failed: $u"
done
if ! in_chroot "pacman -U --noconfirm --needed /tmp/nvpkgs/*.pkg.tar.zst"; then
  # unattended context: a keyring mismatch (frozen image keyring vs current
  # Arch packager keys) must not brick updates — packages came over HTTPS
  # from Arch infrastructure, so retry unsigned rather than fail the update
  log "WARNING: pacman -U failed (keyring?) — retrying with signature checks off"
  sed 's/^SigLevel.*/SigLevel = Never/' "$MERGED/etc/pacman.conf" > "$MERGED/tmp/pacman-nosig.conf"
  in_chroot "pacman --config /tmp/pacman-nosig.conf -U --noconfirm --needed /tmp/nvpkgs/*.pkg.tar.zst" \
    || die "driver package install failed"
fi
compgen -G "$MERGED/usr/lib/modules/$KVER/updates/dkms/nvidia.ko*" >/dev/null \
  || in_chroot "dkms autoinstall -k $KVER"
compgen -G "$MERGED/usr/lib/modules/$KVER/updates/dkms/nvidia.ko*" >/dev/null \
  || die "driver failed to build for $KVER"
in_chroot "pacman -Qq" | LC_ALL=C sort > "$WORK/after.txt"

BUILD_ONLY_RE='^(dkms|nvidia-open-dkms|patch|gcc|gcc-libs|make|binutils|libisl|libmpc|mpfr|pahole|python-setuptools|linux-neptune.*-headers|.*-headers)$'
mapfile -t NEW_PKGS < <(LC_ALL=C comm -13 "$WORK/before.txt" "$WORK/after.txt" | grep -Ev "$BUILD_ONLY_RE")
[[ ${#NEW_PKGS[@]} -gt 0 ]] || die "payload list empty"
log "Payload: ${NEW_PKGS[*]}"

: > "$WORK/files.txt"
for pkg in "${NEW_PKGS[@]}"; do in_chroot "pacman -Qlq $pkg" >> "$WORK/files.txt"; done
sed 's|^/||' "$WORK/files.txt" > "$WORK/files.rel"

log "Copying driver into $PARTSET rootfs"
rsync -a --files-from="$WORK/files.rel" "$MERGED/" "$NEWROOT/"
rsync -a "$UPPER/usr/lib/modules/$KVER/updates" "$NEWROOT/usr/lib/modules/$KVER/"
for pkg in "${NEW_PKGS[@]}"; do
  for ENTRY in "$UPPER/usr/lib/holo/pacmandb/local/$pkg"-[0-9]*; do
    [[ -d "$ENTRY" ]] && rsync -a "$ENTRY" "$NEWROOT/usr/lib/holo/pacmandb/local/" && break
  done
done
chroot "$NEWROOT" depmod "$KVER"
chroot "$NEWROOT" ldconfig

cat > "$NEWROOT/etc/modprobe.d/99-nvidia-patch.conf" <<'EOF'
# Added by steamos-nvidia repatch
blacklist nouveau
options nouveau modeset=0
options nvidia-drm modeset=1 fbdev=1
options nvidia NVreg_PreserveVideoMemoryAllocations=1
EOF
chroot "$NEWROOT" systemctl enable nvidia-suspend nvidia-resume nvidia-hibernate 2>/dev/null || true

CMDLINE_ADD='rd.driver.blacklist=nouveau modprobe.blacklist=nouveau nvidia-drm.modeset=1 nvidia-drm.fbdev=1'
grep -q 'rd.driver.blacklist=nouveau' "$NEWROOT/etc/default/grub" \
  || sed -i -E "s#^(GRUB_CMDLINE_LINUX_DEFAULT=\")#\1$CMDLINE_ADD #" "$NEWROOT/etc/default/grub"

# propagate the self-healing machinery (repatch.sh + driver.conf) so the
# NEXT update is covered too
mkdir -p "$NEWROOT/usr/lib/steamos-nvidia"
cp -a /usr/lib/steamos-nvidia/. "$NEWROOT/usr/lib/steamos-nvidia/"
if [[ ! -f "$NEWROOT/usr/bin/steamos-update.orig" ]]; then
  mv "$NEWROOT/usr/bin/steamos-update" "$NEWROOT/usr/bin/steamos-update.orig"
  cp -a /usr/bin/steamos-update "$NEWROOT/usr/bin/steamos-update"
fi
[[ -f "$NEWROOT/usr/lib/systemd/system/steamos-finish-oobe-migration.service" ]] \
  && ln -sf /dev/null "$NEWROOT/etc/systemd/system/steamos-finish-oobe-migration.service"
[[ -f /etc/sudoers.d/zz-deck-nopasswd ]] \
  && install -m 440 /etc/sudoers.d/zz-deck-nopasswd "$NEWROOT/etc/sudoers.d/zz-deck-nopasswd"

# regenerate the new slot's grub.cfg with the nvidia cmdline
log "Regenerating grub config for $PARTSET"
mkdir -p "$NEWROOT/efi"
mount "$EFIDEV" "$NEWROOT/efi"
mount -t proc proc "$NEWROOT/proc"
mount --rbind /sys "$NEWROOT/sys"; mount --make-rslave "$NEWROOT/sys"
mount --rbind /dev "$NEWROOT/dev"; mount --make-rslave "$NEWROOT/dev"
chroot "$NEWROOT" update-grub
grep -q 'rd.driver.blacklist=nouveau' "$NEWROOT/efi/EFI/steamos/grub.cfg" \
  || die "regenerated grub.cfg is missing the nvidia cmdline"

log "Syncing"
btrfs filesystem sync "$NEWROOT"
sync -f "$NEWROOT"
[[ $WAS_RO -eq 1 ]] && btrfs property set "$NEWROOT" ro true
log "OK — $PARTSET is NVIDIA-ready ($KVER)"
REPATCH
  chmod 755 "$MNT/usr/lib/steamos-nvidia/repatch.sh"

  # ---- wrapper around steamos-update: real update, then repatch the new slot
  if [[ ! -f "$MNT/usr/bin/steamos-update.orig" ]]; then
    mv "$MNT/usr/bin/steamos-update" "$MNT/usr/bin/steamos-update.orig"
  fi
  cat > "$MNT/usr/bin/steamos-update" <<'WRAP'
#!/bin/bash
# steamos-update wrapper (steamos-nvidia self-healing updates).
# Runs Valve's real updater, then rebuilds the NVIDIA driver inside the
# freshly staged OS slot. If that fails, the update is cancelled: the
# bootloader keeps booting the current (working) image.
REAL=/usr/bin/steamos-update.orig
REPATCH=/usr/lib/steamos-nvidia/repatch.sh
LOG=/var/log/steamos-nvidia-repatch.log

is_apply=1
for a in "$@"; do
  case "$a" in check|--supports-duplicate-detection) is_apply=0 ;; esac
done

"$REAL" "$@"
rc=$?

# Edit the boot config of every slot EXCEPT the currently booted one.
# The conf files on the ESP are plain text; editing them directly is the
# only revert that reliably steers steamcl (set-mode booted does NOT undo a
# staged switch, and a zeroed boot-requested-at still gets retried while
# boot-attempts is nonzero — both verified the hard way).
edit_other_confs() {  # args: sed expressions
  local this conf
  this="$(steamos-bootconf this-image 2>/dev/null)" || return 0
  [[ -n "$this" ]] || return 0
  for conf in /esp/SteamOS/conf/*.conf; do
    [[ -f "$conf" ]] || continue
    [[ "$(basename "$conf" .conf)" == "$this" ]] && continue
    sed -i "$@" "$conf"
  done
  sync -f /esp/SteamOS/conf 2>/dev/null || sync
}

if [[ $rc -eq 0 && $is_apply -eq 1 ]]; then
  echo "Update staged. Building NVIDIA driver for the new OS (10-20 min, do NOT power off)..." >&2
  if "$REPATCH" other >> "$LOG" 2>&1; then
    echo "NVIDIA driver installed into the updated OS. Safe to reboot." >&2
    # make sure the freshly patched slot is bootable (clears an
    # image-invalid left by a previously cancelled update)
    edit_other_confs -e 's/^image-invalid:.*/image-invalid: 0/'
  else
    echo "!! NVIDIA driver rebuild FAILED — cancelling this update." >&2
    echo "!! The system will keep booting the current working version." >&2
    echo "!! Details: $LOG" >&2
    edit_other_confs \
      -e 's/^boot-requested-at:.*/boot-requested-at: 0/' \
      -e 's/^boot-attempts:.*/boot-attempts: 0/' \
      -e 's/^image-invalid:.*/image-invalid: 1/'
    steamos-bootconf set-mode booted 2>/dev/null
    exit 1
  fi
fi
exit $rc
WRAP
  chmod 755 "$MNT/usr/bin/steamos-update"
fi

# ----------------------------------------------------- kernel cmdline
# rd.driver.blacklist keeps the initramfs from loading its bundled nouveau,
# so no initramfs regeneration is needed. /etc/default/grub matters too:
# the installer's update-grub regenerates the target's grub.cfg from it.
CMDLINE_ADD='rd.driver.blacklist=nouveau modprobe.blacklist=nouveau nvidia-drm.modeset=1 nvidia-drm.fbdev=1'
log "Appending to kernel cmdline: $CMDLINE_ADD"
sed -i -E "s#(steamenv_boot[[:space:]]+linux[[:space:]]+/boot/vmlinuz[^\n]*)#\1 $CMDLINE_ADD#" \
  "$EFIMNT/EFI/steamos/grub.cfg"
grep -q 'rd.driver.blacklist=nouveau' "$EFIMNT/EFI/steamos/grub.cfg" \
  || die "grub.cfg edit failed — cmdline pattern not found"
if [[ -f "$MNT/etc/default/grub" ]]; then
  sed -i -E "s#^(GRUB_CMDLINE_LINUX_DEFAULT=\")#\1$CMDLINE_ADD #" "$MNT/etc/default/grub"
fi

# -------------------------------------------------- one-click installer
if [[ $ADD_INSTALLER -eq 1 ]]; then
  TOOLS="$HOMEMNT/deck/tools"
  DESKTOP="$HOMEMNT/deck/Desktop"
  [[ -f "$TOOLS/repair_device.sh" ]] \
    || die "No repair_device.sh in image home — is this the OOBE *repair* image?"

  log "Patching Valve's repair_device.sh for generic hardware"
  cp -a "$TOOLS/repair_device.sh" "$TOOLS/repair_device.sh.stock"
  # shellcheck disable=SC2016  # literal $ wanted in the patched script
  sed -i \
    -e 's|^DISK=/dev/nvme0n1$|DISK="${STEAMOS_TARGET_DISK:-/dev/nvme0n1}"|' \
    -e 's|^DISK_SUFFIX=p$|DISK_SUFFIX=""; [[ "$DISK" =~ [0-9]$ ]] \&\& DISK_SUFFIX="p"|' \
    "$TOOLS/repair_device.sh"
  grep -q 'STEAMOS_TARGET_DISK' "$TOOLS/repair_device.sh" || die "DISK patch failed"
  # skip NVMe sanitize for non-NVMe targets (it error-traps on SATA/virtio)
  # shellcheck disable=SC2016
  sed -i '/^all)$/,/^  ;;$/ s|^  sanitize_all$|  if [[ "$DISK" == /dev/nvme* ]]; then sanitize_all; else ewarn "Non-NVMe target: skipping NVMe sanitize"; fi|' \
    "$TOOLS/repair_device.sh"
  grep -q 'skipping NVMe sanitize' "$TOOLS/repair_device.sh" || die "sanitize patch failed"

  log "Installing disk-picker wrapper + desktop icons"
  cat > "$TOOLS/install_to_hd.sh" <<'WRAPPER'
#!/bin/bash
# One-click SteamOS (NVIDIA-patched) installer/upgrader. Picks an internal
# disk, then runs Valve's repair_device.sh which clones the running USB
# system onto it.
#   $1 = all    → full install: wipes the disk (default)
#   $1 = system → upgrade: reimages the OS partitions, KEEPS games & data
set -eu

MODE="${1:-all}"
case "$MODE" in
  all)
    TITLE="Install SteamOS (NVIDIA) to Hard Drive"
    PICK_TEXT="Select the disk to install SteamOS onto.\n\nEVERYTHING ON THE SELECTED DISK WILL BE ERASED."
    CONFIRM_LABEL="ERASE AND INSTALL"
    CONFIRM_TEXT_TPL="About to install SteamOS (NVIDIA-patched) onto:\n\n    %s\n\nThis PERMANENTLY DESTROYS everything on that disk.\nThe install takes several minutes. The machine powers off when done:\nremove the USB stick, then boot from %s."
    ;;
  system)
    TITLE="Upgrade SteamOS (NVIDIA) — keeps games & data"
    PICK_TEXT="Select the disk with the existing SteamOS installation to upgrade.\n\nThe OS partitions are reinstalled from this USB; the home partition\n(games, saves, Steam login) is NOT touched."
    CONFIRM_LABEL="UPGRADE"
    CONFIRM_TEXT_TPL="About to upgrade the SteamOS installation on:\n\n    %s\n\nGames and user data on that disk are preserved.\nOS customisations outside /home will be lost.\nThe machine powers off when done: remove the USB stick and boot."
    ;;
  *) echo "Usage: $0 [all|system]" >&2; exit 1 ;;
esac

err_exit() { zenity --error --no-wrap --text "$1" 2>/dev/null || echo "ERROR: $1" >&2; exit 1; }

# Disk we're running from (the USB) — never offer it as a target
SRC_PART="$(findmnt -no SOURCE /)"
SRC_DISK="$(lsblk -no PKNAME "$SRC_PART" 2>/dev/null | head -1)"

mapfile -t CANDIDATES < <(lsblk -dn -o NAME,SIZE,MODEL,TRAN,TYPE | \
  awk -v src="$SRC_DISK" '$NF=="disk" && $1!=src && $1 !~ /^(loop|zram|sr|nbd|ram)/ {NF--; print}')

[[ ${#CANDIDATES[@]} -gt 0 ]] || err_exit "No target disk found.\nThis machine appears to have no internal drive (other than this USB)."

ROWS=()
for c in "${CANDIDATES[@]}"; do
  name="${c%% *}"; rest="${c#* }"
  ROWS+=(FALSE "/dev/$name" "$rest")
done

TARGET=$(zenity --list --radiolist --title "$TITLE" \
  --text "$PICK_TEXT" \
  --column "" --column "Disk" --column "Size / Model / Bus" \
  --width 640 --height 340 "${ROWS[@]}") || exit 0
[[ -n "$TARGET" && -b "$TARGET" ]] || err_exit "No disk selected."

# Upgrade mode only makes sense on a disk that already has the SteamOS layout
if [[ "$MODE" == system ]]; then
  if ! lsblk -no PARTLABEL "$TARGET" 2>/dev/null | grep -qx "rootfs-A"; then
    err_exit "No existing SteamOS installation found on $TARGET.\nUse \"Install SteamOS (NVIDIA) to Hard Drive\" for a fresh install."
  fi
fi

# shellcheck disable=SC2059  # template contains the %s placeholders
CONFIRM_TEXT="$(printf "$CONFIRM_TEXT_TPL" "$TARGET" "$TARGET")"
zenity --question --no-wrap --title "Final confirmation" --ok-label "$CONFIRM_LABEL" --cancel-label "Cancel" \
  --text "$CONFIRM_TEXT" || exit 0

# POWEROFF=1: end with a shutdown prompt so the user can pull the USB
exec sudo env STEAMOS_TARGET_DISK="$TARGET" POWEROFF=1 \
  "$(dirname "$(readlink -f "$0")")/repair_device.sh" "$MODE"
WRAPPER
  chmod 755 "$TOOLS/install_to_hd.sh"

  cat > "$DESKTOP/Install SteamOS NVIDIA.desktop" <<'ICON'
[Desktop Entry]
Name=Install SteamOS (NVIDIA) to Hard Drive
GenericName=Install SteamOS (NVIDIA) to Hard Drive
Comment=Erase an internal disk and install this NVIDIA-patched SteamOS onto it
Exec=/home/deck/tools/install_to_hd.sh all
Icon=drive-harddisk
Path=/home/deck
Terminal=true
Type=Application
StartupNotify=true
ICON
  chmod 755 "$DESKTOP/Install SteamOS NVIDIA.desktop"

  cat > "$DESKTOP/Upgrade SteamOS NVIDIA.desktop" <<'ICON'
[Desktop Entry]
Name=Upgrade SteamOS (NVIDIA) — keeps games & data
GenericName=Upgrade SteamOS (NVIDIA) — keeps games & data
Comment=Reinstall the OS partitions from this USB while preserving the home partition
Exec=/home/deck/tools/install_to_hd.sh system
Icon=system-software-update
Path=/home/deck
Terminal=true
Type=Application
StartupNotify=true
ICON
  chmod 755 "$DESKTOP/Upgrade SteamOS NVIDIA.desktop"

  chown -R 1000:1000 "$TOOLS/install_to_hd.sh" "$TOOLS/repair_device.sh" \
    "$TOOLS/repair_device.sh.stock" "$DESKTOP/Install SteamOS NVIDIA.desktop" \
    "$DESKTOP/Upgrade SteamOS NVIDIA.desktop"

  log "Adding NOPASSWD sudoers drop-in for deck (needed by the install icon)"
  echo 'deck ALL=(ALL) NOPASSWD: ALL' > "$MNT/etc/sudoers.d/zz-deck-nopasswd"
  chmod 440 "$MNT/etc/sudoers.d/zz-deck-nopasswd"
fi

# ----------------------------------------------------------- sanity check
log "Sanity checks"
compgen -G "$MNT/usr/lib/modules/$KVER/updates/dkms/nvidia.ko*" >/dev/null || die "nvidia.ko missing from image"
grep -q 'blacklist nouveau' "$MNT/etc/modprobe.d/99-nvidia-patch.conf" || die "modprobe conf is empty/missing"
if [[ $UPDATE_MODE == selfheal ]]; then
  grep -q 'self-healing' "$MNT/usr/bin/steamos-update" || die "update wrapper missing"
  [[ -f "$MNT/usr/bin/steamos-update.orig" ]] || die "original steamos-update not preserved"
  grep -q 'repatch' "$MNT/usr/lib/steamos-nvidia/repatch.sh" || die "repatch tool missing"
  grep -q "^DRIVER_VERSION=\"$DRIVER_VERSION\"" "$MNT/usr/lib/steamos-nvidia/driver.conf" || die "driver.conf missing/wrong"
  [[ -L "$MNT/etc/systemd/system/atomupd.service" ]] && die "atomupd must NOT be masked in selfheal mode"
fi
compgen -G "$MNT/usr/lib/firmware/nvidia/*/gsp_*.bin" >/dev/null || warn "GSP firmware not found — nvidia-open needs it"
[[ -f "$MNT/usr/share/vulkan/icd.d/nvidia_icd.json" ]] || warn "Vulkan ICD json missing"
AVAIL_AFTER="$(df -m --output=avail "$MNT" | tail -1 | tr -d ' ')"
log "Rootfs free space after install: ${AVAIL_AFTER} MB"

# Flush all pending writes BEFORE flipping the subvolume read-only —
# flipping with delalloc data still queued can silently produce 0-byte files.
log "Syncing filesystems"
btrfs filesystem sync "$MNT"
sync -f "$MNT"; sync -f "$HOMEMNT"; sync -f "$EFIMNT"

log "Restoring btrfs read-only property"
btrfs property set "$MNT" ro true

log "Unmounting"
cleanup
trap - EXIT

log "DONE — $OUT"
cat <<EOF

  Driver:  nvidia-open (DKMS) $NVIDIA_VER for kernel $KVER
           (latest Arch at build time, pinned — Valve's mirror only has 575.x)
$( case $UPDATE_MODE in
     selfheal) echo "  Updates: SELF-HEALING — updating from within Steam works; the SAME
           pinned driver is rebuilt for each new OS version automatically
           (adds 10-20 min per update; failed rebuilds cancel the update,
           system stays working). For a NEWER driver later: rerun this
           script and reinstall from the fresh USB image." ;;
     hold)     echo "  Updates: OS updates HELD (atomupd + OOBE migration masked, CLIs stubbed)." ;;
     stock)    echo "  Updates: STOCK behaviour — an OS update will REMOVE the NVIDIA driver!" ;;
   esac )
$( [[ $ADD_INSTALLER -eq 1 ]] && echo "  Install: boot the USB → double-click \"Install SteamOS (NVIDIA) to
           Hard Drive\" → pick disk → machine powers off → remove USB, boot." )

  Flash:   sudo dd if="$OUT" of=/dev/sdX bs=4M status=progress conv=fsync
  Needs:   UEFI + Secure Boot off; RTX 20xx or newer (nvidia-open = Turing+).
  Cache:   $WORKDIR (speeds up reruns; safe to delete)
EOF
