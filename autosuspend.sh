#!/bin/bash

# autosuspend script:
# After being launched, it will hibernate the machine (using pm-hibernate or
# systemctl hibernate) after 1h if there is no user active on a console and
# no network traffic (<100KiBps) and if the lock file has not been touched.
# Author : Maxime Morel <maxime.morel69@gmail.com>

# Changelog
# 2016/09/07:
# Fix indentation.
# Detect at the beginning if systemd is present and store it in a flag.
# Use bash function return values and local variables.
# Allowing to delay hibernation by touching a lock file.
# Use KiB unit.
#
# 2015/10/02:
# Shutdown if kernel has been updated, to prevent any stall during wakeup.
# Check for systemctl and use it if available instead of pm-hibernate.
#
# 2014/01/08:
# No longer need dstat to compute netspeed, use /proc/net/dev.
# Compute user idle time using stat on tty device, no more errors.
# Fix getting stat info with ls -lu (atime field).
#
# 2014/01/06:
# Currently quite ugly, but does what I need:
# Allows me to wake my storage machine and let it autosuspend if unused.

# countdown in seconds
countdown=14400

# timestep in seconds
timestep=30

# user idle time before sleep
idletime=60

# network threshold to go below before sleep in KiBps
netthreshold=100

# network interface to monitor
network_interface=eth0

# lock file to force hibernation delay
lockFile=/tmp/autosuspend.lock
touch "$lockFile"
chmod 666 "$lockFile"

# do we have systemd?
hasSystemd=0
which systemctl > /dev/null
if [ $? -eq 0 ]
then
    hasSystemd=1
fi

# nb iterations (test purpose)
nbiter=10

function isUserActive()
{
    local res=0
    local n=$(date "+%s")
    local tty
    for tty in $(w -h | tr -s ' ' | cut -d' ' -f2)
    do
        # stat the tty device to have last modif time
        local lastmodif=$(ls -lu --time-style=full-iso /dev/$tty | tr -s ' ' | cut -d' ' -f 7,8,9)
        local d=$(date -d "$lastmodif" "+%s") # unix timestamp
        local t=$(( $n - $d )) # idletime
        #echo "$tty $d $t"
        if [ $t -lt $idletime ]
        then
            echo "User active: $tty $t sec"
            res=1
        fi
    done

    return $res
}

function getTotalTraffic()
{
    local val=$(cat /proc/net/dev | grep $network_interface | tr -s ' ' | cut -f3,11 -d ' ')
    local down=$(echo $val | cut -f1 -d' ') # down
    local up=$(echo $val | cut -f2 -d' ') # up
    # sum
    local total=$(( $down + $up ))
    return $total
}
getTotalTraffic
old_total=$?

function isNetworkUsed()
{
    local res=0

    getTotalTraffic
    local new_total=$?
    local total=$(( $new_total - $old_total ))
    old_total=$new_total

    # per sec value
    total=$(( $total / $timestep ))

    # put in KiBps
    total=$(( $total / 1024 ))

    if [ $total -gt $netthreshold ]
    then
        echo "Network active: $total KiBps"
        res=1
    fi

    return $res
}

function isLockFileTouched()
{
    local res=0
    if [ -f "$lockFile" ]
    then
        local t=$(( ($(date +%s) - $(stat -c %Y "$lockFile")) ))
        if [ $t -lt $idletime ]
        then
            echo "Lock file touched: $t sec"
            res=1
        fi
    fi

    return $res
}

function sendHibernate()
{
    sync
    if [ -d /lib/modules/$(uname -r) ]
    then
        if [ $hasSystemd == 1 ]
        then
            #systemctl hibernate
            systemctl poweroff
        else
            #pm-suspend
            #pm-hibernate
            shutdown -h now
        fi
    else
        echo "The kernel has been updated, better to shutdown"
        if [ $hasSystemd == 1 ]
        then
            systemctl poweroff
        else
            shutdown -h now
        fi
    fi
}

mycountdown=$countdown
mynbiter=0
while [ 1 ]
do
    n=$(date "+%s")

    finalres=0
    res=0

    isUserActive
    res=$?
    finalres=$(( $finalres | $res ))

    isNetworkUsed
    res=$?
    finalres=$(( $finalres | $res ))

    isLockFileTouched
    res=$?
    finalres=$(( $finalres | $res ))

    # if finalres is 1 then we have at least one condition which prevents going to suspend
    if [ $finalres -eq 1 ]
    then
        mycountdown=$countdown
        echo "Reset countdown: $mycountdown sec"
    else
        mycountdown=$(( $mycountdown - $timestep ))
        echo "Decrease countdown: $mycountdown sec ($(( $mycountdown / 60 )) min) before suspend"
    fi

    if [ $mycountdown -le 0 ]
    then
        echo "Go to suspend"
        # suspend command
        sendHibernate

        # reset countdown
        mycountdown=$countdown
    fi

    echo "Sleep $timestep sec"
    sleep $timestep

    mynbiter=$(( $mynbiter + 1 ))
done

