# Games crashing with a SIGSEGV — missing `lib32-libxkbcommon`

## Symptom

A game crashes with a SIGSEGV a minute or two after launch — no GPU driver
errors, no VRAM or RAM pressure, nothing obviously wrong. First observed
with Halo: The Master Chief Collection (Steam appid 976730), running under
Proton, but the underlying cause isn't specific to that game.

## Root cause

SteamOS's built-in Performance Overlay (Steam button + X) runs on
`mangoapp`, part of the `mangohud`/`lib32-mangohud` packages, injected
system-wide into every game the gamescope session launches — not a
per-game setting. If a game has any 32-bit component (a native 32-bit
Linux binary, or a 32-bit anti-cheat helper such as EasyAntiCheat's), the
overlay has to load a 32-bit capsule too.

That capsule has a hard link dependency on `libxkbcommon.so.0`:

```
$ readelf -d /usr/lib32/libMangoHud.so | grep NEEDED
 0x00000001 (NEEDED)  Shared library: [libxkbcommon.so.0]
 0x00000001 (NEEDED)  Shared library: [libwayland-client.so.0]
 ...
```

(`libMangoHud_opengl.so` has the same `DT_NEEDED` entry.) But
`lib32-libxkbcommon` isn't installed anywhere in the shipped image:
64-bit `libxkbcommon` and `lib32-mangohud` are both present, but
`lib32-mangohud`'s own `%DEPENDS%` is just `lib32-glibc lib32-gcc-libs
lib32-dbus lib32-libglvnd` — the dependency is simply missing from
Valve's package. This isn't a conditional failure that needs anti-cheat
or any other second factor to tip it over; the preload can never resolve
on its own, full stop.

Because the overlay is system-wide rather than per-title, and the
failure is unconditional, **any** game with a 32-bit component hits this
the moment the gamescope session tries to inject the overlay into it —
not just Halo MCC, and not only when anti-cheat is in the mix.

## The fix

```bash
steamos-readonly disable
pacman -Sy lib32-libxkbcommon
steamos-readonly enable
```

## Why this needs to be a persistent fix, not a one-off

This is the same class of problem this repo's [self-healing OS
updates](../README.md#os-updates) exist to solve: SteamOS updates itself
with an A/B image swap — each update writes a complete, fresh root image
to the inactive slot rather than patching the running one. Anything
installed by hand with `pacman` lives under `/usr`, and `/usr` is exactly
what the next image replaces. `/etc`, by contrast, is carried over.

So the one-line `pacman` fix above is temporary by construction: the next
routine SteamOS update silently rebuilds `/usr` from stock,
`lib32-libxkbcommon` disappears again, and the crash comes back with no
obvious new cause — until a stable SteamOS release ships with this
package in the base image by default.

## Persistent workaround for an existing install

Images built by this repo after the fix landed install `lib32-libxkbcommon`
into the build chroot itself, from the same frozen `multilib-3.8` mirror
the driver payload already comes from — so it's captured in the payload
and registered in the image's pacman db automatically, and simply
survives A/B updates like everything else this repo installs. If you
built (or rebuilt) after that change, you don't need anything below this
point.

If you're on an already-installed system and don't want to rebuild, a
boot-time systemd service checks for the required package on every boot
and silently reinstalls it if missing — i.e. if a prior update just wiped
it. Both files live under `/etc`, so the check-and-reinstall logic itself
survives the same updates it's guarding against.

`/etc/persist-32bit-libs/reinstall-libs.sh`:

```bash
#!/bin/bash
# Reinstalls pacman packages that SteamOS system updates wipe from /usr.
# Runs on every boot via persist-32bit-libs.service; no-ops if nothing is missing.
set -euo pipefail

PKGS="lib32-libxkbcommon"
MISSING=""

for pkg in $PKGS; do
    if ! pacman -Qi "$pkg" &>/dev/null; then
        MISSING="$MISSING $pkg"
    fi
done

if [ -z "$MISSING" ]; then
    echo "persist-32bit-libs: all packages present, nothing to do."
    exit 0
fi

echo "persist-32bit-libs: missing$MISSING (likely wiped by a SteamOS update) — reinstalling."
steamos-readonly disable
trap 'steamos-readonly enable' EXIT
pacman -Sy --noconfirm --needed $MISSING
echo "persist-32bit-libs: done."
```

`/etc/systemd/system/persist-32bit-libs.service`:

```ini
[Unit]
Description=Reinstall pacman packages wiped by SteamOS system updates (lib32-libxkbcommon)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/etc/persist-32bit-libs/reinstall-libs.sh
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
```

Enable it with:

```bash
sudo systemctl enable persist-32bit-libs.service
```

It runs on every boot — including the one right after an update — and
puts the package back before you ever get back into a game.

## Verification

```bash
journalctl -u persist-32bit-libs.service
```

A clean run logs either `all packages present, nothing to do` or a
`missing ... reinstalling` / `done` pair right after an update.

## Retirement condition

Remove this service once a stable SteamOS release ships with
`lib32-libxkbcommon` included in the base image by default — at that
point the package survives A/B updates on its own and the boot-time check
is no longer needed.

## If a game still crashes after applying this

- Check `journalctl -u persist-32bit-libs.service` first — if it shows a
  recent reinstall, this fix already handled a post-update wipe and isn't
  the cause of the new crash.
- If nothing needed reinstalling, treat it as a separate issue: try a
  different Proton version, test with anti-cheat/multiplayer avoided to
  isolate overlay-injection conflicts, and pull a symbolized backtrace
  (Proton debug symbols + `coredumpctl debug`) rather than relying on the
  raw Wine trampoline trace.
