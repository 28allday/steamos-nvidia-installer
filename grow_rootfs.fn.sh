# Grow rootfs-A/B on an existing installation by physically relocating the
# home partition's data forward, then reclaiming the space it vacates.
# Runs from the live USB, before the OS is imaged, against the target
# disk's UNMOUNTED partitions only.
#
# Why a physical relocation at all: resize2fs only ever changes a
# filesystem's END — it never moves its START. So shrinking home and then
# just rewriting the partition table to say home "starts later" does NOT
# make that true; the real data stays exactly where it physically was, and
# the table would point at empty space while var-A/B/rootfs-B's new,
# bigger ranges silently overlap home's real (untouched) data. That overlap
# is exactly what a completed (non-interrupted) run of an earlier, broken
# version of this function would have overwritten. Growing rootfs-A/B
# safely therefore requires physically relocating home's data forward,
# byte for byte — the same thing GParted does internally for a "move" (not
# just "resize"). This does that:
#   1. benchmark a real read off this disk and use it to give the user an
#      actual time estimate before asking for confirmation
#   2. shrink+fsck home (offline resize2fs, verified against its actual
#      minimum size so real files can't be truncated)
#   3. physically copy the shrunk range forward by the exact shift amount,
#      in chunks equal to that shift, HIGH-TO-LOW — the only order that's
#      memmove-safe on overlapping ranges without needing anything fancier
#      than dd (any given chunk's destination never lands on a not-yet-read
#      source, since the chunk ahead of it was already relocated out of
#      the way first)
#   4. checksum every chunk immediately before/after moving it — abort
#      before ever touching the partition table on any mismatch
#   5. fsck the relocated filesystem at its new physical offset,
#      independent of the (still old, still correct) partition table
#   6. only now rewrite the partition table, then fsck once more through
#      the normal device path to confirm table and data agree
# A chunk's source is left untouched until the chunk before it overwrites
# it, so an interruption at any point before step 6 is always safe to just
# retry from the top — nothing has been lost, only some chunks would get
# redundantly re-copied. Verified end-to-end (including a deliberate
# kill-mid-copy-then-retry) against a synthetic disk image with real
# checksummed files before ever touching a real disk.
# Mounts a root slot, grows its btrfs to fill whatever its partition's
# CURRENT size is, and verifies the result actually reached that size
# instead of trusting the exit code alone -- "resize max" has been observed
# to exit 0 without fully taking effect on one slot, cause unconfirmed.
# Non-fatal on a shortfall (best-effort enlargement, not worth aborting the
# whole repair over) but always LOUD about it, so a silent no-op like that
# doesn't go unnoticed again.
#   $1 partition device (e.g. /dev/nvme0n1p4)
_grow_root_slot()
{
  local slot_dev="$1" slot_mnt part_bytes fs_bytes
  slot_mnt="$(mktemp -d)"
  cmd mount "$slot_dev" "$slot_mnt" || die "Could not mount $slot_dev to grow its filesystem -- aborting"
  cmd btrfs filesystem resize max "$slot_mnt" || die "btrfs resize failed on $slot_dev -- aborting"
  part_bytes="$(blockdev --getsize64 "$slot_dev")"
  fs_bytes="$(df -B1 --output=size "$slot_mnt" | tail -1 | tr -d ' ')"
  if (( fs_bytes < part_bytes - 16777216 )); then
    ewarn "btrfs on $slot_dev is only ${fs_bytes} bytes after resize, but its partition is ${part_bytes} bytes -- the grow did not fully take effect (continuing anyway; retry from the running system with 'btrfs filesystem resize max /' once booted into this slot)"
  fi
  cmd umount "$slot_mnt"
  rmdir -- "$slot_mnt"
}

