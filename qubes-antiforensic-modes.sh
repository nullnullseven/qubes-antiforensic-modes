#!/bin/bash

# Qubes Dom0 Amnesic modes
# ⚠️ Make backup before running! Run as root: sudo ./amnesic.sh
echo "=== Qubes Dom0 Live Boot Setup ==="

#BOOT_UUID
BOOT_UUID=$(findmnt -n -o UUID /boot 2>/dev/null || echo "AUTO_BOOT_NOT_FOUND")
if [ "$BOOT_UUID" = "AUTO_BOOT_NOT_FOUND" ]; then
    BOOT_UUID=$(blkid -s UUID -o value -d $(findmnt -n -o SOURCE /boot 2>/dev/null))
fi

# LUKS_UUID
LUKS_DEVICE=$(blkid -t TYPE="crypto_LUKS" -o device 2>/dev/null | head -n1 || echo "")
if [ -n "$LUKS_DEVICE" ]; then
    LUKS_UUID=$(sudo cryptsetup luksUUID "$LUKS_DEVICE" 2>/dev/null)
else
    LUKS_UUID="AUTO_LUKS_NOT_FOUND"
fi

# Latest XEN_PATH 
XEN_PATH=$(ls /boot/xen*.gz 2>/dev/null | sort -V | tail -1 | xargs basename 2>/dev/null || echo "/xen-4.19.4.gz")

# Latest kernel/initramfs
LATEST_KERNEL=$(ls /boot/vmlinuz-*qubes*.x86_64 2>/dev/null | grep -E 'qubes\.fc[0-9]+' | sort -V | tail -1 | xargs basename)
LATEST_INITRAMFS=$(echo "/initramfs-${LATEST_KERNEL#vmlinuz-}.img")

# Max memory dom0
system_total_mb=$(xl info | grep total_memory | awk '{print $3}')

if [ -n "$system_total_mb" ] && [ "$system_total_mb" -gt 0 ] 2>/dev/null; then
    # 80% total_memory
    DOM0_MAX_MB=$((system_total_mb * 80 / 100))
    DOM0_MAX_GB=$((DOM0_MAX_MB / 1024))
    DOM0_MAX_RAM="dom0_mem=max:${DOM0_MAX_MB}M"
    DOM0_MAX_GBG="${DOM0_MAX_GB}G"
else
    DOM0_MAX_RAM="dom0_mem=max:10240M"
    DOM0_MAX_GB="10"
    DOM0_MAX_GBG="10G"
fi

# qubes_dom0-root
Qubes_Root=$(findmnt -n -o SOURCE /)

# /home/user
if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    USER_HOME="$HOME"
fi

if [ ! -d "$USER_HOME" ]; then
    echo "home dir '$USER_HOME' not found!" >&2
    exit 1
fi

# === dom0 resize ===

REQUIRED_FREE_GB=100
MIN_DOM0_SIZE_GB=40

get_dom0_size_gb() {
    local size_bytes
    size_bytes=$(df -B1 /dev/mapper/qubes_dom0-root 2>/dev/null | awk 'NR==2 {print $2}')
    if [[ -z "$size_bytes" ]]; then
        echo "Warning: failed to determine dom0 size" >&2
        return 1
    fi
    echo "$((size_bytes / 1024 / 1024 / 1024))"
    return 0
}

get_vg_free_gb() {
    local lv_size data_pct
    lv_size=$(lvs --noheadings --nosuffix --units b -o lv_size qubes_dom0/vm-pool 2>/dev/null | tr -dc '0-9')
    data_pct=$(lvs --noheadings -o data_percent qubes_dom0/vm-pool 2>/dev/null | tr ',' '.' | tr -dc '0-9.')

    if [[ -z "$lv_size" || -z "$data_pct" ]]; then
        echo "Warning: failed to determine free space in vm-pool" >&2
        return 1
    fi

    local free_gb
    free_gb=$(awk "BEGIN { printf \"%.0f\", ($lv_size * (100 - $data_pct) / 100) / 1024 / 1024 / 1024 }")
    echo "$free_gb"
    return 0
}

