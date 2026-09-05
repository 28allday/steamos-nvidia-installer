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
#   2. verify the current partition layout matches what the eventual table
#      rewrite assumes (rootfs-A/B, var-A/B, home contiguous, in that
#      order, 1MiB-aligned) — refuse before touching anything if not
#   3. shrink+fsck home (offline resize2fs, verified against its actual
#      minimum size so real files can't be truncated)
#   4. physically copy the shrunk range forward by the exact shift amount,
#      in chunks equal to that shift, HIGH-TO-LOW — the only order that's
#      memmove-safe on overlapping ranges without needing anything fancier
#      than dd (any given chunk's destination never lands on a not-yet-read
#      source, since the chunk ahead of it was already relocated out of
#      the way first)
#   5. checksum every chunk immediately before/after moving it — abort
#      before ever touching the partition table on any mismatch
#   6. fsck the relocated filesystem at its new physical offset,
#      independent of the (still old, still correct) partition table
#   7. only now rewrite the partition table, read it back to confirm home
#      actually landed where the relocated data was written, then fsck
#      once more through the normal device path to confirm table and data
#      agree
#
# Interruption: a chunk's source is left untouched only until the PREVIOUS
# (higher-index) chunk overwrites it — so past the very first chunk,
# blindly retrying step 4 from the top is NOT safe. Chunk i's destination
# is chunk i+1's original source, so a second pass re-reads already-shifted
# data and shifts it again — double-moving everything and destroying the
# first (highest-index) chunk's data outright. Instead, step 4 keeps a
# progress record — {disk GUID, home start, shift amount, chunk count,
# next chunk index} — on the live environment's OWN storage (next to this
# script, never the target disk), fsynced after every verified chunk and
# removed only once the partition table rewrite (step 7) has completed. On
# entry, a record matching this disk/geometry resumes the loop exactly
# where it left off (skipping the shrink and its fsck, already done); a
# record that exists but doesn't match refuses instead of guessing.
# Mounts a root slot, grows its btrfs to fill whatever its partition's
# CURRENT size is, and verifies the result actually reached that size
# instead of trusting the exit code alone -- "resize max" has been observed
# to exit 0 without fully taking effect on one slot, cause unconfirmed.
# Non-fatal on ANY failure here (best-effort enlargement, not worth
# aborting the whole repair over -- a slot that isn't mountable right now
# for whatever reason was either about to be overwritten anyway or is none
# of this function's business) but always LOUD about it, so a silent
# no-op like that doesn't go unnoticed again.
#   $1 partition device (e.g. /dev/nvme0n1p4)
_grow_root_slot()
{
  local slot_dev="$1" slot_mnt part_bytes fs_bytes
  slot_mnt="$(mktemp -d)"
  if ! cmd mount "$slot_dev" "$slot_mnt"; then
    ewarn "Could not mount $slot_dev to grow its filesystem -- skipping (best-effort enlargement, not worth aborting the repair over)"
    rmdir -- "$slot_mnt"
    return 0
  fi
  if ! cmd btrfs filesystem resize max "$slot_mnt"; then
    ewarn "btrfs resize failed on $slot_dev -- skipping (best-effort enlargement, not worth aborting the repair over)"
    cmd umount "$slot_mnt"
    rmdir -- "$slot_mnt"
    return 0
  fi
  part_bytes="$(blockdev --getsize64 "$slot_dev")"
  fs_bytes="$(df -B1 --output=size "$slot_mnt" | tail -1 | tr -d ' ')"
  if (( fs_bytes < part_bytes - 16777216 )); then
    ewarn "btrfs on $slot_dev is only ${fs_bytes} bytes after resize, but its partition is ${part_bytes} bytes -- the grow did not fully take effect (continuing anyway; retry from the running system with 'btrfs filesystem resize max /' once booted into this slot)"
  fi
  cmd umount "$slot_mnt"
  rmdir -- "$slot_mnt"
}

