# Who Ran Up the Inference Bill?

Demo for the KubeCon North America 2026 talk **"Who Ran Up the Inference Bill?"**
by Lasse Vierow. Not for production, just an example.

Everything runs locally in kind: **KServe** deploys the model, **agentgateway** routes and
meters every request, a **rate limit service** keeps the budgets. The model is
`llm-d-inference-sim`: no GPU, no API key, and no internet on the day of the talk.

## How it works

1. Four teams call the same model, each with its own JWT.
2. agentgateway writes team, model, tokens and cost into every access log line.
3. A guardrail stops PII before it reaches the model. A budget stops a team at 60,000 tokens per hour.
4. If our model goes down, a paid cloud API takes over, and the log shows what that costs.

The team with the most requests is not the team with the biggest bill.

## Setup (done before the talk)

### 1. Download (once, with internet)

Manifests, Helm charts and every image the demo runs go to `offline/` (about 600 MB, not in git).

```sh
mkdir -p offline/charts
curl -fsSL -o offline/gateway-api.yaml https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.0/standard-install.yaml
curl -fsSL -o offline/cert-manager.yaml https://github.com/cert-manager/cert-manager/releases/download/v1.20.2/cert-manager.yaml
curl -fsSL -o offline/inference-extension.yaml https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/v1.5.0/manifests.yaml
for c in kserve-llmisvc-crd kserve-llmisvc-resources kserve-runtime-configs; do
  helm pull oci://ghcr.io/kserve/charts/$c --version v0.20.0-rc0 -d offline/charts
done
for c in agentgateway-crds agentgateway; do
  helm pull oci://cr.agentgateway.dev/charts/$c --version v1.4.1 -d offline/charts
done

images=(
  quay.io/jetstack/cert-manager-controller:v1.20.2
  quay.io/jetstack/cert-manager-cainjector:v1.20.2
  quay.io/jetstack/cert-manager-webhook:v1.20.2
  kserve/llmisvc-controller:v0.20.0-rc0
  cr.agentgateway.dev/controller:v1.4.1
  cr.agentgateway.dev/agentgateway:v1.4.1
  ghcr.io/llm-d/llm-d-inference-sim:v0.9.0-rc3
  ghcr.io/llm-d/llm-d-router-endpoint-picker:v0.9.0
  envoyproxy/ratelimit:5ae0682e
  redis:7-alpine
  curlimages/curl:8.11.1
)
platform=linux/$(docker info --format '{{.Architecture}}' | sed 's/aarch64/arm64/; s/x86_64/amd64/')
for i in kindest/node:v1.35.0 "${images[@]}"; do docker pull -q --platform "$platform" "$i"; done
docker save --platform "$platform" -o offline/kind-node.tar kindest/node:v1.35.0
docker save --platform "$platform" -o offline/images.tar "${images[@]}"
```

If a registry answers `502`, run the block again.

### 2. Install (no internet needed)