main() {
    if [[ "$EUID" -ne 0 ]]; then
        echo "Warning: This script should be run as root (sudo)" >&2
        # Changed from exit 1 to just warning
    fi

    local dom0_size_gb vg_free_gb
    dom0_size_gb=$(get_dom0_size_gb) || dom0_size_gb="unknown"
    vg_free_gb=$(get_vg_free_gb) || vg_free_gb="unknown"

    echo "Current dom0 size: ${dom0_size_gb} GB"
    echo "Free space in VM pool: ${vg_free_gb} GB"

    if [[ "$vg_free_gb" != "unknown" ]] && ((vg_free_gb < REQUIRED_FREE_GB)); then
        echo "Info: free space is less than ${REQUIRED_FREE_GB} GB (available: ${vg_free_gb} GB) - skipping resize"
        # Changed from exit 0 to continue
    elif [[ "$dom0_size_gb" != "unknown" ]] && ((dom0_size_gb >= MIN_DOM0_SIZE_GB)); then
        echo "Info: dom0 size is already ${dom0_size_gb} GB (>= ${MIN_DOM0_SIZE_GB} GB) - skipping resize"
        # Changed from exit 0 to continue
    else
        echo "Conditions met. Starting dom0 resize..."

        if lvresize --size 40G /dev/mapper/qubes_dom0-root; then
            resize2fs /dev/mapper/qubes_dom0-root
            lvresize -L +20G qubes_dom0/root-pool
            echo "Done. New dom0 size: $(get_dom0_size_gb) GB"
        else
            echo "Warning: dom0 resize failed - continuing with other commands"
        fi
    fi

    echo "--- dom0 resize completed ---"
}

main "$@"

# === swapoff ===
sudo sed -i '/\/dev\/mapper\/swap/!{/^[[:space:]]*#/!{/\<swap\>/s/^/# /}}' /etc/fstab
sudo sed -i '/\/dev\/mapper\/swap/b; /[[:space:]]\+swap[[:space:]]\+/s/^/# /' /etc/fstab

# === harden autostart ===
mkdir -p "$USER_HOME/.config"
if [ ! -f "$USER_HOME/.config/harden.sh" ]; then
    cat > "$USER_HOME/.config/harden.sh" << 'EOF'
#!/bin/bash
sleep 1
if findmnt -n -o SOURCE / | grep -qE "(overlay|/dev/zram0)"; then
    notify-send --expire-time=20000 "Amnesic session is running" "dom0 mode: $(findmnt -n -o SOURCE /)" --icon=dialog-information
    sudo sysctl -w kernel.sysrq=0
    sudo sysctl -w kernel.perf_event_paranoid=3
    sudo sysctl -w kernel.kptr_restrict=2
    sudo sysctl -w kernel.panic=5
    sudo sysctl -w fs.protected_regular=2
    sudo sysctl -w fs.protected_fifos=2
    sudo sysctl -w kernel.printk="3 3 3 3"
    sudo sysctl -w kernel.kexec_load_disabled=1
    sudo sysctl -w kernel.io_uring_disabled=2
    sudo chattr +i /boot/grub2/grub.cfg
    sudo chattr +i /boot
else
    sudo chattr -i /boot/grub2/grub.cfg
    sudo chattr -i /boot
fi
EOF
    chmod 755 "$USER_HOME/.config/harden.sh"
    echo "Created harden.sh"
else
    echo "harden.sh already exists, skipping"
fi

# === autostart desktop entry ===
mkdir -p "$USER_HOME/.config/autostart"
if [ ! -f "$USER_HOME/.config/autostart/harden.desktop" ]; then
    cat > "$USER_HOME/.config/autostart/harden.desktop" << EOF