# Verifies the CURRENT on-disk layout is what the partition-table rewrite
# in maybe_grow_rootfs() assumes: rootfs-A, rootfs-B, var-A, var-B, home
# physically contiguous, in that order, 1MiB-aligned -- true for Valve's
# stock layout and this script's own "all" target, but never actually
# checked against the live table before now. sgdisk's --new=...:0:...
# packs each new partition right after the previous one in command-line
# order, so if this assumption is wrong, the rewritten table lands home at
# the wrong offset -- pointing at data that was never physically moved
# there, or missing the front of the data that WAS. The final post-rewrite
# fsck would then run against that mismatch and either mangle it under -y
# or fail outright, with the correctly relocated data sitting untouched
# nearby but no longer reachable through the table. Dies before anything
# is touched if any of this doesn't hold.
#   $1 disk sector size  $2 CURRENT rootfs size (MiB)  $3 target rootfs
#   size (MiB)  $4 var size (MiB)  $5 home's current start (MiB)
#   $6 planned shift amount (MiB)
_assert_relocation_layout()
{
  local ss="$1" cur_root_mib="$2" target_mib="$3" var_mib="$4" home_start_mib="$5" shift_mib="$6"
  (( ss > 0 && 1048576 % ss == 0 )) \
    || die "Disk sector size ($ss) does not evenly divide 1MiB -- refusing to verify partition layout"
  local mib_sectors=$(( 1048576 / ss ))

  local -a partnums=("$FS_ROOT_A" "$FS_ROOT_B" "$FS_VAR_A" "$FS_VAR_B" "$FS_HOME")
  local -a expect_mib=("$cur_root_mib" "$cur_root_mib" "$var_mib" "$var_mib")
  local idx=0 partnum info first last start_mib end_mib prev_end_mib="" root_a_start_mib="" home_start_mib_read=""
  for partnum in "${partnums[@]}"; do
    info="$(sgdisk -i "$partnum" "$DISK")"
    first="$(awk '/^First sector:/{print $3}' <<<"$info")"
    last="$(awk '/^Last sector:/{print $3}' <<<"$info")"
    [[ "$first" =~ ^[0-9]+$ && "$last" =~ ^[0-9]+$ ]] \
      || die "Could not read partition $partnum's sectors -- refusing to grow rootfs (unexpected disk layout)"
    (( first % mib_sectors == 0 )) \
      || die "Partition $partnum does not start on a 1MiB boundary -- refusing to grow rootfs (unexpected disk layout)"
    start_mib=$(( first / mib_sectors ))
    if (( idx == 0 )); then
      root_a_start_mib=$start_mib
    else
      (( start_mib == prev_end_mib )) \
        || die "Partition $partnum does not immediately follow the previous partition (expected rootfs-A, rootfs-B, var-A, var-B, home contiguous in that order) -- refusing to grow rootfs (unexpected disk layout)"
    fi
    if (( idx == 4 )); then
      # home is last and fills the rest of the disk -- its END is bounded
      # by the GPT backup header/array reserved at the very end of the
      # disk, which is essentially never 1MiB-aligned, so unlike the other
      # four partitions there is no end boundary to check here.
      home_start_mib_read=$start_mib
    else
      (( (last + 1) % mib_sectors == 0 )) \
        || die "Partition $partnum does not end on a 1MiB boundary -- refusing to grow rootfs (unexpected disk layout)"
      end_mib=$(( (last + 1) / mib_sectors ))
      (( end_mib - start_mib == expect_mib[idx] )) \
        || die "Partition $partnum is $(( end_mib - start_mib ))MiB, expected ${expect_mib[idx]}MiB -- refusing to grow rootfs (unexpected disk layout)"
      prev_end_mib=$end_mib
    fi
    (( ++idx ))
  done

  (( home_start_mib_read == home_start_mib )) \
    || die "Current home start (${home_start_mib_read}MiB) does not match what was read earlier (${home_start_mib}MiB) -- refusing to grow rootfs (disk changed mid-run?)"

  local expected_new_home_start_mib=$(( root_a_start_mib + 2 * target_mib + 2 * var_mib ))
  (( expected_new_home_start_mib == home_start_mib + shift_mib )) \
    || die "Post-resize home offset would be ${expected_new_home_start_mib}MiB, but the relocated data is being placed at $(( home_start_mib + shift_mib ))MiB -- refusing to rewrite the partition table (unexpected disk layout)"
}

