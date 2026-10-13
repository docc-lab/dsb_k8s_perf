#!/bin/sh

##
## On the head node, wait until every node has rebooted into the harvest
## kernel (setup-kernel.sh touched $OURDIR/kernel-done) before Kubespray
## starts ssh'ing into them.
##

set -x

if [ -z "$EUID" ]; then
    EUID=`id -u`
fi

# Grab our libs
. "`dirname $0`/setup-lib.sh"

if [ -f $OURDIR/kernel-wait-done ]; then
    exit 0
fi

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi
if [ -f $LOCALSETTINGS ]; then
    . $LOCALSETTINGS
fi

if [ ! "$HARVESTENABLE" = "1" ]; then
    touch $OURDIR/kernel-wait-done
    exit 0
fi

logtstart "kernel-wait"

# Kernel builds take a while; give up after 3 hours.
DEADLINE=`expr \`date +%s\` + 10800`
for node in $NODES ; do
    while true ; do
	$SSH -o ConnectTimeout=10 $node test -f $OURDIR/kernel-done
	if [ $? -eq 0 ]; then
	    echo "$node: `$SSH $node uname -r`"
	    break
	fi
	if [ `date +%s` -gt $DEADLINE ]; then
	    echo "ERROR: $node never came up on the harvest kernel; aborting!"
	    exit 1
	fi
	echo "Waiting for $node to boot the harvest kernel..."
	sleep 30
    done
done

logtend "kernel-wait"
touch $OURDIR/kernel-wait-done
exit 0
