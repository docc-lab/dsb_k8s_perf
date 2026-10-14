#!/bin/sh

##
## One-screen view of the profile's setup across all nodes.  Run on node-0
## (as root, so the setup ssh keys work) any time while setup is running:
##
##   sudo sh /local/repository/setup-status.sh
##
## Per node: reachable or not, running kernel, which setup steps have
## finished ($OURDIR/*-done markers), whether setup-driver.sh is still
## running, what /storage is mounted from, and the last ERROR line from
## /local/logs.  On node-0 it also shows the kernel-wait status and
## whether Kubespray (ansible-playbook) is running.
##

OURDIR=/local/setup
SSH="ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5"
NODES=`cut -f1 $OURDIR/fqdn.map 2>/dev/null | sort -n | xargs`
if [ -z "$NODES" ]; then
    echo "no $OURDIR/fqdn.map yet; setup has not got that far"
    exit 1
fi

REMOTE='
echo "  kernel:  $(uname -r)"
echo "  done:    $(ls '$OURDIR' 2>/dev/null | sed -n "s/-done$//p" | xargs)"
if pgrep -f setup-driver.sh >/dev/null; then echo "  driver:  RUNNING"; else echo "  driver:  not running"; fi
echo "  storage: $(findmnt -no SOURCE /storage 2>/dev/null || echo NOT MOUNTED)"
E=$(grep -h "^ERROR" /local/logs/*.log 2>/dev/null | tail -1)
[ -n "$E" ] && echo "  last error: $E"
true
'

for node in $NODES ; do
    echo "== $node"
    $SSH $node "$REMOTE" 2>/dev/null
    if [ $? -eq 255 ]; then
	echo "  UNREACHABLE over ssh (rebooting, or stuck at boot: check its CloudLab console)"
    fi
done

echo "== node-0 head-node steps"
if ls $OURDIR/kernel-wait.status* >/dev/null 2>&1; then
    echo "  kernel-wait:"
    cat $OURDIR/kernel-wait.status* | sed 's/^/    /'
fi
P=`pgrep -af ansible-playbook | head -1`
if [ -n "$P" ]; then
    echo "  kubespray: RUNNING (tail -f /local/logs/setup-kubespray.sh.log)"
else
    echo "  kubespray: not running"
fi
echo "  last timing entry: `tail -1 $OURDIR/setup-time.log 2>/dev/null`"
