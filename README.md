This repository contains tools and instructions for installing Xen and dom0 with UEFI/SecureBoot such that all critical components of Xen and the dom0 kernel get SecureBoot verified and measured into the TPM.

# Table of Contents
1. [Generating SecureBoot signing keys](#section-1)
2. [Placing the system into SecureBoot SetupMode](#section-2)
3. [Installing SecureBoot Keys](#section-3)
4. [Signing binaries with the SecureBoot keys](#section-4)
5. [Shim setup](#section-5)
6. [Xen setup](#section-6)
7. [dom0 setup](#section-7)

# 1. Generating SecureBoot signing keys <a name="section-1"></a>

## Precautions to be taken
------------------------------
Private keys generated for SecureBoot need to be protected at all times. For this purpose we recommend utilizing a locked-down machine (potentially air-gapped) after the required tools have been loaded on to it. Dummy/test keys can be used during regular building to sign binaries, where these signatures can be overwritten later on the secure machine.

## Generating SecureBoot keys on Debian (stretch)
------------------------------
```
apt-get install make gcc libssl1.0-dev git gnu-efi sbsigntool libfile-slurp-perl
git clone https://github.com/tklengyel/xen-uefi --recursive
cd xen-uefi
./mkkeys.sh
```

The generated keys will be located in the `keys` folder.

# 2. Placing the system into SecureBoot SetupMode <a name="section-2"></a> 
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
cd xen-uefi/efitools
make KeyTool.efi
```

Start `KeyTool` from a USB device or from the `ESP` partition.
1. Edit Keys
2. The Platform Key (PK)
3. Select the GUID
4. Delete with .auth file
5. Locate the noPK.auth file on the USB device or on the ESP partition

The system should now be in `SetupMode` again. 

# 3. Installing SecureBoot keys <a name="section-3"></a> 
## Installing SecureBoot keys with LockDown.efi
------------------------------
LockDown.efi is a minimal EFI application that contains the SecureBoot certificates embedded in the application itself. When executed, it will automatically load the keys into their respective SecureBoot key-slot.

By default LockDown.efi does not wait after the keys have been successfully loaded or in case an error occurred. There is a patch in the git repository that adds a bit of wait time so messages can be read of the screen when using the tool. To apply the patch:

```
cd xen-uefi/efitools
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
cd xen-uefi/efitools
make KeyTool.efi
```

Make sure to load the keys in the following order (loading PK will take the system out of SecureBoot Setup mode!):
1.  DB
2.  KEK
3.  PK


# 4. Signing binaries with the SecureBoot keys <a name="section-4"></a> 
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


# 5. Shim setup <a name="section-5"></a> 
## Compile and sign SHIM
------------------------------
We will use a slightly modified version of the SHIM that can keep the `.reloc` section of the image it loads in memory (ie. `KEEP_DISCARDABLE_RELOC=1`). This is necessary for Xen as Xen looks for the `.reloc` section but by default the SHIM doesn't copy it if it's marked discardable. Also, there is a new shim ABI that allows us to measure arbitrary buffers into the TPM via the shim lock protocol.

The SHIM will be signed with `DB.key` and will automatically launch `xen-signed.efi` provided it is properly signed with `SHIM.key`.

Make sure the SecureBoot keys have been generated already as described above..

For compiling the SHIM it must have access to `SHIM.cer` which will be compiled into the binary. Signing the final binary can be performed on a separate machine that holds the SecureBoot keys.

```
cd xen-uefi/shim
make ARCH=x86_64 EFI_INCLUDE=/usr/include/efi EFI_PATH=/usr/lib VENDOR_CERT_FILE=../keys/SHIM.cer KEEP_DISCARDABLE_RELOC=1 DEFAULT_LOADER=xen-signed.efi
```

Signing the resulting SHIM is performed with
```
sbsign --key ../keys/DB.key --cert ../keys/DB.crt --output shim-signed.efi shimx64.efi
```

The default loader specified when the SHIM was compiled needs to be signed by the SHIM private key, as we want to prohibit it being executable without the SHIM first being loaded.


## Install SHIM
------------------------------
The SHIM needs to be installed on the Efi System Partition (`ESP`), alongside the default loader it will execute. Assume the partition is mounted at `/boot/efi`:

`/boot/efi/EFI/xen/shim.efi`.

Adding a boot entry can be performed with:
```
efibootmgr -c -d /dev/sda -p 1 -w -L "Xen" -l \EFI\xen\shim.efi
```

# 6. Setup Xen <a name="section-6"></a> 
## Compile Xen with required patches

There are two patches for Xen that need to be applied. The first patch adds support to Xen to properly understand EFI_LOAD_OPTIONs. This is necessary only if there are multiple sections in the Xen efi config file. The second patch adds support to Xen to take advantage of the new shim measure ABI, which will be used to measure into the TPM the Xen efi config file, initrd and the XSM policy. These patches apply to Xen 4.10.0 but could be backported as necessary.

```
patch -p1 < 0001-xen-Add-EFI_LOAD_OPTION-support.patch
patch -p1 < 0002-xen-shim-lock-measure.patch
```

## Signing Xen with the SHIM key
--------------------------------
To allow the SHIM to boot Xen, sign `xen.efi` as follows:

```sbsign --key SHIM.key --cert SHIM.crt --output xen-signed.efi xen.efi```

Afterwards, copy `xen-signed.efi` into the `ESP` partition next to the SHIM (ie. `/boot/efi/EFI/xen/`). DO NOT create a UEFI boot entry for Xen as it can only be booted through the SHIM.

## The Xen configuration file
-------------------------------
Xen expects a configuration file to be present when booted as a UEFI application. By default it expects to be named the same as the Xen UEFI application with the `cfg` extension. However, when booted through the SHIM, it will need to be named what the SHIM is named with the `cfg` extension. For example, `BOOTX64.cfg`.

The Xen configuration file can specify multiple sections, so that it is possible to pre-define different boot options for the Xen and the dom0 kernel.

```
[global]
default=normal

[normal]
options=console=vga
kernel=vmlinuz-4.8.0-41-generic-signed root=/dev/sda2 ro quiet console=hvc0
ramdisk=initrd.img-4.8.0-41-generic

[debug]
options=console=vga,com1 com1=115200,8n1,pci iommu=verbose loglvl=all guest_loglvl=all
kernel=vmlinuz-4.8.0-41-generic-signed root=/dev/sda2 ro quiet console=hvc0
ramdisk=initrd.img-4.8.0-41-generic
```

To allow choosing between these sections during boot, specify the section name as the EFI_LOAD_OPTION's option field:
```
efibootmgr -c -d /dev/sda -p 1 -w -L "Xen (normal)" -l \EFI\xen\shim.efi -u "normal"
efibootmgr -c -d /dev/sda -p 1 -w -L "Xen (debug)" -l \EFI\xen\shim.efi -u "debug"
```
# 7. dom0 setup <a name="section-7"></a> 
## Sign and install
Most kernels shipping with Debian or Ubuntu will "just work", but to ensure, check that the following options are enabled in the kernel config file:
```
CONFIG_EFI=y
CONFIG_EFI_STUB=y
CONFIG_FB_EFI=y
```

To sign the the kernel:

```sbsign --key SHIM.key --cert SHIM.crt --output vmlinuz-4.8.0-41-generic-signed vmlinuz-4.8.0-41-generic```

Afterwards, copy the signed kernel and its initrd  into the `ESP` partition next to the SHIM (ie. `/boot/efi/EFI/xen/`).
