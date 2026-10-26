#!/usr/bin/env bash
# Send one prompt as one team.
#   ./chat.sh support 'my card is 4111 1111 1111 1111'   403 Request contains PII
#   ./chat.sh ml-research --loop                         200 200 429 429 429
set -euo pipefail
cd "$(dirname "$0")"
usage="usage: ./chat.sh <team> <prompt>  or  ./chat.sh <team> --loop"
team=${1:?$usage}
prompt=${2:?$usage}
[[ -f tokens/$team.jwt ]] || { echo "no token for team '$team' in tokens/ (README, step 3)" >&2; exit 1; }

chat() { # prompt, curl options
  curl -s localhost:8080/v1/chat/completions "${@:2}" \
    -H "Authorization: Bearer $(cat "tokens/$team.jwt")" -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg p "$1" '{model: "mock-llm", messages: [{role: "user", content: $p}]}')"
}

if [[ $prompt == --loop ]]; then
  big=$(printf 'context %.0s' $(seq 7000))
  for _ in 1 2 3 4 5; do chat "$big" -o /dev/null -w '%{http_code} '; sleep 0.5; done
  echo
else
  chat "$prompt" -w '\n%{http_code}\n'
fi
