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

# Transmission

interface="ppp*"
host="192.168.0.74"
web_port="9091"
username="admin"
password="12345"
forward_ipv6=1
dnat_accept=1
nft_snippet=1

# script begins

retry_interval=57
retry_times=2880

rsf="$script_dir/trs_running"
rs=0
rs_b=0
wait_to_exit=$(($retry_interval + 30))

if [ -f "$rsf" ]; then
  rs=$(cat "$rsf")
  if ! [ "$rs" -ge 0 ]; then
    if ! [[ $(wc -c <"$rsf") -le 4 ]]; then
      echo "$rsf : unexpected value"
      echo "An error occurred."
      echo "Place this script on other folder to suppress the error."
      exit 99
    fi
    rs=0
  fi

  rs=$(($rs + 1))
  echo "$rs" >"$rsf"
  sleep $wait_to_exit

  if ! [ -f "$rsf" ]; then
    exit 100
  fi

  rs_b=$(cat "$rsf")
  if ! [ "$rs" = "$rs_b" ]; then
    exit 200
  fi

  echo "0" >"$rsf"
else
  echo "0" >"$rsf"
fi

x=1
ut_token=nul

# If bittorrent client isn't online, try 57 seconds later.
# ( Loop last 48 hours unless this script is invoked again or app is online. )
while [ $x -le $retry_times ]; do
  if ! [ -f "$rsf" ]; then
    exit 101
  fi

  rs=$(cat "$rsf")
  if ! [ "$rs" = "0" ]; then
    echo "Another running script detected, exit."
    exit 102
  fi

  tr_header=$(curl -m 3 -s -u $username:$password http://$host:$web_port/transmission/rpc | grep -o '<code.*code>' | grep -o '>.*<' | sed -e 's/>\(.*\)</\1/')
  if [[ $(expr match "$tr_header" 'X.\+Id...') -gt 27 ]]; then
    echo "Update Transmission listen port to $public_port"
    curl -m 3 -s -u $username:$password -X POST -H "$tr_header" -d '{"method":"session-set","arguments":{"peer-port":'$port'}}' "http://$host:$web_port/transmission/rpc" &>/dev/null
	if [ $? != '0' ]; then
      sleep 5
      echo "Retrying.."
      curl -m 3 -s -u $username:$password -X POST -H "$tr_header" -d '{"method":"session-set","arguments":{"peer-port":'$port'}}' "http://$host:$web_port/transmission/rpc" &>/dev/null
    fi
    break
  fi

  x=$(($x + 1))
  sleep $retry_interval
done

if ! [ $x -le $retry_times ]; then
  exit 103
fi

retry_on_fail() {
  $1
  if [ $? != '0' ]; then
    sleep 1
    $1
    if [ $? != '0' ]; then
      sleep 2
      $1
    fi
  fi
}

# nft
retry_on_fail "nft add chain inet fw4 tr_dstnat"
retry_on_fail "nft flush chain inet fw4 tr_dstnat"
if ! nft list chain inet fw4 dstnat | grep -q 'jump tr_dstnat' > /dev/null; then
  retry_on_fail "nft add rule inet fw4 dstnat jump tr_dstnat"
fi
retry_on_fail "nft add rule inet fw4 tr_dstnat iifname $interface $protocol dport $private_port counter dnat ip to $host:$port"
n_rule1="add rule inet fw4 tr_dstnat iifname $interface $protocol dport $private_port counter dnat ip to $host:$port"

n_rule2=""
n_rule3=""
n_rule4=""
if [ $forward_ipv6 -eq 1 ]; then
  retry_on_fail "nft add chain inet fw4 tr_forward_wan"
  retry_on_fail "nft flush chain inet fw4 tr_forward_wan"
  if ! nft list chain inet fw4 forward_wan | grep -q 'jump tr_forward_wan' > /dev/null; then
    retry_on_fail "nft insert rule inet fw4 forward_wan jump tr_forward_wan"
  fi
  retry_on_fail "nft add rule inet fw4 tr_forward_wan iifname $interface meta nfproto ipv6 tcp dport $port counter accept"
  retry_on_fail "nft add rule inet fw4 tr_forward_wan iifname $interface meta nfproto ipv6 udp dport $port counter accept"
  n_rule2="insert rule inet fw4 forward_wan jump tr_forward_wan"
  n_rule3="add rule inet fw4 tr_forward_wan iifname $interface meta nfproto ipv6 tcp dport $port counter accept"
  n_rule4="add rule inet fw4 tr_forward_wan iifname $interface meta nfproto ipv6 udp dport $port counter accept"
fi

n_rule5=""
if [ $dnat_accept -eq 1 ]; then
  n_rule5="insert rule inet fw4 forward_wan ct status dnat counter accept"
  if ! nft list chain inet fw4 forward_wan | grep 'ct status dnat' | grep -q 'accept' > /dev/null; then
    retry_on_fail "nft insert rule inet fw4 forward_wan ct status dnat counter accept"
  fi
fi

if [ $nft_snippet -eq 1 ] && [ -d /usr/share/nftables.d/ruleset-post ]; then
  echo "
add chain inet fw4 tr_dstnat
flush chain inet fw4 tr_dstnat
add rule inet fw4 dstnat jump tr_dstnat
$n_rule1
add chain inet fw4 tr_forward_wan
flush chain inet fw4 tr_forward_wan
$n_rule2
$n_rule3
$n_rule4
$n_rule5
  " > /usr/share/nftables.d/ruleset-post/tr_forward_wan.nft
fi

rm -f "$rsf"
echo Fin
exit 0
