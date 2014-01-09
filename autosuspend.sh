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
# compute user idle time using stat on tty device, no more errors
# fix getting stat info with ls -lu (atime field)

# countdown in seconds
countdown=3600

# timestep in seconds
timestep=30

# user idle time before sleep
idletime=60

# network threshold to go below before sleep in kBps
netthreshold=100

# nb iterations (test purpose)
nbiter=10

function isUserActive()
{
    res=0
    n=$(date "+%s")
    for tty in $(w -h | tr -s ' ' | cut -d' ' -f2)
    do
	# stat the tty device to have la modif time
	lastmodif=$(ls -lu --time-style=full-iso /dev/$tty | tr -s ' ' | cut -d' ' -f 7,8,9)
        d=$(date -d "$lastmodif" "+%s")	# unix timestamp
        t=$(( $n - $d )) # idletime
        #echo $tty $d $t
        if [ $t -lt $idletime ]
        then
            echo "user active : " $tty $t sec
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

        echo $total kB/sec

    if [ $total -gt $netthreshold ] # 100ko/sec
    then
        echo "network active"
        res=1
    fi
}

start=$(date "+%s")
mycountdown=$countdown
mynbiter=0
while [ 1 ]
do
    n=$(date "+%s")
    #echo $n

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
        echo Reset countdown : $mycountdown sec
    else    # decrease countdown
        mycountdown=$(( $mycountdown - $timestep ))
        echo Decrease countdown : $mycountdown sec \($(( $mycountdown / 60 )) min\) before suspend
    fi

    if [ $mycountdown -le 0 ]
    then
        echo Go to suspend
        # suspend command
        pm-suspend

        # reset countdown
        mycountdown=$countdown
    fi

    echo Sleep $timestep sec
    sleep $timestep

    mynbiter=$(( $mynbiter + 1 ))
done
