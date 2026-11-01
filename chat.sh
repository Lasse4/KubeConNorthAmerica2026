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
  # Big prompts until the budget has said 429 three times. Right after ./traffic.sh that is
  # 200 200 429 429 429. If the budget hour has turned since then, a few more 200s come first.
  big=$(printf 'context %.0s' $(seq 7000))
  denied=0
  for _ in $(seq 10); do
    code=$(chat "$big" -o /dev/null -w '%{http_code}')
    printf '%s ' "$code"
    [[ $code == 429 ]] && denied=$((denied + 1))
    ((denied < 3)) || break
    sleep 0.5
  done
  echo
else
  chat "$prompt" -w '\n%{http_code}\n'
fi