[Desktop Entry]
Encoding=UTF-8
Version=0.9.4
Type=Application
Name=harden
Comment=
Exec=$USER_HOME/.config/harden.sh
OnlyShowIn=XFCE;
RunHook=0
StartupNotify=false
Terminal=false
Hidden=false
EOF
    echo "Created harden.desktop"
else
    echo "harden.desktop already exists, skipping"
fi

# === Dracut module directories ===
DIR_OVERLAY_CRYPT=/usr/lib/dracut/modules.d/90overlay-crypt
DIR_RAMBOOT=/usr/lib/dracut/modules.d/90ramboot
DIR_OVERLAY=/usr/lib/dracut/modules.d/90overlayfs-root
DIR_RAMWIPE=/usr/lib/dracut/modules.d/40ram-wipe

for d in "$DIR_RAMBOOT" "$DIR_OVERLAY" "$DIR_RAMWIPE" "$DIR_OVERLAY_CRYPT"; do
    if [ ! -d "$d" ]; then
        mkdir -p "$d"
        echo "Created $(basename "$d")"
    else
        echo "$(basename "$d") already exists, skipping"
    fi
done

# === 90overlay-crypt/module-setup.sh ===
if [ ! -f "$DIR_OVERLAY_CRYPT/module-setup.sh" ]; then
    cat > "$DIR_OVERLAY_CRYPT/module-setup.sh" << 'EOF'
#!#!/bin/bash

check() {
    require_binaries cryptsetup || return 1
    require_binaries losetup || return 1
    require_binaries mkfs.ext4 || return 1
    return 0
}

depends() {
    return 0
}

installkernel() {
    hostonly='' instmods overlay 2>/dev/null || true
    hostonly='' instmods dm-crypt 2>/dev/null || true
}

install() {
    inst_multiple cryptsetup losetup mkfs.ext4 dd modprobe mount umount shred
    inst_hook pre-pivot 10 "$moddir/overlay-crypt.sh"
}
EOF
    chmod 755 "$DIR_OVERLAY_CRYPT/module-setup.sh"
    echo "Created 90overlay-crypt/module-setup.sh"
else
    echo "90overlay-crypt/module-setup.sh already exists, skipping"
fi

# === 90overlay-crypt/overlay-crypt.sh ===
if [ ! -f "$DIR_OVERLAY_CRYPT/overlay-crypt.sh" ]; then
    cat > "$DIR_OVERLAY_CRYPT/overlay-crypt.sh" << 'EOF'
#!/bin/bash

. /lib/dracut-lib.sh

if ! getargbool 0 cryptovl ; then
    return
fi

modprobe overlay 2>/dev/null || true
modprobe dm-crypt 2>/dev/null || true

#
mount -o remount,ro /sysroot 2>/dev/null || true

# 
mkdir -p /live/image
mount --bind /sysroot /live/image
umount /sysroot

# 
dd if=/dev/urandom bs=64 count=1 of=/dev/shm/overlay-key status=none
chmod 600 /dev/shm/overlay-key

# create 20 GB size (seek)
mkdir -p /var/lib
dd if=/dev/zero of=/var/lib/overlay-crypt.img bs=1M count=0 seek=20480 status=none

# 
losetup -f
LOOP_DEV=$(losetup -f --show /var/lib/overlay-crypt.img)

# 
cryptsetup luksFormat --type luks2 \
    --cipher aes-xts-plain64 --key-size 512 \
    --hash sha256 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 \
    --batch-mode --key-file /dev/shm/overlay-key "$LOOP_DEV"

# 
cryptsetup open --type luks2 --key-file /dev/shm/overlay-key "$LOOP_DEV" overlaycrypt

# 
mkfs.ext4 -F -L "overlaycrypt" /dev/mapper/overlaycrypt

# 
mkdir -p /cow
mount -o noatime,nodiratime,nobarrier /dev/mapper/overlaycrypt /cow
mkdir -p /cow/work /cow/rw