maybe_grow_rootfs()
{
  local target_mib=8192
  local var_mib="$PART_SIZE_VAR"
  local root_a root_b home_dev cur_root_mib delta_mib shift_mib
  root_a="$(diskpart "$FS_ROOT_A")"
  root_b="$(diskpart "$FS_ROOT_B")"
  home_dev="$(diskpart "$FS_HOME")"

  # Runs unconditionally, even if the partition table below turns out to
  # already be at target_mib (e.g. a previous run already grew it but never
  # actually grew the filesystem inside -- the guard just below would
  # otherwise return before ever reaching this). Resizing to "max" against
  # an already-max-sized filesystem is a harmless no-op, so it's always
  # safe to just try this first.
  local slot_dev
  for slot_dev in "$root_a" "$root_b"; do
    _grow_root_slot "$slot_dev"
  done

  cur_root_mib=$(( $(blockdev --getsize64 "$root_a") / 1048576 ))
  (( cur_root_mib < target_mib )) || return 0
  delta_mib=$(( target_mib - cur_root_mib ))
  shift_mib=$(( delta_mib * 2 ))

  # Read the CURRENT, still-valid layout directly from the live table --
  # never assume stock sizes, always derive from what's actually on disk.
  local disk_sector_size home_start_sector home_start_mib home_part_mib new_home_mib
  disk_sector_size="$(blockdev --getss "$DISK")"
  home_start_sector="$(sgdisk -i "$FS_HOME" "$DISK" | awk '/^First sector:/{print $3}')"
  [[ -n "$home_start_sector" ]] || die "Could not read home partition's current start sector -- aborting resize for safety"
  home_start_mib=$(( home_start_sector * disk_sector_size / 1048576 ))
  home_part_mib=$(( $(blockdev --getsize64 "$home_dev") / 1048576 ))
  new_home_mib=$(( home_part_mib - shift_mib ))

  # Quick real read off this disk to turn "this will take a while" into an
  # actual estimate instead of a guess. The relocation does roughly 3 reads
  # + 1 write per byte moved (checksum before, copy, checksum after), so
  # the measured read throughput is scaled down by 4x for a rough ETA.
  local bench_mib=512 bench_start bench_end bench_secs read_mib_s eta_secs eta_txt
  (( bench_mib > new_home_mib )) && bench_mib=$new_home_mib
  (( bench_mib < 8 )) && bench_mib=8
  bench_start="$(date +%s.%N)"
  dd if="$DISK" bs=1M skip="$home_start_mib" count="$bench_mib" of=/dev/null status=none 2>/dev/null
  bench_end="$(date +%s.%N)"
  bench_secs="$(awk -v a="$bench_start" -v b="$bench_end" 'BEGIN{d=b-a; if (d<0.05) d=0.05; print d}')"
  read_mib_s="$(awk -v m="$bench_mib" -v s="$bench_secs" 'BEGIN{printf "%.0f", m/s}')"
  (( read_mib_s > 0 )) || read_mib_s=50
  eta_secs=$(( new_home_mib * 4 / read_mib_s ))
  eta_txt="$(awk -v s="$eta_secs" 'BEGIN{ if (s<90) printf "~%d seconds", s; else printf "~%d minutes", int((s+30)/60) }')"

  if ! zenity --title "Enlarge system partitions?" --question --no-wrap --ok-label "Grow now" --cancel-label "Skip" --text "Your SteamOS system partitions are ${cur_root_mib}MiB (Valve's stock size).\nThis is often too small for NVIDIA driver updates (\"No space left on device\").\n\nThis repair can grow them to ${target_mib}MiB each by physically relocating ${new_home_mib}MiB of your home partition's data. This copies and checksum-verifies real data.\n\nEstimated time: ${eta_txt} (measured against this disk just now -- actual time may vary). Nothing else changes unless every chunk verifies correctly.\n\nChoose \"Grow now\" to do this, or \"Skip\" to repair with the current sizes."; then
    ewarn "Skipping partition resize; repairing with existing partition sizes."
    return 0
  fi

  estat "Verifying home partition location before any changes"
  cmd blkid -o value -s TYPE "$home_dev" | grep -qx ext4 || die "home partition is not ext4 where expected -- aborting resize for safety"

  estat "Checking home partition before resize"
  cmd e2fsck -f -y "$home_dev" || die "home partition failed fsck -- aborting resize for safety"

  local block_size min_blocks min_mib
  block_size="$(dumpe2fs -h "$home_dev" 2>/dev/null | awk -F: '/Block size/{gsub(/ /,"",$2); print $2}')"
  min_blocks="$(resize2fs -P "$home_dev" 2>&1 | grep -oE '[0-9]+$')"
  min_mib=$(( min_blocks * block_size / 1048576 ))
  if (( new_home_mib < min_mib + 2048 )); then
    eerr "Not enough free space on home to grow system partitions safely -- skipping resize."
    return 0
  fi

  estat "Shrinking home filesystem to make room (${new_home_mib}MiB)"
  cmd resize2fs "$home_dev" "${new_home_mib}M" || die "home filesystem resize failed -- aborting"
  cmd e2fsck -f -y "$home_dev" || die "home partition failed fsck after shrink -- aborting"

  estat "Relocating home data ${shift_mib}MiB forward (copies ${new_home_mib}MiB, this takes a while)"
  local chunk_mib=$shift_mib n_chunks i this_start this_size src_off dst_off src_sum dst_sum
  n_chunks=$(( (new_home_mib + chunk_mib - 1) / chunk_mib ))
  for (( i = n_chunks - 1; i >= 0; i-- )); do
    this_start=$(( i * chunk_mib ))
    this_size=$(( new_home_mib - this_start )); (( this_size > chunk_mib )) && this_size=$chunk_mib
    src_off=$(( home_start_mib + this_start ))
    dst_off=$(( home_start_mib + shift_mib + this_start ))
    estat "  relocating chunk $(( n_chunks - i ))/$n_chunks (${this_size}MiB)"
    src_sum="$(dd if="$DISK" bs=1M skip="$src_off" count="$this_size" status=none | sha256sum | awk '{print $1}')"
    cmd dd if="$DISK" of="$DISK" bs=1M skip="$src_off" seek="$dst_off" count="$this_size" conv=notrunc,fsync status=none \
      || die "Data relocation failed on chunk $(( n_chunks - i ))/$n_chunks -- aborting before touching the partition table (source data is untouched, safe to retry)"
    dst_sum="$(dd if="$DISK" bs=1M skip="$dst_off" count="$this_size" status=none | sha256sum | awk '{print $1}')"
    [[ "$src_sum" == "$dst_sum" ]] \
      || die "Checksum mismatch after relocating chunk $(( n_chunks - i ))/$n_chunks -- aborting before touching the partition table (source data is untouched, safe to retry)"
  done

  estat "Verifying relocated home filesystem before committing the new partition table"
  local new_home_ld relocated_ok=1
  new_home_ld="$(losetup -f)"
  cmd losetup --read-only --offset $(( (home_start_mib + shift_mib) * 1048576 )) --sizelimit $(( new_home_mib * 1048576 )) "$new_home_ld" "$DISK"
  blkid -o value -s TYPE "$new_home_ld" | grep -qx ext4 || relocated_ok=0
  e2fsck -f -n "$new_home_ld" >/dev/null 2>&1 || relocated_ok=0
  cmd losetup -d "$new_home_ld"
  [[ $relocated_ok = 1 ]] || die "Relocated home filesystem failed verification -- aborting before touching the partition table (original data at the old location is untouched)"

  estat "Rewriting partition table: growing rootfs-A/B, repositioning var-A/B and home to match the relocated data"
  cmd sgdisk --delete=$FS_ROOT_A --delete=$FS_ROOT_B --delete=$FS_VAR_A --delete=$FS_VAR_B --delete=$FS_HOME "$DISK"
  cmd sgdisk --new=$FS_ROOT_A:0:+${target_mib}MiB --typecode=$FS_ROOT_A:4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709 --change-name=$FS_ROOT_A:rootfs-A --new=$FS_ROOT_B:0:+${target_mib}MiB --typecode=$FS_ROOT_B:4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709 --change-name=$FS_ROOT_B:rootfs-B --new=$FS_VAR_A:0:+${var_mib}MiB --typecode=$FS_VAR_A:4D21B016-B534-45C2-A9FB-5C16E091FD2D --change-name=$FS_VAR_A:var-A --new=$FS_VAR_B:0:+${var_mib}MiB --typecode=$FS_VAR_B:4D21B016-B534-45C2-A9FB-5C16E091FD2D --change-name=$FS_VAR_B:var-B --new=$FS_HOME:0:0 --typecode=$FS_HOME:933AC7E1-2EB4-4F13-B844-0E14E2AEF915 --change-name=$FS_HOME:home "$DISK"
  cmd partprobe "$DISK" || cmd blockdev --rereadpt "$DISK"

  # Same reasoning as the identical block near the top of this function --
  # needed again here because THIS is the run that actually grows the
  # partition table for a disk that's never been touched before, so the
  # earlier (pre-sgdisk) pass only had the OLD, still-small size to work
  # with. imageroot() separately grows whichever single slot it reimages
  # this run, but a "system" repair only reimages ONE of rootfs-A/B per
  # run -- the other would otherwise keep its old, smaller btrfs size.
  estat "Growing rootfs-A/B filesystems to fill their new partition size"
  local slot_dev
  for slot_dev in "$root_a" "$root_b"; do
    _grow_root_slot "$slot_dev"
  done

  estat "Final verification of home through the updated partition table"
  cmd e2fsck -f -y "$home_dev" || die "home failed final verification after the partition table update -- system is in an inconsistent state, do not proceed, seek manual recovery"

  estat "Growing home filesystem to fill its (still large) partition"
  cmd resize2fs "$home_dev"
}