As in the [agentgateway KServe guide](https://agentgateway.dev/docs/kubernetes/latest/integrations/llm/routing/kserve/),
but from `offline/`.

```sh
# kind cluster, all images loaded before anything starts
docker image inspect kindest/node:v1.35.0 >/dev/null 2>&1 || docker load -i offline/kind-node.tar
kind create cluster --name kubecon --config kind-config.yaml
kind load image-archive offline/images.tar --name kubecon

# Gateway API CRDs and cert-manager (KServe uses it for webhook certificates)
kubectl apply --server-side -f offline/gateway-api.yaml
kubectl apply -f offline/cert-manager.yaml
kubectl wait --for=condition=available deployment --all --namespace cert-manager --timeout=180s

# KServe, with its LLMInferenceService controller on a shared agentgateway Gateway
kubectl create namespace kserve
helm upgrade -i kserve-llmisvc-crd offline/charts/kserve-llmisvc-crd-v0.20.0-rc0.tgz \
  --namespace kserve
helm upgrade -i kserve-llmisvc-resources offline/charts/kserve-llmisvc-resources-v0.20.0-rc0.tgz \
  --namespace kserve \
  --set kserve.llmisvc.controller.imagePullPolicy=IfNotPresent \
  --set kserve.controller.deploymentMode=Standard \
  --set kserve.controller.gateway.ingressGateway.enableGatewayApi=true \
  --set kserve.controller.gateway.ingressGateway.createGateway=false \
  --set kserve.controller.gateway.ingressGateway.kserveGateway=kserve/kserve-ingress-gateway \
  --set kserve.controller.gateway.ingressGateway.className=agentgateway \
  --set kserve.controller.gateway.disableIstioVirtualHost=true \
  --set kserve.controller.gateway.disableIngressCreation=false \
  --set kserve.controller.knativeAddressableResolver.enabled=false \
  --set kserve.controller.gateway.localGateway.gateway="" \
  --set kserve.controller.gateway.localGateway.gatewayService=""
kubectl rollout status deployment/llmisvc-controller-manager --namespace kserve --timeout=240s
# repeats until the KServe webhook answers, a few seconds after the rollout
until helm upgrade -i kserve-runtime-configs offline/charts/kserve-runtime-configs-v0.20.0-rc0.tgz \
  --namespace kserve --force-conflicts \
  --set kserve.llmisvcConfigs.enabled=true; do sleep 5; done

# Inference Extension CRDs (after KServe, so the transitional CRDs stay)
kubectl apply --server-side -f offline/inference-extension.yaml

# agentgateway with Inference Extension support
helm upgrade -i agentgateway-crds offline/charts/agentgateway-crds-v1.4.1.tgz \
  --create-namespace --namespace agentgateway-system
helm upgrade -i agentgateway offline/charts/agentgateway-v1.4.1.tgz \
  --namespace agentgateway-system --set inferenceExtension.enabled=true

# Gateway, price list, rate limit service, apps namespace, localhost:8080
kubectl apply -f 00-prepare.yaml
kubectl wait --for=condition=Programmed gateway/kserve-ingress-gateway --namespace kserve --timeout=180s
kubectl rollout status deployment/kserve-ingress-gateway --namespace kserve --timeout=180s
kubectl rollout status deployment/ratelimit --namespace ratelimit --timeout=120s
```

- `localhost:8080` goes straight to the gateway (`kind-config.yaml`), no port-forward needed.
- `imagePullPolicy=IfNotPresent`: with the chart's default `Always`, the KServe controller
  doesn't start again without internet.
- `--force-conflicts`: without it a second install fails, because KServe rewrites the CPU values.
- Don't install the llm-d Router chart: KServe owns the endpoint picker.

### 3. Team tokens

One signed JWT per team in `tokens/`, the public key in `tokens/03-teams.yaml`, the two in-cluster
tokens as a Secret. Paste the block as a whole; reruns keep the key.

```sh
mkdir -p tokens
[ -f tokens/key.pem ] || openssl genrsa -out tokens/key.pem 2048
b64() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

head=$(printf '{"alg":"RS256","typ":"JWT","kid":"demo"}' | b64)
for t in support:customer-chatbot ml-research:prompt-experiments data:nightly-summaries platform:code-review-agent; do
  body=$(printf '{"iss":"kubecon-demo","team":"%s","sub":"%s","exp":%d}' "${t%:*}" "${t#*:}" $(($(date +%s) + 180*86400)) | b64)
  printf '%s' "$head.$body.$(printf '%s' "$head.$body" | openssl dgst -sha256 -sign tokens/key.pem | b64)" > "tokens/${t%:*}.jwt"
done

# Public key as JWKS: the 256 modulus bytes sit at offset 33 of a 2048-bit key in DER.
n=$(openssl rsa -in tokens/key.pem -pubout -outform DER 2>/dev/null | tail -c +34 | head -c 256 | b64)
sed "/inline:/s|__JWKS__|{\"keys\":[{\"kty\":\"RSA\",\"alg\":\"RS256\",\"kid\":\"demo\",\"n\":\"$n\",\"e\":\"AQAB\"}]}|" 03-teams.yaml > tokens/03-teams.yaml

kubectl create secret generic team-tokens -n apps --from-file=data=tokens/data.jwt \
  --from-file=platform=tokens/platform.jwt --dry-run=client -o yaml | kubectl apply -f -
```

Rehearse the demo once with Wi-Fi off, then [reset](#reset).

## Demo

| Script | What it does |
|---|---|
| `traffic.sh` | Four teams send traffic, two from outside the cluster, two from inside |
| `cost-by-team.sh` | Requests, tokens and cost per team, from the gateway log |
| `chat.sh` | One prompt as one team; `--loop` sends five big prompts |

### 1. Deploy the model

One file. KServe creates route, pool, endpoint picker and pods.

```sh
kubectl apply -f 01-model.yaml
kubectl wait --for=condition=Ready llminferenceservice/mock-llm -n kserve-test --timeout=300s
kubectl get llminferenceservice,httproute,inferencepool,pods -n kserve-test
```

### 2. Call it: 200, but blind

```sh
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/kserve-test/mock-llm/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"mock-llm","messages":[{"role":"user","content":"Hello"}]}'
```

```sh
kubectl logs -n kserve deploy/kserve-ingress-gateway --tail 20 | grep 'http.status=' | tail -1 \
  | grep -oE '(http.status|protocol|gen_ai[a-z_.]+)=[^ ]+'
```

`http.status=200` and `protocol=http`, nothing about model or tokens.

### 3. Flip the switch

Same request, new path `/v1/chat/completions`. KServe needs a few seconds to rewrite the route;
a `404` means: send it again.

```sh
kubectl apply -f 02-llm-backend.yaml
```

```sh
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"mock-llm","messages":[{"role":"user","content":"Hello"}]}'
```

```sh
kubectl logs -n kserve deploy/kserve-ingress-gateway --tail 20 | grep 'http.status=' | tail -1 \
  | grep -oE '(http.status|protocol|gen_ai[a-z_.]+)=[^ ]+'
```

Now `protocol=llm`, the model and the input and output tokens.

### 4. Four teams send traffic

A JWT per team, the team in every log line.

```sh
kubectl apply -f tokens/03-teams.yaml -f 04-controls.yaml
```

```sh
./traffic.sh
```

```sh
./cost-by-team.sh
```

The nightly summaries send the most requests, ML research uses the most tokens.

### 5. Guardrail and budget

```sh
./chat.sh support 'my card is 4111 1111 1111 1111'  # 403 Request contains PII
```

```sh
./chat.sh ml-research --loop  # 200 200 429 429 429
```

```sh
./chat.sh support 'hello again'  # 200
```

### 6. Failover without a surprise bill

A second priority group on the same backend: a paid cloud API, only used when our model is
down. The "cloud API" is a second simulator in the cluster, $2.50 / $10.00 per 1M tokens
instead of $0.40.

```sh
kubectl apply -f 05-failover.yaml
kubectl rollout status deploy/cloud-llm -n kserve-test
./chat.sh support hello
```

Outage: our model goes away. Repeats until the cloud answers.

```sh
kubectl patch llminferenceservice mock-llm -n kserve-test --type merge -p '{"spec":{"replicas":0}}'
until ./chat.sh support hello | tee /dev/stderr | grep -q cloud-llm; do sleep 1; done
```

Same prompt, before and after:

```sh
kubectl logs -n kserve deploy/kserve-ingress-gateway --tail 50 | grep 'http.status=200' | tail -2 \
  | grep -oE '(gen_ai.response.model|agw.ai.usage.cost.total)=[^ ]+' | paste - -
```

Nine times the price, and the log says exactly which model answered.

---

### Reset

```sh
kubectl delete namespace kserve-test
kubectl delete agentgatewaypolicy team-access-log -n kserve
kubectl exec -n ratelimit deploy/redis -- redis-cli FLUSHALL
```

### Cleanup

```sh
kind delete cluster --name kubecon
```

## Links

- agentgateway + KServe: <https://agentgateway.dev/docs/kubernetes/latest/integrations/llm/routing/kserve/>