# 
mount -t overlay -o noatime,nodiratime,volatile,lowerdir=/live/image,upperdir=/cow/rw,workdir=/cow/work,default_permissions,relatime overlay /sysroot

# 
mkdir -p /sysroot/live/cow /sysroot/live/image
mount --bind /cow/rw /sysroot/live/cow
mount --bind /live/image /sysroot/live/image

# 
umount /cow 2>/dev/null || true
umount /live/image 2>/dev/null || true

# 
shred -u /dev/shm/overlay-key 2>/dev/null || rm -f /dev/shm/overlay-key
EOF
    chmod 755 "$DIR_OVERLAY_CRYPT/overlay-crypt.sh"
    echo "Created 90overlay-crypt/overlay-crypt.sh"
else
    echo "90overlay-crypt/overlay-crypt.sh already exists, skipping"
fi

# === 90ramboot/module-setup.sh ===
if [ ! -f "$DIR_RAMBOOT/module-setup.sh" ]; then
    cat > "$DIR_RAMBOOT/module-setup.sh" << 'EOF'
#!/usr/bin/bash
check() {
    return 0
}
depends() {
    return 0
}
install() {
    inst_simple "$moddir/zram-mount.sh"
    inst_hook cleanup 00 "$moddir/zram-mount.sh"
}
EOF
    chmod 755 "$DIR_RAMBOOT/module-setup.sh"
    echo "Created 90ramboot/module-setup.sh"
else
    echo "90ramboot/module-setup.sh already exists, skipping"
fi

# === 90ramboot/zram-mount.sh ===
if [ ! -f "$DIR_RAMBOOT/zram-mount.sh" ]; then
    cat > "$DIR_RAMBOOT/zram-mount.sh" << EOF
#!/bin/sh

. /lib/dracut-lib.sh

if ! getargbool 0 rootzram ; then
    return
fi

mkdir -p /mnt
umount /sysroot
mount -o ro $Qubes_Root /mnt
modprobe zram
echo $DOM0_MAX_GBG > /sys/block/zram0/disksize
#/mnt/usr/sbin/mkfs.xfs -f -m reflink=0 /dev/zram0
/mnt/usr/sbin/mkfs.ext2 /dev/zram0
mount -o nodev,nosuid,noatime,nodiratime /dev/zram0 /sysroot
EXCLUDES=("dev" "proc" "sys" "tmp" "run" "mnt" "media" "lost+found" "var/log")

FIND_EXPR=()
for dir in "${EXCLUDES[@]}"; do
    FIND_EXPR+=(-name "$dir" -o)
done
unset 'FIND_EXPR[${#FIND_EXPR[@]}-1]'
find /mnt -mindepth 1 -maxdepth 1 ! \( "${FIND_EXPR[@]}" \) -exec cp -a {} /sysroot \;
for dir in "${EXCLUDES[@]}"; do
    mkdir -p "/sysroot/$dir"
done

# Disable swap
if [ -f /sysroot/etc/fstab ]; then
    sed -i '/[ \t]swap[ \t]/d' /sysroot/etc/fstab
fi

if [ -d /sysroot/etc/systemd/system ]; then
    ln -sf /dev/null /sysroot/etc/systemd/system/dev-mapper-swap.device
fi

umount /mnt
exit 0
EOF
    chmod 755 "$DIR_RAMBOOT/zram-mount.sh"
    echo "Created 90ramboot/zram-mount.sh"
else
    echo "90ramboot/zram-mount.sh already exists, skipping"
fi

# === 90overlayfs-root/module-setup.sh ===
if [ ! -f "$DIR_OVERLAY/module-setup.sh" ]; then
    cat > "$DIR_OVERLAY/module-setup.sh" << 'EOF'
#!/bin/bash

check() {
    [ -d /lib/modules/$kernel/kernel/fs/overlayfs ] || return 1
}

