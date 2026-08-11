# Applies every patch needed for the "grow rootfs-A/B" feature to the
# already-copied repair_device.sh at $TOOLS/repair_device.sh. Sourced from
# steamos-nvidia-installer.sh — expects $TOOLS, $SCRIPT_DIR and the usual
# log/warn/die helpers already in scope.
patch_grow_rootfs()
{
  # Enlarge rootfs-A/B (Valve ships 5GiB, which "no space left on device"s
  # on any real driver upgrade). Bumping this constant only takes effect
  # via the destructive "all" target (full wipe + sfdisk repartition) —
  # it's the one-time path: run "all" once from this USB and every later
  # "system" repair on that disk inherits the bigger partitions for free,
  # since "system" mode never rewrites the partition table on its own.
  sed -i -e 's|^PART_SIZE_ROOT="5120"|PART_SIZE_ROOT="8192"|' "$TOOLS/repair_device.sh"
  grep -q 'PART_SIZE_ROOT="8192"' "$TOOLS/repair_device.sh" || die "rootfs partition-size patch failed"

  # btrfs doesn't auto-grow into a larger block device after a raw dd clone
  # (the filesystem stays the source's original size) — grow it to fill
  # rootfs-A/B now that the partition itself is bigger.
  sed -i -e '/^imageroot()$/,/^}$/{s|^  cmd btrfs check "$newroot"$|&\n  local mnt; mnt="$(mktemp -d)"\n  cmd mount "$newroot" "$mnt"\n  cmd btrfs filesystem resize max "$mnt"\n  cmd umount "$mnt"\n  rmdir -- "$mnt"|}' \
    "$TOOLS/repair_device.sh"
  grep -q 'btrfs filesystem resize max' "$TOOLS/repair_device.sh" || die "rootfs grow patch failed"

  # Also offer the grow on a "system" repair (existing install, games/home
  # preserved) — not just "all". The runtime logic (maybe_grow_rootfs,
  # physically relocates home's data — see grow_rootfs.fn.sh for why a real
  # relocation is needed, not just resize2fs+sgdisk) lives in its own file.
  # If it's missing (curl-only download of just the main script) degrade
  # cleanly instead of failing the whole build: the size bump above still
  # applies to "all" installs, just not the in-place "system" grow.
  local grow_fn="$SCRIPT_DIR/grow_rootfs.fn.sh"
  if [[ ! -f "$grow_fn" ]]; then
    warn "grow_rootfs.fn.sh not found next to this script (curl-only download?) — skipping the rootfs enlarge-on-repair feature"
    return 0
  fi

  cp "$grow_fn" "$TOOLS/.grow_rootfs.fn"
  sed -i '/^  rmdir -- "$mnt"$/,/^}$/{
/^}$/r '"$TOOLS"'/.grow_rootfs.fn
}' "$TOOLS/repair_device.sh"
  rm -f "$TOOLS/.grow_rootfs.fn"
  grep -q '^maybe_grow_rootfs()$' "$TOOLS/repair_device.sh" || die "rootfs grow-function patch failed"

  sed -i 's|^    verifypart "$(diskpart $FS_HOME)" ext4 home$|&\n  if [[ $writeOS = 1 ]]; then\n    maybe_grow_rootfs\n  fi|' \
    "$TOOLS/repair_device.sh"
  grep -q 'maybe_grow_rootfs$' "$TOOLS/repair_device.sh" || die "rootfs grow call-site patch failed"
}
