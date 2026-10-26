#!/usr/bin/env bash
# Four teams send traffic to the same model, two from outside the cluster
# (support, ml-research) and two from inside (data, platform, see in-cluster.yaml).
set -euo pipefail
cd "$(dirname "$0")"

show() { awk -v t="$1" '{printf "  %-12s %4d x %s\n", t, $1, $2}'; }

send() { # team, requests, words per prompt
  local body
  body=$(jq -nc --arg p "$(printf 'context %.0s' $(seq "$3"))" '{model: "mock-llm", messages: [{role: "user", content: $p}]}')
  for _ in $(seq "$2"); do
    curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/v1/chat/completions \
      -H "Authorization: Bearer $(cat "tokens/$1.jwt")" -H 'Content-Type: application/json' -d "$body"
  done | sort | uniq -c | show "$1"
}

# Budgets count per clock hour: do not start just before they reset.
while (( $(date +%s) % 3600 > 3300 )); do echo "Budget hour ends soon, waiting ..."; sleep 30; done

# Fresh budgets, and cost-by-team.sh counts from here.
kubectl exec -n ratelimit deploy/redis -- redis-cli FLUSHALL >/dev/null
date -u +%Y-%m-%dT%H:%M:%SZ > tokens/last-traffic-start
kubectl delete jobs -n apps -l demo=traffic --ignore-not-found >/dev/null
kubectl apply -f in-cluster.yaml >/dev/null

echo "From outside the cluster (localhost:8080):"
send support 48 115 &
send ml-research 3 7000 &
wait

kubectl wait --for=condition=complete job -n apps -l demo=traffic --timeout=300s >/dev/null
echo "From inside the cluster (Service DNS):"
kubectl logs -n apps job/nightly-summaries | show data
kubectl logs -n apps job/code-review-agent | show platform

echo "The nightly summaries sent the most requests. Who used the most tokens? ./cost-by-team.sh"
