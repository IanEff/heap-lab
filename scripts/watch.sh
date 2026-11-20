#!/usr/bin/env bash
# heap-lab: watch.sh
# Measure what an upgrade breaks, and for how long. Run it in its own
# terminal, do the upgrade in another, Ctrl-C when done. Once a second:
#
#   api:<node>       the node's API server through its forwarded port, from
#                    the Mac. 401 or 200 is up; 503 is not ready; no answer is down.
#   <host>@<node>    an Ingress host on the node's port 80, asked from inside
#                    broome (Heap's runbook curls from broome too). For the
#                    canary the body is the writer's last timestamp, so an
#                    answer more than 5 s old is "stale": NFS or the writer.
#   <host>@<node>-v6 the same on the node's IPv6 address, for nodes whose
#                    ingress answers there when the watch starts (dual-stack).
#
# Targets are whatever answers when the watch starts. Every probe goes to
# .state/watch/<time>.csv; the terminal shows changes only, as offsets from
# the start; Ctrl-C prints each target's outages.
set -uo pipefail
_TAG=watch
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
mkdir -p "${STATE_DIR}/watch"
CSV="${STATE_DIR}/watch/$(date +%Y%m%dT%H%M%S).csv"
T0=$(date +%s)

api_probe() {  # node -> http code; 000 when nothing answers
    curl -sk --max-time 1 -o /dev/null -w '%{http_code}' "https://127.0.0.1:$(api_port "$1")/readyz" 2>/dev/null
}

IPS=""; for n in ${LAB_NODES}; do IPS="${IPS} ${n}=$(node_ip "$n")"; done
IPS="${IPS# }"
# scripts/guest/probe.sh, run on broome over ssh: mode, IPS, HOSTS.
remote() { on broome "MODE=$1 IPS='$2' HOSTS='${3:-}' bash -s" < "${LAB_ROOT}/scripts/guest/probe.sh"; }

API_NODES=""
for n in ${LAB_NODES}; do [ "$(api_probe "$n")" != 000 ] && API_NODES="${API_NODES} ${n}"; done
HOSTS=$(remote pick "$IPS" | paste -sd' ' -)
# Each node's IPv6 address too, if its ingress answers there. An IPv4-only
# cluster's Envoy doesn't listen on IPv6, so those targets are left out.
V6=""
for n in ${LAB_NODES}; do
    t="${n}-v6=[$(node_ipv6 "$n")]"
    [ -n "$HOSTS" ] && [ -n "$(remote pick "$t")" ] && { IPS="${IPS} ${t}"; V6="${V6} ${n}"; }
done
info "API:     ${API_NODES:- none}"
info "Ingress: ${HOSTS:-none}, on every node; over IPv6 on:${V6:- none}"
info "Log:     ${CSV#"${LAB_ROOT}/"}   (Ctrl-C to stop and summarize)"
echo "epoch,target,state,detail" > "$CSV"

api_loop() {
    while true; do
        local t c; t=$(date +%s)
        for n in ${API_NODES}; do
            c=$(api_probe "$n")
            # Anonymous requests get 401 from a ready k3s API and 503 from
            # one that's still starting, so 503 counts as an outage.
            case "$c" in
                000) echo "$t,api:$n,down,no answer" ;;
                503) echo "$t,api:$n,notready,503" ;;
                *)   echo "$t,api:$n,up,$c" ;;
            esac
        done
        sleep 1
    done
}
ingress_loop() { [ -n "$HOSTS" ] && remote loop "$IPS" "$HOSTS"; }

summarize() {
    echo
    info "Outages, as offsets from the start (log: ${CSV#"${LAB_ROOT}/"}):"
    gawk -F, -v t0="$T0" 'function at(s) { return sprintf("+%d:%02d", (s-t0)/60, (s-t0)%60) }
    NR>1 {
        k=$2; if (!(k in total)) order[++nk]=k
        total[k]++
        if ($3!="up") { bad[k]++; if (!(k in open)) { open[k]=$1; why[k]=$3" "$4 } }
        else if (k in open) { out[k]=out[k] sprintf("      %s for %ds (%s)\n", at(open[k]), $1-open[k], why[k]); delete open[k] }
    } END {
        for (i=1;i<=nk;i++) { k=order[i]
            if (k in open) out[k]=out[k] sprintf("      %s, still out at the end (%s)\n", at(open[k]), why[k])
            printf "  %-36s %d of %d probes failed\n%s", k, bad[k]+0, total[k], out[k] }
    }' "$CSV"
}

stop() { trap - INT TERM; kill $(jobs -p) 2>/dev/null; pkill -P $$ 2>/dev/null; sleep 0.5; summarize; exit 0; }
trap stop INT TERM
{ api_loop & ingress_loop & wait; } | tee -a "$CSV" \
    | gawk -F, -v t0="$T0" '{ if (state[$2]!=$3) { printf "+%d:%02d  %-36s %s %s\n", ($1-t0)/60, ($1-t0)%60, $2, $3, $4; state[$2]=$3 } fflush() }' &
wait
