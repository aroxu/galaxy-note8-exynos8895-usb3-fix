#!/system/bin/sh

MODDIR=${0%/*}

# Run asynchronously so Magisk's late_start service stage is not blocked.
sh "$MODDIR/worker.sh" >/dev/null 2>&1 &

exit 0
