profile_qr() {
    profile_standard
    title="Hardware_QR"
    desc="Alpine Linux for Hardware Info QR Collection"
    arch="x86_64"
    # Override initfs_cmdline to include nvme,vfat (profile_base only has loop,squashfs,sd-mod,usb-storage)
    initfs_cmdline="modules=loop,squashfs,sd-mod,usb-storage,nvme,vfat,isofs"
    # kernel_cmdline: only params NOT already in initfs_cmdline (no duplicate modules= or quiet)
    # edd=off     — skip slow EDD BIOS disk probing (5-30s savings)
    # nopnp       — skip legacy PnP device probing
    # usbdelay=1  — nlplug-findfs timeout 1s after last uevent (instead of default ~6s)
    # modprobe.blacklist=floppy,sr_mod,cdrom — prevent 60s timeout on empty CD/DVD drives
    # printk.time=1 initcall_debug — boot profiling tools
    # Prefer firmware/simple framebuffer over GPU-specific KMS. This is more
    # predictable on newer Intel Iris and NVIDIA cards where QR auto-scaling can clip.
    kernel_cmdline="nomodeset video=1024x768@60 modprobe.blacklist=floppy,sr_mod,cdrom usbdelay=1 edd=off nopnp"
    initfs_features="ata base ext4 nvme scsi usb vfat loop squashfs cdrom"
    apks="$apks libqrencode-tools util-linux pciutils lsblk coreutils dmidecode smartmontools fbida file kbd fbset"
    apkovl="genapkovl-qr.sh"
}
