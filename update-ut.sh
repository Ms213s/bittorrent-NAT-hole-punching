#!/bin/sh

script=$(readlink -f "$0")
script_dir=$(dirname "$script")

# natmap
public_addr=$1
public_port=$2
ip4p=$3
private_port=$4
protocol=$5

port=$public_port

echo 
echo "External IP - $public_addr:$public_port, bind port $private_port, $protocol"
echo 

# utorrent

interface=""
host="192.168.0.74"
web_port="4444"
username="admin"
password="123456"
set_tracker_ip=1

# Update utorrent listen port.

retry_interval=117


rsf="$script_dir/uts_running"
rs=0
wait_to_exit=$(( $retry_interval + 10 ))

if [ -f $rsf ]
then
  echo 1 > $rsf
  sleep $wait_to_exit
  echo 0 > $rsf
else
  echo 0 > $rsf
fi

x=1
ut_token=nul

# If app isn't online, try 117 seconds later. 
# ( Loop last 48 hours unless this script is invoked again or app is online. )
while [ $x -le 1440 ]
do
  rs=$(cat $rsf)
  if [ $rs -eq 1 ]
  then
    echo 'Another running script detected, exit.'
    exit 2
  fi
  
  ut_token=$(curl -m 3 -s -u $username:$password http://$host:$web_port/gui/token.html | grep -o '<div.*div>' | grep -o '>.*<' | sed -e 's/>\(.*\)</\1/')
  
  if [[ $(expr match "$ut_token" '.\+=') -gt 8 ]]
  then
    echo "update utorrent listen port to $public_port.."
    
    if [ $set_tracker_ip -eq 1 ]
    then
      curl -u $username:$password "http://$host:$web_port/gui/?token=$ut_token&action=setsetting&s=bind_port&v=$port&s=tracker_ip&v=$public_addr" >/dev/null 2>&1
    else
      curl -u $username:$password "http://$host:$web_port/gui/?token=$ut_token&action=setsetting&s=bind_port&v=$port" >/dev/null 2>&1
    fi
    break
  fi
  x=$(( $x + 1 ))
  sleep $retry_interval
done

# iptables

echo 

tdrsh="$script_dir/uts_tdr"

if [ -f $tdrsh ]
then
  sh $tdrsh
fi

d_rule=" "

sleep 1
echo "add rule"

if [ -z $interface ]
then
  iptables -t nat -I PREROUTING -p $protocol --dport $private_port -j DNAT --to-destination $host:$port
  d_rule="iptables -t nat -D PREROUTING -p $protocol --dport $private_port -j DNAT --to-destination $host:$port"
else
  iptables -t nat -I PREROUTING -i $interface -p $protocol --dport $private_port -j DNAT --to-destination $host:$port
  d_rule="iptables -t nat -D PREROUTING -i $interface -p $protocol --dport $private_port -j DNAT --to-destination $host:$port"
fi

echo "#! /bin/sh
# External IP - $public_addr:$public_port, bind port $private_port, $protocol
sleep 1
echo 'delete rule'
$d_rule
" > $tdrsh

rm $rsf

echo Fin
