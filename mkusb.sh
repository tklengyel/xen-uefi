#!/bin/bash -e
k=$1
o=$2
if [ $# -ne 2 ]; then
    echo "Usage $0: key_dir usb_device"
    exit 1;
fi
t=usb.img
if [ ! -d "$k" ]; then
    echo "Failed to find directory $k"
    exit 1;
fi

dd if=/dev/zero of=${o} bs=512 count=102096
parted ${o} "mktable gpt"
parted ${o} "mkpart p fat32 2048s 102049s"
parted ${o} "toggle 1 boot"
parted ${o} "name 1 UEFI"
dd if=/dev/zero of=${t} bs=512 count=100000
mkfs -t vfat -n UEFI-Tools ${t}
mmd -i ${t} ::/EFI
mmd -i ${t} ::/EFI/BOOT
mcopy -i ${t} ${k}/LockDown-signed.efi ::/EFI/BOOT/BOOTX64.efi
dd if=${t} of=${o} bs=512 seek=2048 count=100000
exit 0;
