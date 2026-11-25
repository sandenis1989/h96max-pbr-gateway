#!/bin/bash
set -euo pipefail

# End-to-end self-test of all 3 routing circuits using a throwaway netns+veth
# as a "LAN client". Host is NOT reconfigured permanently: the veth is added to
# the nftables set lan_ifaces only for the duration of the test.

NS=pbrtest
VH=veth-pbr
VN=veth-pbr-ns
IPH=10.99.0.1
IPN=10.99.0.2
GW_DNS=192.168.12.1

cleanup() {
    nft delete element inet pbr_fw lan_ifaces "{ \"$VH\" }" 2>/dev/null || true
    ip netns del "$NS" 2>/dev/null || true
    ip link del "$VH" 2>/dev/null || true
}
trap cleanup EXIT

counters() {
    nft -a list ruleset | grep -E 'counter packets' | grep -E 'ru_ips|zapret_domains|mark set|tproxy to' \
        | sed 's/^[[:space:]]*//; s/ # handle.*//'
}

cleanup
ip netns add "$NS"
ip link add "$VH" type veth peer name "$VN"
ip link set "$VN" netns "$NS"
ip addr add "$IPH/24" dev "$VH"
ip link set "$VH" up
ip netns exec "$NS" ip link set lo up
ip netns exec "$NS" ip addr add "$IPN/24" dev "$VN"
ip netns exec "$NS" ip link set "$VN" up
ip netns exec "$NS" ip route add default via "$IPH"
nft add element inet pbr_fw lan_ifaces "{ \"$VH\" }"

echo "== counters before =="
counters

echo
echo "== local DNS via dnsmasq ($GW_DNS) =="
ip netns exec "$NS" dig +short +time=4 +tries=1 @"$GW_DNS" example.com | head -1 || echo FAIL

echo
echo "== circuit 3: foreign TCP via VPN =="
echo -n "exit_ip_via_vpn="
ip netns exec "$NS" curl -s --max-time 15 https://api.ipify.org || echo FAIL
echo

echo
echo "== circuit 3: foreign UDP via VPN (DNS to 1.1.1.1) =="
echo -n "udp_dns="
ip netns exec "$NS" dig +short +time=6 +tries=1 @1.1.1.1 example.com 2>&1 | head -1 || echo FAIL

echo
echo "== circuit 2: DPI bypass (YouTube, resolved via dnsmasq) =="
YT_IP=$(dig +short +time=4 +tries=1 @"$GW_DNS" www.youtube.com | tail -1)
echo "youtube_ip=$YT_IP"
if nft list set inet pbr_fw zapret_domains | grep -q "$YT_IP"; then
    echo "in_zapret_set=yes"
else
    echo "in_zapret_set=no"
fi
echo -n "youtube_http="
ip netns exec "$NS" curl -s -o /dev/null -w '%{http_code}\n' --max-time 20 --resolve "www.youtube.com:443:$YT_IP" https://www.youtube.com/ || echo FAIL

echo
echo "== circuit 1: RU direct (ya.ru, resolved via dnsmasq) =="
YA_IP=$(dig +short +time=4 +tries=1 @"$GW_DNS" ya.ru | tail -1)
echo "ya_ip=$YA_IP"
echo -n "ya_http="
ip netns exec "$NS" curl -s -o /dev/null -w '%{http_code}\n' --max-time 15 --resolve "ya.ru:443:$YA_IP" https://ya.ru/ || echo FAIL

echo
echo "== counters after =="
counters
