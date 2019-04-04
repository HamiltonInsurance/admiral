#!/bin/bash

# A script for coordinating an admiral release across a cluster

function die
{
    echo $1
    exit 1
}

# Set up parameters
APP=$0
WORKERS=$(docker node ls --format "{{.Hostname}} {{.ManagerStatus}}" |  column -t -s' ' | ag -v Leader | cut -d" " -f1)
DT=$(date +%H:%M)

echo "Updating workers at $DT..."
echo
echo "Are you paying attention?"
echo -n "Please confirm the current hour and minute to proceed: "
read UDT

if [ "$UDT" != "$DT" ]; then
    die "Validation failed!"
fi

for W in "$WORKERS"; do
    echo -n "\tUpdate worker: $W"
    tt -m "$W" "admiral"
done
admiral

