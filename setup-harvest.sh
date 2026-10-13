#!/bin/sh

##
## Prepare a HarvestContainers worker: packages, the HC repo, /mnt/extra
## (HC scripts write config/logs/results there), irqbalance off, and
## systemd units for the Listener and Balancer.  The units are installed
## but not enabled; the experiment scripts / mitigation controller start
## them after the qidlecpu module is loaded (hc-load-module).
##
## No-op on nodes not listed in HARVESTWORKERS.
##

set -x

if [ -z "$EUID" ]; then
    EUID=`id -u`
fi

# Grab our libs
. "`dirname $0`/setup-lib.sh"

if [ -f $OURDIR/harvest-done ]; then
    exit 0
fi

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi
if [ -f $LOCALSETTINGS ]; then
    . $LOCALSETTINGS
fi

if [ ! "$HARVESTENABLE" = "1" ]; then
    exit 0
fi
echo ",$HARVESTWORKERS," | grep -q ",$NODEID,"
if [ ! $? -eq 0 ]; then
    exit 0
fi

logtstart "harvest"

do_apt_update
maybe_install_packages build-essential g++ git jq cgroup-tools msr-tools \
    python3-setproctitle python3-numpy util-linux

HCDIR=/local/HarvestContainers
if [ ! -d $HCDIR ]; then
    $SUDO mkdir -p $HCDIR
    $SUDO chown $SWAPPER $HCDIR
    git clone $HARVESTREPO $HCDIR
    if [ ! $? -eq 0 ]; then
	echo "ERROR: could not clone $HARVESTREPO"
	exit 1
    fi
fi
# HC's Config/SYSTEM.sh uses ${HOME}/HarvestContainers.
SWAPPERHOME=`getent passwd $SWAPPER | cut -d: -f6`
[ -e $SWAPPERHOME/HarvestContainers ] || ln -s $HCDIR $SWAPPERHOME/HarvestContainers

#
# /mnt/extra on the big LVM volume.
#
if [ -d $STORAGEDIR ]; then
    $SUDO mkdir -p $STORAGEDIR/extra /mnt/extra
    grep -q ' /mnt/extra ' /etc/fstab
    if [ ! $? -eq 0 ]; then
	echo "$STORAGEDIR/extra /mnt/extra none defaults,bind 0 0" \
	    | $SUDO tee -a /etc/fstab
    fi
    mountpoint -q /mnt/extra || $SUDO mount /mnt/extra
else
    $SUDO mkdir -p /mnt/extra
fi
$SUDO mkdir -p /mnt/extra/config /mnt/extra/logs /mnt/extra/results \
    /mnt/extra/logs/hc
$SUDO chown -R $SWAPPER /mnt/extra

# HC pins IRQs itself (or not at all); irqbalance would move them back.
$SUDO systemctl disable --now irqbalance || true

#
# Shared HC settings.  CPU ids assume socket 1 = CPUs 16-31 with SMT off;
# check `lscpu -e` on the node and edit before starting anything.
#
if [ ! -f /etc/default/hc-harvest ]; then
    cat <<'EOF' | $SUDO tee /etc/default/hc-harvest
# HarvestContainers host settings (read by hc-load-module and the
# hc-listener / hc-balancer units).  Edit after checking `lscpu -e`.
HC_DIR=/local/HarvestContainers
HC_BIN=/local/HarvestContainers/TestFramework/bin
HC_LOGDIR=/mnt/extra/logs/hc
# Primary (victim) cores the Monitor watches.
HC_CPULIST=18,19,20
# Cores dedicated to the Secondary (aggressors).
HC_SECONDARY_CPULIST=21,22,23,24
HC_TARGET_IDLE_CORES=1
HC_MIN_SECONDARY_CORES=0
HC_MONITOR_CPU=31
HC_BALANCER_CPU=30
HC_LISTENER_CPU=29
EOF
fi

cat <<'EOF' | $SUDO tee /usr/local/sbin/hc-load-module
#!/bin/sh
# Load qidlecpu.ko (built by TestFramework/Experiments/setup-bins.sh),
# point it at HC_CPULIST, bind the Monitor kthread, and start polling.
set -e
. /etc/default/hc-harvest
if ! grep -q '^qidlecpu ' /proc/modules; then
    insmod $HC_BIN/qidlecpu.ko
fi
echo $HC_CPULIST > /proc/idlecpu/cpulist
echo $HC_MONITOR_CPU > /proc/idlecpu/bindcpu
echo 1 > /proc/idlecpu/control
EOF
$SUDO chmod 755 /usr/local/sbin/hc-load-module

# Both binaries clean up (and the Balancer writes its logs) on SIGUSR1.
cat <<'EOF' | $SUDO tee /etc/systemd/system/hc-listener.service
[Unit]
Description=HarvestContainers Listener (TCP 10101)
After=network.target

[Service]
Type=simple
EnvironmentFile=/etc/default/hc-harvest
WorkingDirectory=/mnt/extra/logs/hc
ExecStartPre=/usr/local/sbin/hc-load-module
ExecStart=/bin/sh -c 'exec taskset -a -c $HC_LISTENER_CPU $HC_BIN/listener'
KillSignal=SIGUSR1
TimeoutStopSec=10
Restart=on-failure
StandardOutput=append:/mnt/extra/logs/hc/listener.log
StandardError=append:/mnt/extra/logs/hc/listener.log

[Install]
WantedBy=multi-user.target
EOF

cat <<'EOF' | $SUDO tee /etc/systemd/system/hc-balancer.service
[Unit]
Description=HarvestContainers Balancer
After=hc-listener.service
Requires=hc-listener.service

[Service]
Type=simple
EnvironmentFile=/etc/default/hc-harvest
WorkingDirectory=/mnt/extra/logs/hc
ExecStart=/bin/sh -c 'exec taskset -a -c $HC_BALANCER_CPU $HC_BIN/balancer 0 $HC_TARGET_IDLE_CORES $HC_MIN_SECONDARY_CORES $HC_CPULIST $HC_SECONDARY_CPULIST'
KillSignal=SIGUSR1
TimeoutStopSec=30
Restart=no
StandardOutput=append:/mnt/extra/logs/hc/balancer.out
StandardError=append:/mnt/extra/logs/hc/balancer.out

[Install]
WantedBy=multi-user.target
EOF
service_init_reload

#
# Try to build the HC binaries now; not fatal, since the module may need
# porting work for this kernel (see Docs/07_icelake_hc_actuator_plan.md).
#
if [ -x $HCDIR/TestFramework/Experiments/setup-bins.sh ]; then
    (cd $HCDIR/TestFramework/Experiments && ./setup-bins.sh) \
	|| echo "WARNING: HC setup-bins.sh failed; build by hand"
fi

logtend "harvest"
touch $OURDIR/harvest-done
exit 0