# Progress record for the chunk-relocation loop in maybe_grow_rootfs(),
# kept on the live environment's own storage (next to this very script --
# never the target disk) so an interruption, including a power cut, can be
# resumed instead of unsafely retried from the top (see the comment at the
# top of this file for why retry-from-scratch loses data past the first
# chunk).
_resume_state_file()
{
  local self_dir
  self_dir="$(dirname "$(readlink -f "$0")")"
  echo "$self_dir/.grow_rootfs.resume"
}

# Prints the next chunk index to process when a record matches the given
# disk/geometry; prints nothing if no record exists; dies if a record
# exists but doesn't match (refuses to guess rather than risk resuming
# against the wrong disk or a stale geometry). Callers MUST be invoked as
# `x="$(_resume_state_read ...)" || die ...` -- this function is meant to
# be called via command substitution, and a die() (exit) taken from
# inside one only kills that subshell, not the caller, so the caller's
# own die on a non-zero exit status is what actually stops the run.
_resume_state_read()
{
  local disk_guid="$1" home_start_mib="$2" shift_mib="$3" n_chunks="$4"
  local f; f="$(_resume_state_file)"
  [[ -f "$f" ]] || return 0

  local DISK_GUID="" HOME_START_MIB="" SHIFT_MIB="" N_CHUNKS="" NEXT_I=""
  # shellcheck disable=SC1090
  source "$f"

  if [[ "$DISK_GUID" != "$disk_guid" || "$HOME_START_MIB" != "$home_start_mib" \
        || "$SHIFT_MIB" != "$shift_mib" || "$N_CHUNKS" != "$n_chunks" ]]; then
    die "Found a rootfs-grow resume record ($f) that doesn't match this disk/geometry -- refusing to guess (recorded: disk ${DISK_GUID:-?}, home_start ${HOME_START_MIB:-?}MiB, shift ${SHIFT_MIB:-?}MiB, chunks ${N_CHUNKS:-?}; current: disk $disk_guid, home_start ${home_start_mib}MiB, shift ${shift_mib}MiB, chunks $n_chunks). Remove it manually only if you are certain no relocation from a previous run is in progress on this disk."
  fi
  [[ "$NEXT_I" =~ ^-?[0-9]+$ ]] \
    || die "Resume record $f has a corrupt NEXT_I value -- refusing to guess. Remove it manually only if certain no relocation is in progress on this disk."
  echo "$NEXT_I"
}

_resume_state_write()
{
  local disk_guid="$1" home_start_mib="$2" shift_mib="$3" n_chunks="$4" next_i="$5"
  local f; f="$(_resume_state_file)"
  {
    printf 'DISK_GUID=%q\n' "$disk_guid"
    printf 'HOME_START_MIB=%q\n' "$home_start_mib"
    printf 'SHIFT_MIB=%q\n' "$shift_mib"
    printf 'N_CHUNKS=%q\n' "$n_chunks"
    printf 'NEXT_I=%q\n' "$next_i"
  } > "$f.tmp"
  sync -- "$f.tmp" 2>/dev/null || sync
  mv -f "$f.tmp" "$f"
  sync -- "$(dirname "$f")" 2>/dev/null || sync
}

_resume_state_clear()
{
  local f; f="$(_resume_state_file)"
  rm -f -- "$f" "$f.tmp"
}

