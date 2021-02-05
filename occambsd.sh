#!/bin/sh
#-
# SPDX-License-Identifier: BSD-2-Clause-FreeBSD
#
# Copyright 2021 Michael Dexter
# All rights reserved
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted providing that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#	notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#	notice, this list of conditions and the following disclaimer in the
#	documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
# IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
# DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
# STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
# IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

# Version 13.0-ALPHA1

# occambsd: An application of Occam's razor to FreeBSD
# a.k.a. "super svelte stripped down FreeBSD"

# This will create a kernel directory, a disk image with the kernel included,
# and a jail root directory for use with bhyve and jail(8)

# The separate kernel directory is VERY useful for testing kernel changes
# while waiting for institutionalized VirtFS support

set -eu

# Functions

# A usefull function (from: http://code.google.com/p/sh-die/)
die() { echo -n "EXIT: " >&2; echo "$@" >&2; exit 1; }

##### Check if previous NanoBSD make stop correctly by unoumt all tmp mount
# exit with 0 if no problem detected
# exit with 1 if problem detected, but clean it
# exit with 2 if problem detected and can't clean it
check_clean() {
    # Check all working dir allready mounted and unmount them
    # Patch from Warner Losh (imp@)
    __a=`mount | grep $1 | awk '{print length($3), $3;}' | sort -rn \
        | awk '{$1=""; print;}'`
    if [ -n "$__a" ]; then
        echo "unmounting $__a"
        umount $__a
    fi
}

# Variables

playground="/tmp/occambsd"		# This will be mounted tmpfs
imagesize="4G"				# More than enough room
md_id="md42"				# Ask Douglas Adams for an explanation
buildjobs="$(sysctl -n hw.ncpu)"

if [ $(id -u) -ne 0 ]; then
	die "Need to be root"
fi

[ -f /usr/src/sys/amd64/conf/GENERIC ] || die "Sources do not appear to be installed"

# Cleanup - tmpfs mounts are not always dected by mount | grep tmpfs ...
#	They may also be mounted multiple times atop one another and
#	md devices may be attached multiple times. Proper cleanup would be nice

mdconfig -l | grep -q $md_id && mdconfig -du "$md_id"
check_clean $playground
#umount "$playground/mnt"
#umount "$playground"
#check_clean "/usr/obj"

mkdir -p "$playground"

echo Mounting $playground tmpfs
mount -t tmpfs tmpfs "$playground" ||  die "tmpfs mount failed"

echo Making directories in $playground
mkdir -p "$playground/root/boot"
mkdir -p "$playground/root/etc"
mkdir -p "$playground/jail"
mkdir -p "$playground/mnt"
mkdir -p "$playground/obj"

echo Generating $playground/src.conf
sh /usr/src/tools/tools/build_option_survey/listallopts.sh | grep -v WITH_ | sed 's/$/=YES/' | \
	grep -v WITHOUT_AUTO_OBJ | \
	grep -v WITHOUT_UNIFIED_OBJDIR | \
	grep -v WITHOUT_INSTALLLIB | \
	grep -v WITHOUT_LIBPTHREAD | \
	grep -v WITHOUT_LIBTHR | \
	grep -v WITHOUT_LIBCPLUSPLUS | \
	grep -v WITHOUT_CRYPT | \
	grep -v WITHOUT_DYNAMICROOT | \
	grep -v WITHOUT_BOOT | \
	grep -v WITHOUT_LOADER_LUA | \
	grep -v WITHOUT_LOCALES | \
	grep -v WITHOUT_ZONEINFO | \
	grep -v WITHOUT_VI \
	> $playground/src.conf

# WITHOUT_AUTO_OBJ and WITHOUT_UNIFIED_OBJDIR warn that they go in src-env.conf
# <broken build options>
# WITHOUT_LOADER_LUA is required for the lua boot code
# WITHOUT_BOOT is needed to install the LUA loader
# WITHOUT_LOCALES is necessary for a console
# WITHOUT_ZONEINFO is necessary for the timzone setting on VM image with a userland
# WITHOUT_VI could come in handy

# XXX useless ?
[ -f $playground/src.conf ] || die "$playground/src.conf did not generate"

cat $playground/src.conf

echo Removing OCCAM KERNCONF if present
[ -f /usr/src/sys/amd64/conf/OCCAM ] && rm /usr/src/sys/amd64/conf/OCCAM

echo Creating new OCCAM KERNCONF
cat << HERE > /usr/src/sys/amd64/conf/OCCAM

cpu		HAMMER
ident		OCCAM

# Sync with the devices below? Have not needed virtio_blk etc.
makeoptions	MODULES_OVERRIDE="virtio"

