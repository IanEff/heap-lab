#!/bin/bash
# heap-lab: runs on broome for scripts/watch.sh (fed over ssh, never copied).
#   MODE=pick  print the Ingress hosts that answer 200 on any node
#   MODE=loop  probe HOSTS on every node once a second, one CSV row each
# IPS is "greene=192.168.104.138 crosby=... broome=...", plus entries like
# "greene-v6=[fdf2:...::11]" for IPv6 (bracketed, so curl -g takes it as a URL).
set -u
nl=$'\n'
hosts_for() {
    local h p path
    for h in canary.recurse.cloud jupyter.recurse.cloud; do
        for p in $IPS; do
            path=/; [ "$h" = canary.recurse.cloud ] && path=/heartbeat
            if [ "$(curl -sg --max-time 1 -o /dev/null -w '%{http_code}' -H "Host: $h" "http://${p#*=}$path")" = 200 ]; then
                echo "$h"; break
            fi
        done
    done
}
[ "$MODE" = pick ] && { hosts_for; exit 0; }
while true; do
    t=$(date +%s)
    for h in $HOSTS; do
        for p in $IPS; do
            n=${p%%=*}; ip=${p#*=}; path=/
            [ "$h" = canary.recurse.cloud ] && path=/heartbeat
            out=$(curl -sg --max-time 1 -w "${nl}%{http_code}" -H "Host: $h" "http://$ip$path" 2>/dev/null)
            code=${out##*"$nl"}; body=${out%"$nl"*}
            if [ "$code" != 200 ]; then
                echo "$t,$h@$n,down,http ${code:-000}"
            elif [ "$path" = /heartbeat ] && [ "$((t - ${body:-0}))" -gt 5 ] 2>/dev/null; then
                echo "$t,$h@$n,stale,$((t - body))s old"
            else
                echo "$t,$h@$n,up,"
            fi
        done
    done
    sleep 1
done
