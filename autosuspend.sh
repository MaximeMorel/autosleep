#!/bin/bash

# autosuspend script :
# After being launched, it will suspend the machine (using pm-suspend) after
# 1h if there is no user active on a console and no network traffic (<100ko/s)
# Author : Maxime Morel <maxime.morel69@gmail.com>

# Changelog
# 06/01/2014 : Actually quite ugly, but does what I need :
# allow me to wake my storage machine and let it autosuspend if unused.
#
# 08/01/2014 : no longer need dstat to compute netspeed, use /proc/net/dev

# countdown in seconds
countdown=3600

# timestep in seconds
timestep=30

# user idle time before sleep
idletime=60

# network threshold to go below before sleep
netthreshold=100000

# nb iterations (test purpose)
nbiter=10

function isUserActive()
{
    res=0
    n=$(date "+%s")
    for u in $(w -hs | awk '{ print $3 }' | sed -e 's/\([0-9]\)s$/\1sec/')
    do
        #echo $u
        d=$(date -d "-$u" "+%s")
        t=$(( n - d ))
        if [ $t -lt $idletime ]
        then
            echo "user active"
            res=1
        fi
    done
}

function getTotalTraffic()
{
        val=$(cat /proc/net/dev | grep eth0 | tr -s ' ' | cut -f3,11 -d ' ')
        down=$(echo $val | cut -f1 -d' ') # down
        up=$(echo $val | cut -f2 -d' ') # up
        # sum
        total=$(( $down + $up ))
}
getTotalTraffic
old_total=$total

function isNetworkUsed()
{
	res=0

	getTotalTraffic
        new_total=$total
        total=$(( $new_total - $old_total ))
        old_total=$new_total

	# per sec value
	total=$(( $total / $timestep ))

	# put in kB
	total=$(( $total / 1024 ))

        echo $total "kB/sec"

    if [ $total -gt $netthreshold ] # 100ko/sec
    then
        echo "network active"
        res=1
    fi
}

start=$(date "+%s")

mynbiter=0
while [ 1 ]
do
    n=$(date "+%s")
    echo $n

    myres=0

    isUserActive
    myres=$(( $myres | $res ))
    #echo $res

    isNetworkUsed
    myres=$(( $myres | $res ))

    # if myres is 1 then we have at least one condition which prevent going suspend
    if [ $myres -eq 1 ]
    then    # reset countdown
        mycountdown=$countdown
        echo Reset countdown
    else    # decrease countdown
        mycountdown=$(( $mycountdown - $timestep ))
        echo Decrease countdown : $mycountdown
    fi

    if [ $mycountdown -le 0 ]
    then
        echo Go to suspend
        # suspend command
        pm-suspend

        # reset countdown
        mycountdown=$countdown
    fi

    echo Sleep $timestep
    sleep $timestep

    mynbiter=$(( $mynbiter + 1 ))
done