# Pick a scheduler - Required
options 	SCHED_ULE		# ULE scheduler
#options	SCHED_4BSD

device		pci
# The tribal elders say that the loopback device was not always required
device		loop			# Network loopback
# The modern kernel will not build without ethernet
device		ether			# Ethernet support
# The kernel should build at this point

# Do boot it in bhyve, you will want to see serial output
device          uart                    # Generic UART driver

#panic: running without device atpic requires a local APIC
device          atpic           # 8259A compatability

# To get past mountroot
device          ahci                    # AHCI-compatible SATA controllers
device          scbus                   # SCSI bus (required for ATA/SCSI)

# Throws an error but works - Investigate
options         GEOM_PART_GPT           # GUID Partition Tables.

#Mounting from ufs:/dev/vtbd0p3 failed with error 2: unknown file system.
options 	FFS			# Berkeley Fast Filesystem

# Appears to work with only "virtio" synchronized above with MODULES_OVERRIDE
# Investigate
device          virtio                  # Generic VirtIO bus (required)
device          virtio_pci              # VirtIO PCI device
device          virtio_blk              # VirtIO Block device

# Apparently not needed if virtio device and MODULE_OVERRIDE are specified
#device          vtnet                   # VirtIO Ethernet device
#device          virtio_scsi             # VirtIO SCSI device
#device          virtio_balloon          # VirtIO Memory Balloon device

# Luxurious options - sync with build options
#options         SMP                     # Symmetric MultiProcessor Kernel
#options         INET                    # InterNETworking
#device          iflib
#device          em                      # Intel PRO/1000 Gigabit Ethernet Family
HERE

echo The resulting OCCAM KERNCONF is
cat /usr/src/sys/amd64/conf/OCCAM

echo Entering the /usr/src directory
cd /usr/src/

echo Building world with
CMD="make -j$buildjobs SRCCONF=$playground/src.conf MAKEOBJDIRPREFIX=$playground/obj buildworld"
echo $CMD
\time -h $CMD || die "buildworld failed"

echo Building the kernel with
CMD="make -j$buildjobs SRCCONF=$playground/src.conf MAKEOBJDIRPREFIX=$playground/obj buildkernel KERNCONF=OCCAM"
echo $CMD
\time -h $CMD || die "buildkernel failed"

echo Seeing how big the resulting kernel is
ls -lh $playground/obj/usr/src/sys/OCCAM/kernel

echo Truncating VM image - consider -t malloc and tmpfs
truncate -s "$imagesize" "$playground/occambsd.raw" || die "image truncation failed"

[ -f $playground/occambsd.raw ] || die "$playground/occambsd.raw did not create"

echo Attaching VM image
mdconfig -a -u "$md_id" -f "$playground/occambsd.raw"

[ -e /dev/$md_id ] || die "$md_id did not attach"

echo Partitioning and formating $md_id
gpart create -s gpt "$md_id"
gpart add -t freebsd-boot -l bootfs -b 128 -s 128K "$md_id"
gpart bootcode -b /boot/pmbr -p /boot/gptboot -i 1 "$md_id"
gpart add -t freebsd-swap -s 1G "$md_id"
gpart add -t freebsd-ufs "$md_id"

echo The occambsd.raw partitioning is:
gpart show "$md_id"
newfs -U /dev/${md_id}p3 || die "newfs failed"

echo Mounting ${md_id}p3 with mount /dev/${md_id}p3 $playground/mnt
mount /dev/${md_id}p3 $playground/mnt || die "mount failed"

echo Installing world to $playground/mnt
\time -h make installworld SRCCONF=$playground/src.conf MAKEOBJDIRPREFIX=$playground/obj DESTDIR=$playground/mnt

# Alternative: use a known-good full userland
#cat /usr/freebsd-dist/base.txz | tar -xf - -C $playground/mnt

echo Installing world to $playground/jail
\time -h make installworld SRCCONF=$playground/src.conf MAKEOBJDIRPREFIX=$playground/obj DESTDIR=$playground/jail

# KERNEL

echo Installing the kernel to $playground/mnt
\time -h make installkernel SRCCONF=$playground/src.conf MAKEOBJDIRPREFIX=$playground/obj KERNCONF=OCCAM DESTDIR=$playground/mnt/

echo Installing the kernel to $playground/root/
\time -h make installkernel SRCCONF=$playground/src.conf MAKEOBJDIRPREFIX=$playground/obj KERNCONF=OCCAM DESTDIR=$playground/root/

echo Seeing how big the resulting installed kernel is
ls -lh $playground/mnt/boot/kernel/kernel

# DISTRIBUTION

