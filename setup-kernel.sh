#!/bin/sh

##
## Build and boot a kernel.org kernel (default: newest 6.12.N) for the
## HarvestContainers experiments, with sched_ext enabled.  Runs on every
## node.  The node reboots once; CloudLab re-runs the startup command on
## boot, setup-driver.sh calls us again, and we finish once `uname -r`
## matches what we installed.
##
## We build from source (make bindeb-pkg) instead of installing the
## kernel.ubuntu.com mainline .debs: their -generic headers package
## depends on a newer glibc than Ubuntu 22.04 has, and we need working
## headers on the target nodes to build the qidlecpu module.
##

set -x

if [ -z "$EUID" ]; then
    EUID=`id -u`
fi

# Grab our libs
. "`dirname $0`/setup-lib.sh"

if [ -f $OURDIR/kernel-done ]; then
    exit 0
fi

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi
if [ -f $LOCALSETTINGS ]; then
    . $LOCALSETTINGS
fi

if [ ! "$HARVESTENABLE" = "1" ]; then
    touch $OURDIR/kernel-done
    exit 0
fi

#
# Second pass (after reboot): check we came up on the new kernel.  Never
# reboot twice; a mismatch here means grub picked the wrong entry.
#
if [ -f $OURDIR/kernel-installed ]; then
    KREL=`cat $OURDIR/kernel-installed`
    if [ "`uname -r`" = "$KREL" ]; then
	echo "Booted harvest kernel $KREL"
	touch $OURDIR/kernel-done
	exit 0
    fi
    echo "ERROR: installed $KREL but booted `uname -r`; check /etc/default/grub.d/99-harvest.cfg"
    exit 1
fi

logtstart "kernel"

#
# Resolve a series (e.g. 6.12) to the newest point release on kernel.org.
#
KMAJOR=`echo $HARVESTKERNEL | cut -d. -f1`
KVER="$HARVESTKERNEL"
if [ `echo $HARVESTKERNEL | awk -F. '{print NF}'` -eq 2 ]; then
    KVER=`wget -qO- https://cdn.kernel.org/pub/linux/kernel/v${KMAJOR}.x/ \
	| sed -n -e "s/^.*linux-\(${HARVESTKERNEL}\.[0-9]*\)\.tar\.xz.*$/\1/p" \
	| sort -t. -k3 -n | tail -1`
    if [ -z "$KVER" ]; then
	echo "ERROR: could not resolve kernel series $HARVESTKERNEL on kernel.org"
	exit 1
    fi
fi
LOCALVER="-harvest"
KREL="${KVER}${LOCALVER}"

do_apt_update
maybe_install_packages build-essential bc bison flex libssl-dev libelf-dev \
    libdw-dev dwarves zstd rsync cpio kmod debhelper dpkg-dev fakeroot \
    python3 git pciutils libpci-dev

# Build on the big LVM volume if setup-disk-space.sh made one.
if [ -d $STORAGEDIR ]; then
    BUILDDIR=$STORAGEDIR/kernel-build
else
    BUILDDIR=/local/kernel-build
fi
$SUDO mkdir -p $BUILDDIR
$SUDO chown $SWAPPER $BUILDDIR
cd $BUILDDIR

if [ ! -d linux-$KVER ]; then
    get_url https://cdn.kernel.org/pub/linux/kernel/v${KMAJOR}.x/linux-${KVER}.tar.xz \
	linux-${KVER}.tar.xz
    if [ ! $? -eq 0 ]; then
	echo "ERROR: could not download linux-${KVER}.tar.xz"
	exit 1
    fi
    tar -xJf linux-${KVER}.tar.xz
fi
cd linux-$KVER

# Start from the running Ubuntu config so all the drivers/netfilter/ipvs
# bits k8s needs stay enabled; drop Canonical's signing certs.
cp /boot/config-`uname -r` .config
scripts/config --set-str SYSTEM_TRUSTED_KEYS "" \
    --set-str SYSTEM_REVOCATION_KEYS "" \
    --set-str LOCALVERSION "$LOCALVER" \
    --disable LOCALVERSION_AUTO
if [ "$HARVESTSCHEDEXT" = "1" ]; then
    scripts/config --enable DEBUG_INFO \
	--enable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT \
	--enable DEBUG_INFO_BTF \
	--enable BPF --enable BPF_SYSCALL --enable BPF_JIT \
	--enable SCHED_CLASS_EXT
fi
# kprobes are how the qidlecpu module finds kallsyms_lookup_name.
scripts/config --enable KPROBES
make olddefconfig
if [ "$HARVESTSCHEDEXT" = "1" ]; then
    grep -q '^CONFIG_SCHED_CLASS_EXT=y' .config \
	|| echo "WARNING: CONFIG_SCHED_CLASS_EXT did not survive olddefconfig"
fi

make -j`nproc` bindeb-pkg
if [ ! $? -eq 0 ]; then
    echo "ERROR: kernel build failed"
    exit 1
fi
cd $BUILDDIR
$SUDO dpkg -i `ls linux-image-${KREL}_*.deb linux-headers-${KREL}_*.deb \
    | grep -v -- -dbg_`
if [ ! $? -eq 0 ]; then
    echo "ERROR: could not install kernel packages"
    exit 1
fi

# perf and cpupower matching the new kernel (Ubuntu's linux-tools
# wrappers only know Ubuntu kernels).  Not fatal.
cd $BUILDDIR/linux-$KVER
make -C tools/perf NO_LIBTRACEEVENT=1 NO_JEVENTS=1 prefix=/usr/local \
    && $SUDO make -C tools/perf NO_LIBTRACEEVENT=1 NO_JEVENTS=1 \
	prefix=/usr/local install \
    || echo "WARNING: perf build failed"
make -C tools/power/cpupower \
    && $SUDO make -C tools/power/cpupower install \
    && echo /usr/lib64 | $SUDO tee /etc/ld.so.conf.d/cpupower.conf \
    && $SUDO ldconfig \
    || echo "WARNING: cpupower build failed"

#
# Boot the new kernel by default; add the HC boot args on workers only.
# A grub.d drop-in is sourced after /etc/default/grub, so it wins.
#
CMDLINE_EXTRA=""
echo ",$HARVESTWORKERS," | grep -q ",$NODEID,"
if [ $? -eq 0 ]; then
    CMDLINE_EXTRA="$HARVESTBOOTARGS"
fi
$SUDO mkdir -p /etc/default/grub.d
cat <<EOF | $SUDO tee /etc/default/grub.d/99-harvest.cfg
GRUB_DEFAULT="Advanced options for Ubuntu>Ubuntu, with Linux $KREL"
GRUB_CMDLINE_LINUX_DEFAULT="\$GRUB_CMDLINE_LINUX_DEFAULT $CMDLINE_EXTRA"
EOF
$SUDO update-grub
if [ ! $? -eq 0 ]; then
    echo "ERROR: update-grub failed"
    exit 1
fi

echo "$KREL" > $OURDIR/kernel-installed
logtend "kernel"

# The startup command's log is truncated when it re-runs after reboot.
cp -p /local/logs/setup.log /local/logs/setup.pre-reboot.log
sync
$SUDO reboot
# Don't let setup-driver.sh continue while we go down.
sleep 600
exit 1