depends() {
    return 0
}

installkernel() {
    hostonly='' instmods overlay
}

install() {
    inst_hook pre-pivot 10 "$moddir/overlay-mount.sh"
}
EOF
    chmod 755 "$DIR_OVERLAY/module-setup.sh"
    echo "Created 90overlayfs-root/module-setup.sh"
else
    echo "90overlayfs-root/module-setup.sh already exists, skipping"
fi

# === 90overlayfs-root/overlay-mount.sh ===
if [ ! -f "$DIR_OVERLAY/overlay-mount.sh" ]; then
    cat > "$DIR_OVERLAY/overlay-mount.sh" << 'EOF'
#!/bin/sh
. /lib/dracut-lib.sh

if ! getargbool 0 rootovl ; then
    return
fi

modprobe overlay
mount -o remount,nolock,noatime $NEWROOT
mkdir -p /live/image
mount --bind $NEWROOT /live/image
umount $NEWROOT
mkdir /cow
mount -n -t tmpfs -o mode=0755,size=100%,nr_inodes=500k,noexec,nodev,nosuid,noatime,nodiratime tmpfs /cow
mkdir /cow/work /cow/rw
mount -t overlay -o noatime,nodiratime,volatile,lowerdir=/live/image,upperdir=/cow/rw,workdir=/cow/work,default_permissions,relatime overlay $NEWROOT
mkdir -p $NEWROOT/live/cow
mkdir -p $NEWROOT/live/image
mount --bind /cow/rw $NEWROOT/live/cow
umount /cow
mount --bind /live/image $NEWROOT/live/image
umount /live/image
umount $NEWROOT/live/cow
EOF
    chmod 755 "$DIR_OVERLAY/overlay-mount.sh"
    echo "Created 90overlayfs-root/overlay-mount.sh"
else
    echo "90overlayfs-root/overlay-mount.sh already exists, skipping"
fi

# === ramboot dracut.conf ===
if [ ! -f /etc/dracut.conf.d/ramboot.conf ]; then
    cat > /etc/dracut.conf.d/ramboot.conf << 'EOF'
add_drivers+=" zram "
add_dracutmodules+=" ramboot "
EOF
    echo "Created ramboot.conf"
else
    echo "ramboot.conf already exists, skipping"
fi

# === 40ram-wipe/module-setup.sh ===
if [ ! -f "$DIR_RAMWIPE/module-setup.sh" ]; then
    cat > "$DIR_RAMWIPE/module-setup.sh" << 'EOF'
#!/bin/bash
# -*- mode: shell-script; indent-tabs-mode: nil; sh-basic-offset: 4; -*-
# ex: ts=8 sw=4 sts=4 et filetype=sh

## Copyright (C) 2023 - 2025 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## See the file COPYING for copying conditions.

check() {
   require_binaries sync || return 1
   require_binaries sleep || return 1
   require_binaries dmsetup || return 1
   return 0
}

depends() {
   return 0
}

install() {
   inst_simple "/usr/libexec/ram-wipe/ram-wipe-lib.sh" "/lib/ram-wipe-lib.sh"
   inst_multiple sync
   inst_multiple sleep
   inst_multiple dmsetup
   inst_hook shutdown 40 "$moddir/wipe-ram.sh"
   inst_hook cleanup 80 "$moddir/wipe-ram-needshutdown.sh"
}

installkernel() {
   return 0
}
EOF
    chmod +x "$DIR_RAMWIPE/module-setup.sh"
    echo "Created 40ram-wipe/module-setup.sh"
else
    echo "40ram-wipe/module-setup.sh already exists, skipping"
fi

# === 40ram-wipe/wipe-ram-needshutdown.sh ===
if [ ! -f "$DIR_RAMWIPE/wipe-ram-needshutdown.sh" ]; then
    cat > "$DIR_RAMWIPE/wipe-ram-needshutdown.sh" << 'EOF'
