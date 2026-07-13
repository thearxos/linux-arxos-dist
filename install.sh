#!/usr/bin/env bash
# install.sh — apply linux-arxos updates on a user machine (called by the arx updater for the
# `kernel`-type manifest line). Two jobs, both fail-safe (never leave a box unbootable):
#   1. install/refresh the shipped kernel PACKAGE (from a release artifact), keeping the old
#      kernel in place as the rollback (GRUB keeps prior entries).
#   2. apply any pending LIVE PATCHES (kpatch-style, no reboot) from patches/live/.
# A kernel package bump only takes effect on the next reboot; a live patch takes effect now.
set -u
D=$(cd "$(dirname "$0")" && pwd); S=""; [ "$(id -u)" -ne 0 ] && S=sudo

# 1. kernel package (only if a prebuilt artifact ships in the repo/release; source builds go
#    through build.sh + test-gates.sh on our side, never on the user's box)
PKG=$(ls "$D"/dist/*.pkg.tar.* 2>/dev/null | head -n1)
if [ -n "$PKG" ]; then
  echo ">> installing kernel package $(basename "$PKG") (old kernel kept for rollback)"
  $S pacman -U --noconfirm "$PKG" && $S grub-mkconfig -o /boot/grub/grub.cfg
  echo ">> installed; takes effect on next reboot. Previous kernel remains bootable in GRUB."
fi

# 2. live patches (take effect immediately, no reboot; reversible)
if [ -d "$D/patches/live" ] && command -v modprobe >/dev/null; then
  for lp in "$D"/patches/live/*.ko; do
    [ -e "$lp" ] || continue
    name=$(basename "$lp" .ko)
    if [ -e "/sys/kernel/livepatch/$name" ]; then echo ">> live patch $name already applied"; continue; fi
    echo ">> arming live patch $name"
    $S insmod "$lp" && echo "   applied (revert: echo 0 > /sys/kernel/livepatch/$name/enabled)" \
                     || echo "   !! $name failed to load (kernel too old / patch mismatch) - skipped, system untouched"
  done
fi

# 3. arx-workload tuning — I/O + network, ships with the kernel, applied LIVE (no reboot,
#    no reinstall). sysctl values take effect on `sysctl --system`; scheduler rules on
#    `udevadm trigger`; fd/proc limits on next login; tcp_bbr is loaded now + on every boot.
#    All persist across reboots (they live under /usr/lib and /etc).
if [ -d "$D/tuning" ]; then
  # migrate: earlier builds shipped these as 60-* (out-ranked by elasticsearch.conf / 99-sysctl.conf).
  # drop them so the zz-arxos-* files below are the last word.
  $S rm -f /usr/lib/sysctl.d/60-arxos-io.conf /usr/lib/sysctl.d/60-arxos-net.conf \
           /etc/security/limits.d/60-arxos-limits.conf /usr/lib/udev/rules.d/60-arxos-ioscheduler.rules 2>/dev/null
  for f in "$D"/tuning/*; do
    [ -e "$f" ] || continue
    b=$(basename "$f")
    case "$b" in
      *.rules)        $S install -Dm644 "$f" "/usr/lib/udev/rules.d/$b" ;;
      *-limits.conf)  $S install -Dm644 "$f" "/etc/security/limits.d/$b" ;;
      *-modules.conf) $S install -Dm644 "$f" "/usr/lib/modules-load.d/${b/-modules/}" ;;
      *.conf)         $S install -Dm644 "$f" "/usr/lib/sysctl.d/$b" ;;
    esac
  done
  # BBR needs its module present before the sysctl selects it as the congestion control
  $S modprobe tcp_bbr 2>/dev/null || true
  if $S sysctl --system >/dev/null 2>&1; then echo ">> arx I/O + network tuning applied live (sysctl, no reboot)"; fi
  $S udevadm control --reload >/dev/null 2>&1
  if $S udevadm trigger --subsystem-match=block --action=change >/dev/null 2>&1; then echo ">> I/O scheduler rules applied live (udev, no reboot)"; fi
  # conntrack table only exists once the module is loaded (a firewall/NAT is active); raise it for wide scans
  if [ -e /proc/sys/net/netfilter/nf_conntrack_max ]; then
    $S sysctl -qw net.netfilter.nf_conntrack_max=1048576 2>/dev/null || true
  fi
fi

echo "linux-arxos update step complete"
