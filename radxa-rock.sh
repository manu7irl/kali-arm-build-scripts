#!/bin/bash

if [[ $# -eq 0 ]] ; then
    echo "Please pass version number, e.g. $0 1.0.1"
    exit 0
fi

basedir=`pwd`/radxa_rock-$1

#Based kali-arm-build-scripts/mini-x.sh
echo "Download the kali-arm-build-scripts"
git clone https://github.com/offensive-security/kali-arm-build-scripts.git
# Package installations for various sections.
# This will build a minimal XFCE Kali system with the top 10 tools.
# This is the section to edit if you would like to add more packages.
# See http://www.kali.org/new/kali-linux-metapackages/ for meta packages you can
# use. You can also install packages, using just the package name, but keep in
# mind that not all packages work on ARM! If you specify one of those, the
# script will throw an error, but will still continue on, and create an unusable
# image, keep that in mind.

arm="abootimg cgpt fake-hwclock ntpdate vboot-utils vboot-kernel-utils uboot-mkimage"
base="kali-menu kali-defaults initramfs-tools"
desktop="xfce4 network-manager network-manager-gnome xserver-xorg-video-fbdev"
tools="passing-the-hash winexe aircrack-ng hydra john sqlmap wireshark libnfc-bin mfoc"
services="openssh-server apache2"
extras="iceweasel wpasupplicant"

export packages="${arm} ${base} ${desktop} ${tools} ${services} ${extras}"
export architecture="armhf"

# Set this to use an http proxy, like apt-cacher-ng, and uncomment further down
# to unset it.
#export http_proxy="http://localhost:3142/"

mkdir -p ${basedir}
cd ${basedir}

# create the rootfs - not much to modify here, except maybe the hostname
debootstrap --foreign --arch $architecture kali kali-$architecture http://http.kali.org/kali

cp /usr/bin/qemu-arm-static kali-$architecture/usr/bin/

LANG=C chroot kali-$architecture /debootstrap/debootstrap --second-stage
cat << EOF > kali-$architecture/etc/apt/sources.list
deb http://http.kali.org/kali kali main contrib non-free
deb http://security.kali.org/kali-security kali/updates main contrib non-free
EOF

echo "kali" > kali-$architecture/etc/hostname

cat << EOF > kali-$architecture/etc/hosts
127.0.0.1       kali    localhost
::1             localhost ip6-localhost ip6-loopback
fe00::0         ip6-localnet
ff00::0         ip6-mcastprefix
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF

cat << EOF > kali-$architecture/etc/network/interfaces
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

cat << EOF > kali-$architecture/etc/resolv.conf
nameserver 8.8.8.8
EOF

export MALLOC_CHECK_=0 # workaround for LP: #520465
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

modprobe binfmt_misc
mount -t proc proc kali-$architecture/proc
mount -o bind /dev/ kali-$architecture/dev/
mount -o bind /dev/pts kali-$architecture/dev/pts

cat << EOF > kali-$architecture/debconf.set
console-common console-data/keymap/policy select Select keymap from full list
console-common console-data/keymap/full select en-latin1-nodeadkeys
EOF

cat << EOF > kali-$architecture/third-stage
#!/bin/bash
dpkg-divert --add --local --divert /usr/sbin/invoke-rc.d.chroot --rename /usr/sbin/invoke-rc.d
cp /bin/true /usr/sbin/invoke-rc.d
echo -e "#!/bin/sh\nexit 101" > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d

apt-get update
apt-get -y install locales-all

debconf-set-selections /debconf.set
rm -f /debconf.set
apt-get update
apt-get -y install git-core binutils ca-certificates initramfs-tools uboot-mkimage
apt-get -y install locales console-common less nano git
echo "root:toor" | chpasswd
sed -i -e 's/KERNEL\!=\"eth\*|/KERNEL\!=\"/' /lib/udev/rules.d/75-persistent-net-generator.rules
rm -f /etc/udev/rules.d/70-persistent-net.rules
apt-get --yes --force-yes install $packages

rm -f /usr/sbin/policy-rc.d
rm -f /usr/sbin/invoke-rc.d
dpkg-divert --remove --rename /usr/sbin/invoke-rc.d

rm -f /third-stage
EOF

chmod +x kali-$architecture/third-stage
LANG=C chroot kali-$architecture /third-stage

# mtd-by-name link the mtdblock to name
cat << EOF > kali-$architecture/usr/local/bin/mtd-by-name.sh
#!/bin/sh -e
# radxa.com, thanks to naobsd
rm -rf /dev/block/mtd/by-name/
mkdir -p /dev/block/mtd/by-name
for i in `ls -d /sys/class/mtd/mtd*[0-9]`; do
name=`cat $i/name`
tmp="`echo $i | sed -e 's/mtd/mtdblock/g'`"
dev="`echo $tmp |sed -e 's/\/sys\/class\/mtdblock/\/dev/g'`"
ln -s $dev /dev/block/mtd/by-name/$name
done
chmod +x kali-$architecture/usr/local/bin/mtd-by-name.sh
echo -e "/usr/local/bin/mtd-by-name.sh" > /etc/rc.local
EOF

cat << EOF > kali-$architecture/cleanup
#!/bin/bash
rm -rf /root/.bash_history
apt-get update
apt-get clean
rm -f /0
rm -f /hs_err*
rm -f cleanup
rm -f /usr/bin/qemu*
EOF

chmod +x kali-$architecture/cleanup
LANG=C chroot kali-$architecture /cleanup

#umount kali-$architecture/proc/sys/fs/binfmt_misc
umount kali-$architecture/dev/pts
umount kali-$architecture/dev/
umount kali-$architecture/proc

# Create the disk and partition it
echo "Creating rock_rootfs-$1.img"
cd ${basedir}
dd if=/dev/zero of=rock_rootfs-$1.img bs=1M count=7168

#kernel use the label linuxroot to mount the rootfs as /
echo "Formatting rock_rootfs-$1.img to ext4"
mkfs.ext4 -F -L linuxroot rock_rootfs-$1.img
rootfs="rock_rootfs-$1.img"

# Create the dirs for the partitions and mount them
echo "Mounting rootfs"
rootimg="${basedir}/root"
mkdir -p ${rootimg}
mount -o loop ${rootfs} ${rootimg}

echo "Rsyncing rootfs into image file"
rsync -HPavz -q ${basedir}/kali-$architecture/ ${rootimg}

# Uncomment this if you use apt-cacher-ng otherwise git clones will fail.
#unset http_proxy

# Kernel section. If you want to use a custom kernel, or configuration, replace
# them in this section.
echo "Making kernel"
cd ${basedir}
git clone https://github.com/offensive-security/gcc-arm-linux-gnueabihf-4.7
export PATH=${PATH}:${basedir}/gcc-arm-linux-gnueabihf-4.7/bin
git clone https://github.com/offensive-security/kali-arm-build-scripts
cd ${basedir}/kali-arm-build-scripts
./build-deps.sh
cd ${basedir}
export ARCH=arm
export CROSS_COMPILE=arm-linux-gnueabihf-
git clone -b wip/rockchip-3.0-radxa-rock https://github.com/linux-rockchip/rockchip-3.0.git
kerneldir=${basedir}/rockchip-3.0
cd ${kerneldir}
echo "Patching kernel"
wget http://patches.aircrack-ng.org/mac80211.compat08082009.wl_frag+ack_v1.patch -O mac80211.patch
patch -p1 --no-backup-if-mismatch < mac80211.patch
touch .scmversion
cd ${kerneldir}
echo "Building kernel"
# Missing rk3188_radxa_rock_defconfig file in rockchip-3.0 dir
make rk3188_radxa_rock_defconfig
make -j $(grep -c processor /proc/cpuinfo) Image modules
mkdir modules
export INSTALL_MOD_PATH=./modules
make modules
make modules_install
mkdir -p ${rootimg}/lib/modules
mkdir -p ${rootimg}/lib/firmware
cp -r ${kerneldir}/modules/lib/modules/3.0.36+ ${rootimg}/lib/modules
cp -r ${kerneldir}/firmware/* ${rootimg}/lib/firmware/

# Create ramdisk
echo "Create ramdisk"
cd ${kerneldir}/arch/arm/boot/
git clone --depth 1 https://github.com/radxa/initrd.git
make -C initrd

# Create boot.img
echo "Generating boot.img"
wget http://dl.radxa.com/rock/tools/linux/mkbootimg
apt-get -y install lib32stdc++6
chmod +x mkbootimg
./mkbootimg --kernel ${kerneldir}/arch/arm/boot/Image --ramdisk initrd.img -o boot.img
cp boot.img ${basedir}


# Unmount partitions
umount ${rootimg}


# Clean up all the temporary build stuff and remove the directories.
# Comment this out to keep things around if you want to see what may have gone
# wrong.
#echo "Cleaning up temporary build system"
#rm -rf ${basedir}/** ${basedir}/patches ${basedir}/kernel ${basedir}/root ${basedir}/kali-$architecture

# If you're building an image for yourself, comment all of this out, as you
# don't need the sha1sum or to compress the image, since you will be testing it
# soon.
echo "Generating sha1sum for rock_rootfs-$1.img"
sha1sum rock_rootfs-$1.img > ${basedir}/rock_rootfs-$1.img.sha1sum
# Don't pixz on 32bit, there isn't enough memory to compress the images.
MACHINE_TYPE=`uname -m`
if [ ${MACHINE_TYPE} == 'x86_64' ]; then
echo "Compressing kali-$1-radxa-rock.img"
pixz ${basedir}/rock_rootfs-$1.img ${basedir}/rock_rootfs-$1.img.xz
#rm ${basedir}/rock_rootfs-$1.img
echo "Generating sha1sum for kali-$1-radxa-rock.img.xz"
sha1sum rock_rootfs-$1.img.xz > ${basedir}/rock_rootfs-$1.img.xz.sha1sum
cd ${basedir}
git clone https://github.com/linuxerwang/rkflashkit
cd rkflashkit
./waf debian
apt-get -y install python-gtk2
dpkg -i rkflashkit_0.1.1_all.deb
rkflashkit
fi