#!/bin/sh

## Copyright (C) 2023 - 2025 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## See the file COPYING for copying conditions.

type getarg >/dev/null 2>&1 || . /lib/dracut-lib.sh

. /lib/ram-wipe-lib.sh

ram_wipe_check_needshutdown() {
   #local kernel_wiperam_setting

   kernel_wiperam_setting="$(getarg wiperam)"

   if [ "$kernel_wiperam_setting" = "skip" ]; then
      force_echo "wipe-ram-needshutdown.sh: Skip, because wiperam=skip kernel parameter detected, OK."
      return 0
   fi

   true "wipe-ram-needshutdown.sh: Calling dracut function need_shutdown to drop back into initramfs at shutdown, OK."
   need_shutdown

   return 0
}

ram_wipe_check_needshutdown
EOF
    chmod +x "$DIR_RAMWIPE/wipe-ram-needshutdown.sh"
    echo "Created 40ram-wipe/wipe-ram-needshutdown.sh"
else
    echo "40ram-wipe/wipe-ram-needshutdown.sh already exists, skipping"
fi

# === 40ram-wipe/wipe-ram.sh ===
if [ ! -f "$DIR_RAMWIPE/wipe-ram.sh" ]; then
    cat > "$DIR_RAMWIPE/wipe-ram.sh" << 'EOF'
#!/bin/sh

## Copyright (C) 2023 - 2025 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## See the file COPYING for copying conditions.

## Credits:
## First version by @friedy10.
## https://github.com/friedy10/dracut/blob/master/modules.d/40sdmem/wipe.sh

. /lib/ram-wipe-lib.sh

drop_caches() {
   sync
   echo 3 > /proc/sys/vm/drop_caches
   sync
}

ram_wipe() {
   #local kernel_wiperam_setting

   kernel_wiperam_setting="$(getarg wiperam)"

   if [ "$kernel_wiperam_setting" = "skip" ]; then
      force_echo "wipe-ram.sh: Skip, because wiperam=skip kernel parameter detected, OK."
      return 0
   fi

   force_echo "wipe-ram.sh: RAM extraction attack defense... Starting RAM wipe pass during shutdown..."

   drop_caches

   force_echo "wipe-ram.sh: RAM wipe pass completed, OK."
}

ram_wipe
EOF
    chmod +x "$DIR_RAMWIPE/wipe-ram.sh"
    echo "Created 40ram-wipe/wipe-ram.sh"
else
    echo "40ram-wipe/wipe-ram.sh already exists, skipping"
fi

# === ram-wipe dracut.conf ===
if [ ! -f /etc/dracut.conf.d/30-ram-wipe.conf ]; then
    cat > /etc/dracut.conf.d/30-ram-wipe.conf << 'EOF'
add_dracutmodules+=" ram-wipe "
EOF
    echo "Created 30-ram-wipe.conf"
else
    echo "30-ram-wipe.conf already exists, skipping"
fi

# === ram-wipe-lib.sh ===
DIR_RAMWIPE_LIB=/usr/libexec/ram-wipe
if [ ! -d "$DIR_RAMWIPE_LIB" ]; then
    mkdir -p "$DIR_RAMWIPE_LIB"
fi

if [ ! -f "$DIR_RAMWIPE_LIB/ram-wipe-lib.sh" ]; then
    cat > "$DIR_RAMWIPE_LIB/ram-wipe-lib.sh" << 'EOF'
#!/bin/sh

## Copyright (C) 2023 - 2025 ENCRYPTED SUPPORT LLC <adrelanos@whonix.org>
## See the file COPYING for copying conditions.

if [ -z "$DRACUT_SYSTEMD" ]; then
    force_echo() {
        echo "<28>dracut INFO: $*" > /dev/kmsg
        echo "dracut INFO: $*" >&2
    }
else
    force_echo() {
        echo "INFO: $*" >&2
    }