maybe_grow_rootfs()
{
  # Patched in at build time (see patch_grow_rootfs.sh) to whatever
  # --target-root-mib resolved to, so this and PART_SIZE_ROOT in the
  # "all"-target's own repair_device.sh can't drift apart. 8192 here is
  # just this file's own standalone default, for a curl-only download
  # that never goes through the build script's patching.
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

  # Chunk geometry for the relocation loop below -- computed here (not
  # just inside its own section) because the resume-record lookup right
  # after needs it to recognise whether an in-progress record still
  # matches this disk.
  local chunk_mib=$shift_mib n_chunks
  n_chunks=$(( (new_home_mib + chunk_mib - 1) / chunk_mib ))

  local disk_guid
  disk_guid="$(sgdisk -p "$DISK" | awk '/^Disk identifier/{print $4}')"
  [[ -n "$disk_guid" ]] || die "Could not read this disk's GUID -- aborting resize for safety"

  # Refuse before touching anything if the disk doesn't physically look
  # like what the partition-table rewrite near the end of this function
  # assumes -- see _assert_relocation_layout for why that matters. Runs
  # every time (resume or not): the partition table itself is untouched
  # until the very end of this function, so this reads the same thing on
  # a resumed attempt as it would on a fresh one.
  _assert_relocation_layout "$disk_sector_size" "$cur_root_mib" "$target_mib" "$var_mib" "$home_start_mib" "$shift_mib"

  local resume_i=""
  resume_i="$(_resume_state_read "$disk_guid" "$home_start_mib" "$shift_mib" "$n_chunks")" \
    || die "Aborting: rootfs-grow resume record check failed (see message above) -- a die() inside a command substitution only kills that subshell, so this second die is what actually stops the run."

  local start_i
  if [[ -n "$resume_i" ]]; then
    start_i=$resume_i
    if (( start_i >= 0 )); then
      estat "Resuming an interrupted rootfs grow at chunk $(( n_chunks - start_i ))/$n_chunks"
    else
      estat "Resuming an interrupted rootfs grow (data copy already completed; verifying before committing the partition table)"
    fi
  else
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
    min_blocks="$(resize2fs -P "$home_dev" 2>&1 | tail -1 | grep -oE '[0-9]+$')"
    min_mib=$(( min_blocks * block_size / 1048576 ))
    if (( new_home_mib < min_mib + 2048 )); then
      eerr "Not enough free space on home to grow system partitions safely -- skipping resize."
      return 0
    fi

    estat "Shrinking home filesystem to make room (${new_home_mib}MiB)"
    cmd resize2fs "$home_dev" "${new_home_mib}M" || die "home filesystem resize failed -- aborting"
    cmd e2fsck -f -y "$home_dev" || die "home partition failed fsck after shrink -- aborting"

    start_i=$(( n_chunks - 1 ))
  fi

  _resume_state_write "$disk_guid" "$home_start_mib" "$shift_mib" "$n_chunks" "$start_i"

  estat "Relocating home data ${shift_mib}MiB forward (copies ${new_home_mib}MiB, this takes a while)"
  local i this_start this_size src_off dst_off src_sum dst_sum
  for (( i = start_i; i >= 0; i-- )); do
    this_start=$(( i * chunk_mib ))
    this_size=$(( new_home_mib - this_start )); (( this_size > chunk_mib )) && this_size=$chunk_mib
    src_off=$(( home_start_mib + this_start ))
    dst_off=$(( home_start_mib + shift_mib + this_start ))
    estat "  relocating chunk $(( n_chunks - i ))/$n_chunks (${this_size}MiB)"
    src_sum="$(dd if="$DISK" bs=1M skip="$src_off" count="$this_size" status=none | sha256sum | awk '{print $1}')"
    cmd dd if="$DISK" of="$DISK" bs=1M skip="$src_off" seek="$dst_off" count="$this_size" conv=notrunc,fsync status=none \
      || die "Data relocation failed on chunk $(( n_chunks - i ))/$n_chunks -- aborting before touching the partition table. Re-run this repair to resume safely from this chunk (nothing before it will be redone; do NOT retry by any other means, a blind top-of-loop retry is not safe past the first chunk)."
    dst_sum="$(dd if="$DISK" bs=1M skip="$dst_off" count="$this_size" status=none | sha256sum | awk '{print $1}')"
    [[ "$src_sum" == "$dst_sum" ]] \
      || die "Checksum mismatch after relocating chunk $(( n_chunks - i ))/$n_chunks -- aborting before touching the partition table. Re-run this repair to resume safely from this chunk (nothing before it will be redone; do NOT retry by any other means, a blind top-of-loop retry is not safe past the first chunk)."
    _resume_state_write "$disk_guid" "$home_start_mib" "$shift_mib" "$n_chunks" "$(( i - 1 ))"
  done

  estat "Verifying relocated home filesystem before committing the new partition table"
  local new_home_ld relocated_ok=1
  new_home_ld="$(losetup -f --show --read-only --offset $(( (home_start_mib + shift_mib) * 1048576 )) --sizelimit $(( new_home_mib * 1048576 )) "$DISK")" \
    || die "Could not set up a loop device to verify the relocated home filesystem -- aborting before touching the partition table (the relocated data itself is unaffected; re-run this repair to retry)"
  blkid -o value -s TYPE "$new_home_ld" | grep -qx ext4 || relocated_ok=0
  e2fsck -f -n "$new_home_ld" >/dev/null 2>&1 || relocated_ok=0
  cmd losetup -d "$new_home_ld"
  [[ $relocated_ok = 1 ]] || die "Relocated home filesystem failed verification -- refusing to rewrite the partition table (the relocated data itself is unaffected; investigate before re-running)"

  estat "Rewriting partition table: growing rootfs-A/B, repositioning var-A/B and home to match the relocated data"
  cmd sgdisk --delete=$FS_ROOT_A --delete=$FS_ROOT_B --delete=$FS_VAR_A --delete=$FS_VAR_B --delete=$FS_HOME "$DISK"
  cmd sgdisk --new=$FS_ROOT_A:0:+${target_mib}MiB --typecode=$FS_ROOT_A:4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709 --change-name=$FS_ROOT_A:rootfs-A --new=$FS_ROOT_B:0:+${target_mib}MiB --typecode=$FS_ROOT_B:4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709 --change-name=$FS_ROOT_B:rootfs-B --new=$FS_VAR_A:0:+${var_mib}MiB --typecode=$FS_VAR_A:4D21B016-B534-45C2-A9FB-5C16E091FD2D --change-name=$FS_VAR_A:var-A --new=$FS_VAR_B:0:+${var_mib}MiB --typecode=$FS_VAR_B:4D21B016-B534-45C2-A9FB-5C16E091FD2D --change-name=$FS_VAR_B:var-B --new=$FS_HOME:0:0 --typecode=$FS_HOME:933AC7E1-2EB4-4F13-B844-0E14E2AEF915 --change-name=$FS_HOME:home "$DISK"
  cmd partprobe "$DISK" || cmd blockdev --rereadpt "$DISK"

  # Confirm the table sgdisk just wrote actually landed home where the
  # relocated data was written, before the destructive fsck below runs
  # against it -- on a mismatch, -y is exactly the wrong tool to point at
  # correctly relocated data sitting at the wrong table offset.
  estat "Confirming the rewritten table landed where expected"
  local new_home_start_sector new_home_start_mib
  new_home_start_sector="$(sgdisk -i "$FS_HOME" "$DISK" | awk '/^First sector:/{print $3}')"
  [[ "$new_home_start_sector" =~ ^[0-9]+$ ]] \
    || die "Could not read home partition's start sector after the table rewrite -- system is in an inconsistent state, do not proceed, seek manual recovery"
  new_home_start_mib=$(( new_home_start_sector * disk_sector_size / 1048576 ))
  (( new_home_start_mib == home_start_mib + shift_mib )) \
    || die "Home now starts at ${new_home_start_mib}MiB, expected $(( home_start_mib + shift_mib ))MiB -- the rewritten table does not match where the relocated data actually is; system is in an inconsistent state, do not proceed, seek manual recovery"

  _resume_state_clear

  # Deliberately NOT re-growing rootfs-A/B's filesystems here: at this
  # point rootfs-B's new table position is delta_mib into its own OLD
  # data (home is the only partition whose data is physically relocated),
  # so mounting it would fail every time. Valve's own repair_steps() always
  # re-images BOTH rootfs-A and rootfs-B via imageroot() before this
  # function is reached, and imageroot() already runs its own
  # 'btrfs filesystem resize max' after each dd -- so growing them again
  # here is both redundant and, worse, guaranteed to abort on rootfs-B
  # with no path forward (table already rewritten, home already relocated,
  # no OS bootable). The pre-sgdisk pass near the top of this function
  # covers the one legitimate leftover case: an already-grown table whose
  # filesystem was never grown to match.

  estat "Final verification of home through the updated partition table"
  cmd e2fsck -f -y "$home_dev" || die "home failed final verification after the partition table update -- system is in an inconsistent state, do not proceed, seek manual recovery"

  estat "Growing home filesystem to fill its (still large) partition"
  cmd resize2fs "$home_dev"
}
