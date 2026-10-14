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
START=`date +%s`
DEADLINE=`expr $START + 10800`
# $STATUSFILE lists the nodes already on the harvest kernel; the node we
# are still waiting on gets $STATUSFILE.<node>, rewritten every poll, so
# `cat $OURDIR/kernel-wait.status*` shows who is holding us up and why.
STATUSFILE=$OURDIR/kernel-wait.status
for node in $NODES ; do
    while true ; do
	$SSH -o ConnectTimeout=10 -o BatchMode=yes $node test -f $OURDIR/kernel-done
	if [ $? -eq 0 ]; then
	    echo "$node: `$SSH $node uname -r`"
	    echo "$node ok `$SSH $node uname -r` `date`" >> $STATUSFILE
	    break
	fi
	ELAPSED=`expr \( \`date +%s\` - $START \) / 60`
	# Tell "unreachable" (rebooting, or stuck in emergency mode: check
	# the node's console) apart from "up, still building / wrong kernel".
	STATE=$($SSH -o ConnectTimeout=10 -o BatchMode=yes $node \
	    "echo kernel=\$(uname -r); \
	     test -f $OURDIR/kernel-installed && echo installed=\$(cat $OURDIR/kernel-installed); \
	     grep -h '^ERROR' /local/logs/*.log 2>/dev/null | tail -1; true" 2>/dev/null)
	if [ $? -eq 255 ]; then
	    MSG="$node unreachable over ssh (${ELAPSED}m): rebooting, or stuck at boot -- check its CloudLab console"
	else
	    MSG="$node up but not done (${ELAPSED}m): `echo $STATE | tr '\n' ' '`"
	fi
	echo "$MSG"
	echo "$MSG `date`" > $STATUSFILE.$node
	if [ `date +%s` -gt $DEADLINE ]; then
	    echo "ERROR: $node never came up on the harvest kernel; last state: $MSG; aborting!"
	    exit 1
	fi
	sleep 30
    done
    rm -f $STATUSFILE.$node
done

logtend "kernel-wait"
touch $OURDIR/kernel-wait-done
exit 0