fi
EOF
    chmod +x "$DIR_RAMWIPE_LIB/ram-wipe-lib.sh"
    echo "Created ram-wipe-lib.sh"
else
    echo "ram-wipe-lib.sh already exists, skipping"
fi

# Update INITRAMFS
dracut --verbose --force

# Create GRUB custom
echo "Creating GRUB custom ..."

cat > /etc/grub.d/40_custom << EOF
#!/usr/bin/sh
exec tail -n +3 \$0

menuentry 'Qubes Encrypted-Overlay Amnesic Mode' --class qubes --class gnu-linux --class gnu --class os --class xen \$menuentry_id_option 'xen-gnulinux-simple-/dev/mapper/qubes_dom0-root' {
	insmod part_gpt
	insmod ext2
	search --no-floppy --fs-uuid --set=root $BOOT_UUID
	echo 'Loading Xen ...'
	if [ "\$grub_platform" = "pc" -o "\$grub_platform" = "" ]; then
	    xen_rm_opts=
	else
	    xen_rm_opts="no-real-mode edd=off"
	fi
	insmod multiboot2
	multiboot2 /$XEN_PATH placeholder console=none dom0_mem=min:1024M $DOM0_MAX_RAM ucode=scan smt=off gnttab_max_frames=2048 gnttab_max_maptrack_frames=4096 \${xen_rm_opts}
	echo 'Loading Linux $LATEST_KERNEL ...'
	module2 /$LATEST_KERNEL placeholder root=/dev/mapper/qubes_dom0-root ro rd.luks.uuid=$LUKS_UUID rd.lvm.lv=qubes_dom0/root rd.lvm.lv=qubes_dom0/swap plymouth.ignore-serial-consoles rhgb cryptovl quiet module.sig_enforce=1 bootscrub=on
	echo 'Loading initial ramdisk ...'
	insmod multiboot2
	module2 --nounzip $LATEST_INITRAMFS
}

menuentry 'Qubes Zram-Live Amnesic Mode' --class qubes --class gnu-linux --class gnu --class os --class xen \$menuentry_id_option 'xen-gnulinux-simple-/dev/mapper/qubes_dom0-root' {
	insmod part_gpt
	insmod ext2
	search --no-floppy --fs-uuid --set=root $BOOT_UUID
	echo 'Loading Xen ...'
	if [ "\$grub_platform" = "pc" -o "\$grub_platform" = "" ]; then
	    xen_rm_opts=
	else
	    xen_rm_opts="no-real-mode edd=off"
	fi
	insmod multiboot2
	multiboot2 /$XEN_PATH placeholder console=none dom0_mem=min:1024M $DOM0_MAX_RAM ucode=scan smt=off gnttab_max_frames=2048 gnttab_max_maptrack_frames=4096 \${xen_rm_opts}
	echo 'Loading Linux $LATEST_KERNEL ...'
	module2 /$LATEST_KERNEL placeholder root=/dev/mapper/qubes_dom0-root ro rd.luks.uuid=$LUKS_UUID rd.lvm.lv=qubes_dom0/root rd.lvm.lv=qubes_dom0/swap plymouth.ignore-serial-consoles rhgb rootzram quiet module.sig_enforce=1 bootscrub=on
	echo 'Loading initial ramdisk ...'
	insmod multiboot2
	module2 --nounzip $LATEST_INITRAMFS
}
EOF

chmod 755  /etc/grub.d/40_custom

# Update GRUB
grub2-mkconfig -o /boot/grub2/grub.cfg

# Cleanup
dnf clean all
journalctl --vacuum-time=1d
rm -rf /var/cache/dnf/* 2>/dev/null || true


echo
echo "Done!"
echo "✓ ALL STEPS COMPLETED SUCCESSFULLY! Reboot Qubes OS, select one of the new GRUB options (Encrypted-Overlay or Zram-Live), and clone your appVMs to the varlibqubes pool to run in full amnesia mode."
