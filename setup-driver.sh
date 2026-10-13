#!/bin/bash

set -x

# Preserve legacy main logfile location
[ -e /local/setup/setup-driver.log ] || ln -s /local/logs/setup.log /local/setup/setup-driver.log

# setup-kernel.sh reboots the node once (HarvestContainers kernel); on the
# re-run after boot, every script skips itself via its $OURDIR/*-done marker.
ALLNODESCRIPTS="setup-ssh.sh setup-disk-space.sh setup-kernel.sh"
HEADNODESCRIPTS="setup-nfs-server.sh setup-nginx.sh setup-ssl.sh setup-kernel-wait.sh setup-kubespray.sh setup-kubernetes-extra.sh setup-dsb.sh setup-harvest.sh setup-end.sh"
WORKERNODESCRIPTS="setup-nfs-client.sh setup-harvest.sh"

export SRC=`dirname $0`
cd $SRC
. $SRC/setup-lib.sh

chmod +x $SRC/setup-dsb.sh $SRC/setup-kernel.sh $SRC/setup-kernel-wait.sh $SRC/setup-harvest.sh

# Don't run setup-driver.sh twice
if [ -f $OURDIR/setup-driver-done ]; then
    echo "setup-driver already ran; not running again"
    exit 0
fi
for script in $ALLNODESCRIPTS ; do
    cd $SRC
    $SRC/$script | tee - /local/logs/${script}.log 2>&1
    if [ ! $PIPESTATUS -eq 0 ]; then
	echo "ERROR: ${script} failed; aborting driver!"
	exit 1
    fi
done
if [ "$HOSTNAME" = "node-0" ]; then
    for script in $HEADNODESCRIPTS ; do
	cd $SRC
	$SRC/$script | tee - /local/logs/${script}.log 2>&1
	if [ ! $PIPESTATUS -eq 0 ]; then
	    echo "ERROR: ${script} failed; aborting driver!"
	    exit 1
	fi
    done
else
    for script in $WORKERNODESCRIPTS ; do
	cd $SRC
	$SRC/$script | tee - /local/logs/${script}.log 2>&1
	if [ ! $PIPESTATUS -eq 0 ]; then
	    echo "ERROR: ${script} failed; aborting driver!"
	    exit 1
	fi
    done
fi

exit 0
