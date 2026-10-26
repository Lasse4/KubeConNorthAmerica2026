#!/usr/bin/env bash
# Requests, tokens and cost per team since the last ./traffic.sh, from the gateway's access log.
set -euo pipefail
cd "$(dirname "$0")"

printf '%-12s %9s %8s %10s %9s\n' team requests tokens cost '% tokens'
kubectl logs -n kserve deploy/kserve-ingress-gateway --since-time="$(cat tokens/last-traffic-start)" |
  grep 'protocol=llm' | grep 'http.status=200' | grep ' team=' | tr -d '"' |
  awk '
    function get(k) { return match($0, " " k "=[^ ]+") ? substr($0, RSTART + length(k) + 2, RLENGTH - length(k) - 2) : 0 }
    { t = get("team"); n = get("gen_ai.usage.input_tokens") + get("gen_ai.usage.output_tokens")
      req[t]++; tok[t] += n; cost[t] += get("agw.ai.usage.cost.total"); total += n }
    END { for (t in req) printf "%-12s %9d %8d %10.4f %8.0f%%\n", t, req[t], tok[t], cost[t], 100 * tok[t] / total }' |
  sort -k5 -n