echo Installing distribution to $playground/mnt
\time -h make distribution SRCCONF=$playground/src.conf MAKEOBJDIRPREFIX=$playground/obj DESTDIR=$playground/mnt

echo Installing distribution to $playground/root
\time -h make distribution SRCCONF=$playground/src.conf MAKEOBJDIRPREFIX=$playground/obj DESTDIR=$playground/root

echo Installing distribution to $playground/jail
\time -h make distribution SRCCONF=$playground/src.conf MAKEOBJDIRPREFIX=$playground/obj DESTDIR=$playground/jail

# Copying boot components from the mounted device to the root kernel device
cp -rp $playground/mnt/boot/defaults $playground/root/boot/
cp -rp $playground/mnt/boot/lua $playground/root/boot/
#cp -p $playground/mnt/boot/device.hints $playground/root/boot/

echo DEBUG directory listings
echo ls $playground/mnt
ls $playground/mnt
echo ls $playground/mnt/boot
ls $playground/mnt/boot
echo ls $playground/mnt/boot/lua
ls $playground/mnt/boot/lua
echo
echo ls $playground/root
ls $playground/root
echo ls $playground/root/boot
ls $playground/root/boot
echo ls $playground/root/boot/lua
ls $playground/root/boot/lua
echo

echo
echo Generating rc.conf

tee -a $playground/mnt/etc/rc.conf <<EOF
hostname="occambsd"
ifconfig_DEFAULT="DHCP inet6 accept_rtadv"
growfs_enable=YES
EOF
echo
tee -a $playground/root/etc/rc.conf <<EOF
hostname="occambsd"
ifconfig_DEFAULT="DHCP inet6 accept_rtadv"
growfs_enable=YES
EOF

echo
echo Generating fstab
echo "/dev/vtbd0p3   /       ufs     rw,noatime      1       1" > "$playground/mnt/etc/fstab"
echo "/dev/vtbd0p2   none    swap    sw      1       1" >> "$playground/mnt/etc/fstab"
cat "$playground/mnt/etc/fstab" || die "First fstab generation failed"
echo
echo "/dev/vtbd0p3   /       ufs     rw,noatime      1       1" > "$playground/root/etc/fstab"
echo "/dev/vtbd0p2   none    swap    sw      1       1" >> "$playground/root/etc/fstab"
cat "$playground/root/etc/fstab" || die "Second fstab generation failed"

touch "$playground/mnt/firstboot"
touch "$playground/root/firstboot"

echo
echo Generating loader.conf
tee -a $playground/mnt/boot/loader.conf <<EOF
kern.geom.label.disk_ident.enable="0"
kern.geom.label.gptid.enable="0"
autoboot_delay="5"
bootverbose="1"
EOF

cat $playground/mnt/boot/loader.conf || die "First loader.conf generation failed"

tee -a $playground/root/boot/loader.conf <<EOF
kern.geom.label.disk_ident.enable="0"
kern.geom.label.gptid.enable="0"
autoboot_delay="5"
bootverbose="1"
EOF

cat $playground/root/boot/loader.conf || die "Second loader.conf generation failed"

# tzsetup will fail on separated kernel/userland - point at userland somehow
# Could not open /mnt/usr/share/zoneinfo/UTC: No such file or directory

echo
echo Setting the timezone
tzsetup -s -C $playground/mnt UTC
#tzsetup -s -C $playground/root UTC
tzsetup -s -C $playground/jail UTC

echo Go inspect it! Cleaning up from here...
echo Press the elusive ANY key to continue
read anykey

df -h

echo Unmounting $playground/mnt
umount $playground/mnt

echo Destroying $md_id
mdconfig -du $md_id
mdconfig -lv

echo
echo The resulting disk image is $playground/occambsd.raw
echo
echo Note these setup and tear-down scripts:
echo

echo kldload vmm > $playground/load-vmm-module.sh
echo $playground/load-vmm-module.sh
echo bhyveload -h $playground/root/ -m 1024 occambsd \
	> $playground/load-from-directory.sh
echo $playground/load-from-directory.sh
echo bhyveload -d $playground/occambsd.raw -m 1024 occambsd \
	> $playground/load-from-disk-image.sh
echo $playground/load-from-disk-image.sh
echo bhyve -m 1024 -H -A -s 0,hostbridge -s 2,virtio-blk,$playground/occambsd.raw -s 31,lpc -l com1,stdio occambsd \
	> $playground/boot-occam-vm.sh
echo $playground/boot-occam-vm.sh
echo bhyvectl --destroy --vm=occambsd \
	> $playground/destroy-occam-vm.sh
echo $playground/destroy-occam-vm.sh
echo
exit 0
