Make a backup before you run script

You just need:

Save script, for example, in `/home/user/` in appVM.

Copy file to dom0. Run it in dom0 terminal (qube-name - appVM with script):
`qvm-run --pass-io qube-name 'cat /home/user/anti-forensic.sh' > anti-forensic.sh`


Make file executable. Run in dom0 terminal:
`sudo chmod +x anti-forensic.sh`

Run script in dom0 terminal with sudo
`sudo ./anti-forensic.sh`

After launching Amnesic Mode from the GRUB menu, only dom0 operates in amnesia mode by default.
To run any qube in amnesia mode, just copy any qube to the varlibqubes pool and launch this copy:

In Qube Manager click clone qube and in Advanced select varlibqubes in Storage pool. Or create a new appVM, and select varlibqubes Storage pool in the Advanced Options.

Don’t worry about installing these modes - default Qubes boot won’t be affected at all and won’t change! I created this scenario to be as safe as possible and isolated from the default Qubes boot:
New GRUB options are added to /etc/grub.d/40_custom (so it don’t modify your /etc/default/grub).
dom0 size is only changed if there is more than 100 GB of free space on the disk.
New sysctl options start only in live modes.
New dracut live modules start only in live modes.
GRUB, /boot and initramfs/dracut updates disabled in live modes.

**Notes:**
* Your appVMs / Templates in default vm-pool will act like templates: make persistent changes there, while qubes in the varlibqubes pool will behave like disposable VMs (dvm) - they will be completely wiped after dom0 shutdown.

* If you copied sys-usb, enable keyboard and mouse support for the sys-usb copy in Qubes Global Settings. Do not run both sys-usb qubes simultaneously. Also, do not run sys-whonix and its copy at the same time. Additionally, add the sys-whonix copy to Updates in Qubes Global Settings for automatic updates.

* Remember:
`varlibqubes pool` = full amnesia mode (if dom0 in amnesic mode).
`vm-pool` = persistent mode (even if dom0 in amnesic mode!).
See this repo for creating new ephemeral thin pools: https://github.com/nullnullseven/qubes-ephemeral-dvm-pools

* Run script ane change `1)` option after dom0 / Xen kernel updates in default persistent dom0 for grub_custom kernel update. Re-running script won’t break anything.

* You can update templates if they are not added to varlibqubes pool. But always update dom0 in persistent mode (default boot)!

* You can make backups of all VMs (and dom0) in amnesic modes. Don’t back up vm-copies - it will only increase the backup size. If you need to create backup a vm-copy, then vm-copy must be powered off (this rule applies to VMs from varlibqubes), otherwise backup won’t work.

* Max memory in zram mode must exceed the size of dom0 on disk. For example, if dom0 size is 10 GB, zram disk size should be at least 13 GB (dom0 + 3 GB free space). Otherwise, zram0 mode will fail to start due to insufficient disk space! This error may occur after a dom0 update, as updates increase the size of dom0 on the disk.


**Qubes Encrypted-Overlay Amnesic Mode** – this mode intercepts the standard boot process to transparently layer a LUKS2-encrypted writable filesystem on top of the immutable root image. The module first remounts the physical root read-only, then generates a 512-bit ephemeral AES-XTS key in RAM and provisions a sparse disk-backed LUKS2 container using dm-crypt. This encrypted block device mounted as the overlay upperdir, while the original rootfs serves as the lowerdir. The final pivot applies an overlayfs mount with volatile semantics, ensuring all runtime writes are redirected into the encrypted layer and will be discarded on reboot. Bind mounts expose the underlying layers for introspection, and the ephemeral key is securely shredded from memory before handing control to the real init. Dom0 security is achieved through isolation rw-upperdir from read-only persistent storage in lowerdir. This mode allows you to run massive VMs of tens or even hundreds of GB, since you’re not limited by the amount of RAM - only by your disk space. By default, overlay module creates a 20 GB dm-container (your free space in overlay mode).

**Qubes TMPFS-Overlay Amnesic Mode** – using tmpfs (RAM) in overlay upperdir. Because all operations run directly from memory instead of disk, this delivers maximum speed – RAM is orders of magnitude faster than storage – and minimizes CPU load by eliminating disk I/O overhead and filesystem synchronization operations.

**Qubes Zram-Live Amnesic Mode** – this mode sets up live mode via zram: root FS from disk is copied into zram (compressed block device in RAM), then mounted for fully memory-based operation. The pivot completes with the zram-backed filesystem mounted as the new /sysroot with restrictive flags, after which the underlying physical root is detached. This yields a zero-write, wear-free runtime environment that eliminates disk I/O latency for system operations, and isolates the physical storage from all runtime mutations. This mode is heavily dependent on RAM - you use 80% of the device’s memory multiplied by ~2x zram compression for live storage.

Use this bashrc theme for checking dom0 mode https://github.com/nullnullseven/bashrc-themes/blob/main/cyberpunk-theme

<img width="579" height="99" alt="87e6447a814b770afe41ef3031736daf723edfe4" src="https://github.com/user-attachments/assets/798be937-a32c-47bc-aeac-e478981b3d7c" />



<img width="357" height="99" alt="0a0f77bc9cbb0d8935ca8a3b73e275329cca37cc" src="https://github.com/user-attachments/assets/22bd79d1-4bc3-42d3-ab24-b5bb0ec10323" />



<img width="404" height="93" alt="62e016f8dbf74afab1076efc2ef7bf9238754088" src="https://github.com/user-attachments/assets/42f38a26-a87d-4676-b3ef-d70587927ce0" />

