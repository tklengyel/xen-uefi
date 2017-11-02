This repository contains tools and instructions for installing Xen and dom0 with UEFI/SecureBoot such that all critical components of Xen and the dom0 kernel get SecureBoot verified and measured into the TPM.

# Table of Contents
1. [Generating SecureBoot signing keys](#generating-secureboot-signing-keys)
2. [Placing the system into SecureBoot SetupMode](#placing-the-system-into-secureboot-setupmode)
3. [Installing SecureBoot Keys](#installing-secureboot-keys)
4. [Signing binaries with the SecureBoot keys](#signing-binaries-with-the-secureboot-keys)
5. [Shim setup](#shim-setup)
6. [Xen setup](#xen-setup)
7. [dom0 setup](#dom0-setup)

# 1. Generating SecureBoot signing keys

## Precautions to be taken
------------------------------
Private keys generated for SecureBoot need to be protected at all times. For this purpose we recommend utilizing a locked-down machine (potentially air-gapped) after the required tools have been loaded on to it. Dummy/test keys can be used during regular building to sign binaries, where these signatures can be overwritten later on the secure machine.

## Generating SecureBoot keys on Debian (stretch)
------------------------------
```
apt-get install make gcc libssl1.0-dev git gnu-efi sbsigntool libfile-slurp-perl
git clone https://github.com/tklengyel/xen-uefi --recursive
cd uefi-sb
./mkkeys.sh
```

The generated keys will be located in the `keys` folder.

# 2. Placing the system into SecureBoot SetupMode
----------------------------------
In all cases, the system has to be first switched to UEFI boot before SecureBoot can be enabled. Entering SecureBoot `SetupMode` is then required to be able to load custom SecureBoot Keys. Some firmwares (for example Toshiba) ship with SecureBoot enabled but in `SetupMode` so that the user can replace the keys manually. Other firmwares (for example Dell) provide an interface in their BIOS Setup pages to enter "Custom key mode", also known as "Expert key management" on some firmwares.

**In case the firmware ships with SecureBoot in `UserMode` *and* without a firmware option to delete the keys, that platform is permanently locked, no custom keys can be loaded.**


## Entering SetupMode on Dell
---------------------------------
After power-on or reboot, press F2 to enter `BIOS Setup`. Enable UEFI mode. Locate the SecureBoot tab and enable SecureBoot. Once SecureBoot is enabled select `Expert Key Management` and select `Enable Custom Mode`. To enter `SetupMode` click on the `Delete all keys` button.

## Entering SetupMode with noPK.auth
---------------------------------
Once a platform is taken out of `SetupMode` with custom-keys, the platform can re-enter `SetupMode` with use of the generated `noPK.auth` file and `KeyTool`.

```
cd uefi-sb/efitools
make KeyTool.efi
```

Start `KeyTool` from a USB device or from the `ESP` partition.
1. Edit Keys
2. The Platform Key (PK)
3. Select the GUID
4. Delete with .auth file
5. Locate the noPK.auth file on the USB device or on the ESP partition

The system should now be in `SetupMode` again. 

# 3. Installing SecureBoot keys
## Installing SecureBoot keys with LockDown.efi
------------------------------
LockDown.efi is a minimal EFI application that contains the SecureBoot certificates embedded in the application itself. When executed, it will automatically load the keys into their respective SecureBoot key-slot.

By default LockDown.efi does not wait after the keys have been successfully loaded or in case an error occurred. There is a patch in the git repository that adds a bit of wait time so messages can be read of the screen when using the tool. To apply the patch:

```
cd uefi-sb/efitools
patch -p1 < ../efitools-lockdown-messages.patch
```

After the patch is applied you can either use `mkkeys.sh` to generate a new set of keys, or sign the new LockDown.efi manually:

```
cp ../keys/*.h .
make LockDown.efi
sbsign --key ../keys/DB.key --cert ../keys/DB.crt --output LockDown-signed.efi LockDown.efi 2>/dev/null
cp LockDown-signed.efi ../keys
```

LockDown.efi can be loaded onto a USB key to automatically load SecureBoot keys. In the following `/dev/sdb` is the USB device drive.

1. apt-get install mtools
2. ```./mkusb.sh ./keys /dev/sdb```
3. Reboot the system
3. Put system into SecureBoot SetupMode (custom-key mode) in the BIOS
6. Reboot the system
7. Boot from USB drive
8. Reboot target system

## Installing SecureBoot keys with KeyTool
------------------------------
This section is largely based on the [Gentoo Wiki](https://wiki.gentoo.org/wiki/Sakaki%27s_EFI_Install_Guide/Configuring_Secure_Boot#Method_3:_Inserting_Keys_via_Keytool)

One of the tools that is included with efitools is `KeyTool.efi`, a UEFI application that can be used to load SecureBoot keys into the firmware, even if the firmware itself doesn't provide a screen to do so. The `KeyTool.efi` file can be copied either onto the `ESP` partition directly, or loaded onto a FAT formatted USB drive (with the path `/EFI/BOOT/BOOTX64.efi`).

```
cd uefi-sb/efitools
make KeyTool.efi
```

Make sure to load the keys in the following order (loading PK will take the system out of SecureBoot Setup mode!):
1.  DB
2.  KEK
3.  PK


# 4. Signing binaries with the SecureBoot keys
---------------------------------
In order to allow UEFI applications to execute on a SecureBoot enabled system, the application needs to be signed by a private key that was loaded into the firmware. Signing can be performed with the `sbsign` tool. Signing an application with sbsign as a straight forward process:

```sbsign --key DB.key --cert DB.crt --output app-signed.efi app.efi```

In the above we used the `DB` SecureBoot key to sign our application. For applications that will be verified by the SHIM, the SHIM key would be used in a similar manner.

SHIM is a trivial EFI application that, when run, attempts to open and
execute another application. It will initially attempt to do this via the
standard EFI LoadImage() and StartImage() calls. If these fail (because secure
boot is enabled and the binary is not signed with an appropriate key, for
instance) it will then validate the binary against a built-in certificate. If
this succeeds and if the binary or signing key are not blacklisted then shim
will relocate and execute the binary.

If shim is executed from the location EFI/BOOT/BOOTX64.EFI and FBX64.EFI is present in the same same directory, it will launch FBX64.EFI (fallback) instead of the normal target.  If the launch of the initial target failed, it will launch MMX64.EFI (mokmanager) instead.  Shim will not launch any of these unless they are signed either by DB or MOK keys.

Shim is used to cause Xen to verify DOM0 before launching it.  Shim installs an EFI protocol on the system that can be used to verify images loaded by code executed after shim.  If this protocol is present on the system, Xen will use it to verify DOM0 and halt if the verification fails.


# 5. Shim setup
## Compile and sign SHIM
------------------------------
We will use a slightly modified version of the SHIM that can keep the `.reloc` section of the image it loads in memory (ie. `KEEP_DISCARDABLE_RELOC=1`). This is necessary for Xen as Xen looks for the `.reloc` section but by default the SHIM doesn't copy it if it's marked discardable.

The SHIM will be signed with `DB.key` and will automatically launch `xen-signed.efi` provided it is properly signed with `SHIM.key`.

Make sure the SecureBoot keys have been generated already as described above..

For compiling the SHIM it must have access to `SHIM.cer` which will be compiled into the binary. Signing the final binary can be performed on a separate machine that holds the SecureBoot keys.

```
cd uefi-sb/shim
make EFI_PATH=/usr/lib VENDOR_CERT_FILE=../keys/SHIM.cer KEEP_DISCARDABLE_RELOC=1 DEFAULT_LOADER=xen-signed.efi
```

Signing the resulting SHIM is performed with
```
sbsign --key ../keys/DB.key --cert ../keys/DB.crt --output shim-signed.efi shimx64.efi
```

The default loader specified when the SHIM was compiled needs to be signed by the SHIM private key, as we want to prohibit it being executable without the SHIM first being loaded.


## Install SHIM
------------------------------
The SHIM needs to be installed on the Efi System Partition (`ESP`), alongside the default loader it will execute. Assume the partition is mounted at `/boot/efi`:

`/boot/efi/EFI/BOOT/BOOTX64.EFI`.

By using the above path for the SHIM, it will always execute, whether there is a specific boot entry set for it or if the system is being booted from the disk itself.

Adding a boot entry can be performed with:
```
efibootmgr -c -d /dev/sda -p 1 -w -L shim -l \EFI\BOOT\BOOTX64.EFI
```

# 6. Setup Xen
## Compile Xen with required config options
By default the Xen Security Modules (XSM) policy and the Xen command-line arguments are being specified by the bootloader (GRUB). When booted in UEFI mode these options can be specified in the UEFI config file. However, in that case neither would get verified and thus the SecureBoot trust-chain would get broken. Thus it is necessary to compile both into the Xen UEFI binary itself.

The configuration options necessary to activate these features require an environmental flag to be present:

`export XEN_CONFIG_EXPERT=y`

Then, the following options need to be enabled (adjust CMDLINE as appropriate):
```
CONFIG_XSM=y
CONFIG_FLASK=y
CONFIG_XSM_POLICY=y
CONFIG_CMDLINE="console=com1 dom0_mem=min:420M,max:420M,420M com1=115200,8n1,pci mbi-video vga=current flask=enforcing loglvl=debug guest_loglvl=debug ucode=-2"
CONFIG_CMDLINE_OVERRIDE=y
```

A sample configuration file can be found in the git repository at `uefi-sb/xen-4.9-config`.


## Signing Xen with the SHIM key
--------------------------------
To allow the SHIM to boot Xen, sign `xen.efi` as follows:

```sbsign --key SHIM.key --cert SHIM.crt --output xen-signed.efi xen.efi```

Afterwards, copy `xen-signed.efi` into the `ESP` partition next to the SHIM (ie. `/boot/efi/EFI/xen/`). DO NOT create a UEFI boot entry for Xen as it can only be booted through the SHIM.

## The Xen configuration file
-------------------------------
Xen expects a configuration file to be present when booted as a UEFI application. By default it expects to be named the same as the Xen UEFI application with the `cfg` extension. However, when booted through the SHIM, it will need to be named what the SHIM is named with the `cfg` extension. For example, `BOOTX64.cfg`.

The contents of the config file need to be:
```
[global]
default=xen

[xen]
kernel=linux-signed.efi
```

The config file will only specify the name of the dom0 kernel image, which will also need to be signed with the SHIM key.

# 7. dom0 setup
## Compile Linux
-------------------------------
To ensure the the initial ramdisk gets validated during boot it has be compiled into the Linux image itself. This requires first generating the kernel image and the corresponding ramdisk, then re-compiling the kernel image with the ramdisk embedded. The easiest way to do that is by creating the Debian packages for the kernel and actually installing the package to trigger the Debian initramfs hooks.

**Warning: this setup assumes that the target system will have the same system environment as the one being used for building.**


### From scratch
```
wget https://git.kernel.org/torvalds/t/linux-4.14-rc3.tar.gz
tar xvf linux-4.14-rc3.tar.gz
cp /boot/config-4.9.0-3-amd64 .config
make oldconfig # choosing all default options is fine
make -j8 deb-pkg

sudo dpkg -i ../linux-image-4.14.0-rc3_4.14.0-rc3-1_amd64.deb
mkdir initramfs
cd initramfs
zcat /boot/initrd.img-4.14.0-rc3 | cpio -idmv
# make changes if needed, such as adding the udev rule for non-sda named disks
cd ..
sudo apt-get remove linux-image-4.14.0-rc3
```

Ensure config has the following options enabled
```
CONFIG_BLK_DEV_INITRD=y
CONFIG_INITRAMFS_SOURCE="initramfs"
CONFIG_INITRAMFS_ROOT_UID=1000 # <--- make sure it matches current owner of the initramfs folder
CONFIG_INITRAMFS_ROOT_GID=1000 # <--- make sure it matches current owner of the initramfs folder
CONFIG_CMDLINE_BOOL=y
CONFIG_CMDLINE_OVERRIDE=y
CONFIG_CMDLINE="console=hvc0 root=/dev/mapper/xenclient-root ro boot=/dev/mapper/xenclient-boot swiotlb=16384 xen_pciback.passthrough=1 consoleblank=0 video.delay_init=1 vt.global_cursor_default=0 rootfstype=ext3 bootfstype=ext3"
CONFIG_EFI=y
CONFIG_EFI_STUB=y
CONFIG_FB_EFI=y
```

Recompile
```
make -j8 bzImage
```

### From pre-defined config file in git
There is an example config file in the git repository as well that has the options already enabled.

```
git clone https://github.com/tklengyel/xen-uefi
wget https://git.kernel.org/torvalds/t/linux-4.14-rc3.tar.gz
tar xvf linux-4.14-rc3.tar.gz
cp uefi-sb/config-4.14.0 .config
make -j8 deb-pkg
sudo dpkg -i ../linux-image-4.14.0-rc3_4.14.0-rc3-1_amd64.deb
mkdir initramfs
cd initramfs
zcat /boot/initrd.img-4.14.0-rc3 | cpio -idmv
cd ..
sudo apt-get remove linux-image-4.14.0-rc3
make -j8 bzImage
```

The result Linux bzImage of the Linux kernel will be a valid EFI binary. It is also recommended to enable to enable [Linux Kernel Module Signing](https://www.kernel.org/doc/html/v4.10/admin-guide/module-signing.html).

## Sign and install
```sbsign --key SHIM.key --cert SHIM.crt --output linux-signed.efi arch/x86_64/boot/bzImage```

Afterwards, copy `linux-signed.efi` into the `ESP` partition next to the SHIM (ie. `/boot/efi/EFI/xen/`). DO NOT create a UEFI boot entry for Linux as it can only be booted through the SHIM.
