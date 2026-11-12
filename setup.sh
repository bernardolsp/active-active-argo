#!/usr/bin/env bash
set -euo pipefail
umask 077

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
lab_name=${LAB_NAME:-active-active-argo}
if [[ ! $lab_name =~ ^[a-z][a-z0-9-]{0,40}$ || $lab_name == *- ]]; then
    printf 'LAB_NAME deve ter até 41 letras minúsculas, números ou hífens.\n' >&2
    exit 1
fi

state="$root/.lab/$lab_name"
export KUBECONFIG="$state/kubeconfig"
argo_version=${ARGOCD_VERSION:-v3.6.1}
node_image=${KIND_NODE_IMAGE:-kindest/node:v1.35.0}
wait_seconds=${WAIT_SECONDS:-480}
drain_seconds=${DRAIN_SECONDS:-5}
app_namespace=active-active-argo
gateway="$lab_name-gateway"
gateway_image=active-active-argo-gateway:local
east=(kubectl --context "kind-$lab_name-east")
west=(kubectl --context "kind-$lab_name-west")

fail() { printf 'Erro: %s\n' "$*" >&2; exit 1; }

check_command() {
    command -v "$1" >/dev/null 2>&1 || fail "comando necessário: $1"
}

lock_lab() {
    mkdir -p "$state"
    mkdir "$state/lock" 2>/dev/null || fail "operação concorrente em $state/lock"
    trap 'rmdir "$state/lock"' EXIT
}

cluster_exists() {
    local name=$1
    kind get clusters 2>/dev/null | grep -Fxq "$name"
}

create_cluster() {
    local name="$lab_name-$1"
    if cluster_exists "$name"; then
        [[ -f $state/$1-owned ]] || fail "já existe um cluster Kind chamado $name; escolha outro LAB_NAME"
        kind export kubeconfig --name "$name" --kubeconfig "$KUBECONFIG"
    else
        kind create cluster --name "$name" --image "$node_image" --kubeconfig "$KUBECONFIG" --wait 180s
        : > "$state/$1-owned"
    fi
}

node_ip() {
    docker inspect --format '{{(index .NetworkSettings.Networks "kind").IPAddress}}' "$lab_name-$1-control-plane"
}

gateway_ip() {
    docker inspect --format '{{(index .NetworkSettings.Networks "kind").IPAddress}}' "$gateway"
}

gateway_url() {
    local address
    address=$(docker port "$gateway" 8080/tcp)
    [[ $address == 127.0.0.1:* ]] || fail "gateway sem porta IPv4 em loopback"
    printf 'http://%s\n' "$address"
}

start_gateway() {
    local east_ip west_ip owner image_id
    east_ip=$(node_ip east)
    west_ip=$(node_ip west)
    docker build -t "$gateway_image" "$root/lab"
    image_id=$(docker image inspect --format '{{.Id}}' "$gateway_image")
    if docker inspect "$gateway" >/dev/null 2>&1; then
        owner=$(docker inspect --format '{{index .Config.Labels "lab.active-active-argo.owner"}}' "$gateway")
        [[ $owner == "$state" ]] || fail "já existe um container chamado $gateway; escolha outro LAB_NAME"
        if [[ $(docker inspect --format '{{.Image}}' "$gateway") != "$image_id" ||
              $(docker inspect --format '{{join .Config.Cmd " "}}' "$gateway") != "python /usr/local/bin/lab-gateway.py http://$east_ip:30080 http://$west_ip:30080" ]]; then
            docker rm -f "$gateway" >/dev/null
        else
            docker start "$gateway" >/dev/null
            return
        fi
    fi
    docker run --detach --name "$gateway" --network kind \
        --label "lab.active-active-argo.owner=$state" \
        --publish 127.0.0.1::8080 \
        --mount "type=bind,source=$state/token,target=/lab/token,readonly" \
        --mount "type=bind,source=$state/git,target=/lab/git,readonly" \
        "$gateway_image" python /usr/local/bin/lab-gateway.py "http://$east_ip:30080" "http://$west_ip:30080" >/dev/null
}

publish_snapshot() {
    local snapshot revision
    mkdir -p "$state/git"
    if [[ ! -d $state/git/lab.git ]]; then
        git init -q --bare --initial-branch=main "$state/git/lab.git"
    fi
    snapshot=$(mktemp -d "$state/snapshot.XXXXXX")
    (
        trap 'rm -rf -- "$snapshot"' EXIT
        git init -q --initial-branch=main "$snapshot"
        if git --git-dir="$state/git/lab.git" rev-parse --verify main >/dev/null 2>&1; then
            git -C "$snapshot" pull -q "$state/git/lab.git" main
        fi
        rm -rf -- "$snapshot/app-default"
        cp -R "$root/app-default" "$snapshot/app-default"
        git -C "$snapshot" add -A
        if ! git -C "$snapshot" diff --cached --quiet; then
            git -C "$snapshot" -c user.name='Active-active Kind lab' -c user.email='kind-lab@localhost' \
                -c commit.gpgsign=false commit -qm 'Atualiza o chart da demonstração'
            git -C "$snapshot" push -q "$state/git/lab.git" HEAD:main
        fi
        git --git-dir="$state/git/lab.git" update-server-info
        revision=$(git --git-dir="$state/git/lab.git" rev-parse --short main)
        printf 'Revisão publicada no Git local: %s\n' "$revision"
    )
}

apply_argocd() {
    local region=$1 manifest=$2
    local k=(kubectl --context "kind-$lab_name-$region")
    "${k[@]}" create namespace argocd --dry-run=client -o yaml | "${k[@]}" apply -f -
    "${k[@]}" apply -n argocd --server-side --force-conflicts -f "$manifest"
    "${k[@]}" create namespace "$app_namespace" --dry-run=client -o yaml | "${k[@]}" apply -f -
    "${k[@]}" -n "$app_namespace" create secret generic lab-gateway --from-file="token=$state/token" \
        --dry-run=client -o yaml | "${k[@]}" apply --server-side -f -
}

register_west() {
    local token ca server config
    "${west[@]}" apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: lab-argocd
  namespace: $app_namespace
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: lab-argocd
  namespace: $app_namespace
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: admin
subjects:
  - kind: ServiceAccount
    name: lab-argocd
    namespace: $app_namespace
---
apiVersion: v1
kind: Secret
metadata:
  name: lab-argocd-token
  namespace: $app_namespace
  annotations:
    kubernetes.io/service-account.name: lab-argocd
type: kubernetes.io/service-account-token
EOF

    for _ in {1..30}; do
        token=$("${west[@]}" -n "$app_namespace" get secret lab-argocd-token -o jsonpath='{.data.token}')
        [[ -z $token ]] || break
        sleep 1
    done
    [[ -n $token ]] || fail "Kubernetes não gerou o token do cluster west"
    token=$(printf '%s' "$token" | decode64)
    ca=$("${west[@]}" config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
    [[ -n $ca ]] || fail "CA do Kind west não encontrada"
    server="https://$(node_ip west):6443"
    config=$(printf '{"bearerToken":"%s","tlsClientConfig":{"insecure":false,"caData":"%s","serverName":"kubernetes.default.svc"}}' "$token" "$ca")
    "${east[@]}" -n argocd apply --server-side -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: lab-west
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
data:
  name: $(printf lab-west | encode64)
  server: $(printf '%s' "$server" | encode64)
  namespaces: $(printf '%s' "$app_namespace" | encode64)
  config: $(printf '%s' "$config" | encode64)
EOF
}

encode64() { base64 | tr -d '\r\n'; }
decode64() { base64 -d; }

configure_east_argocd() {
    local flag polling
    "${east[@]}" -n argocd patch configmap argocd-cm --type merge \
        -p '{"data":{"resource.respectRBAC":"normal"}}'
    polling=$("${east[@]}" -n argocd get configmap argocd-cm \
        -o 'jsonpath={.data.timeout\.reconciliation}{"/"}{.data.timeout\.reconciliation\.jitter}{"/"}{.data.timeout\.hard\.reconciliation}')
    if [[ $polling != 0s/0s/0s ]]; then
        "${east[@]}" -n argocd patch configmap argocd-cm --type merge \
            -p '{"data":{"timeout.reconciliation":"0s","timeout.reconciliation.jitter":"0s","timeout.hard.reconciliation":"0s"}}'
        "${east[@]}" -n argocd rollout restart deployment/argocd-repo-server statefulset/argocd-application-controller
    fi
    flag=$("${east[@]}" -n argocd get configmap argocd-cmd-params-cm \
        -o 'jsonpath={.data.applicationsetcontroller\.enable\.progressive\.syncs}')
    if [[ $flag != true ]]; then
        "${east[@]}" -n argocd patch configmap argocd-cmd-params-cm --type merge \
            -p '{"data":{"applicationsetcontroller.enable.progressive.syncs":"true"}}'
        "${east[@]}" -n argocd rollout restart deployment/argocd-applicationset-controller
    fi
}

wait_argocd() {
    local region=$1
    local k=(kubectl --context "kind-$lab_name-$region")
    "${k[@]}" -n argocd rollout status deployment/argocd-server --timeout=240s
    "${k[@]}" -n argocd rollout status deployment/argocd-repo-server --timeout=240s
    "${k[@]}" -n argocd rollout status deployment/argocd-applicationset-controller --timeout=240s
    "${k[@]}" -n argocd rollout status statefulset/argocd-application-controller --timeout=240s
}

yaml_value() {
    local value=$1
    value=${value//\'/\'\'}
    printf "'%s'" "$value" | sed 's/[&|\\]/\\&/g'
}

apply_appset() {
    local repo=$1 ref=$2 endpoint=$3
    sed -e "s|__REPO_URL__|$(yaml_value "$repo")|" \
        -e "s|__GIT_REF__|$(yaml_value "$ref")|" \
        -e "s|__GATEWAY_URL__|$(yaml_value "$endpoint")|" \
        -e "s|__DRAIN_SECONDS__|$drain_seconds|" "$root/lab/applicationset.yaml" |
        "${east[@]}" apply -f -
}

wait_for_apps() {
    local repo=$1 ref=$2 revision=${3:-*}
    local deadline=$((SECONDS + wait_seconds)) east_status west_status
    local expected_source="$repo"$'\t'"$ref"$'\t'
    local output='{.status.sync.comparedTo.source.repoURL}{"\t"}{.status.sync.comparedTo.source.targetRevision}{"\t"}{.status.sync.revision}{"\t"}{.status.sync.status}/{.status.health.status}/{.status.operationState.phase}/{.operation.sync.revision}'
    printf 'Aguardando o RollingSync dos dois clusters…\n'
    while (( SECONDS < deadline )); do
        east_status=$("${east[@]}" -n argocd get application app-east --ignore-not-found -o "jsonpath=$output")
        west_status=$("${east[@]}" -n argocd get application app-west --ignore-not-found -o "jsonpath=$output")
        if [[ $east_status == "$expected_source"$revision$'\tSynced/Healthy/Succeeded/' &&
              $west_status == "$expected_source"$revision$'\tSynced/Healthy/Succeeded/' ]]; then
            return
        fi
        sleep 3
    done
    "${east[@]}" -n argocd get applications
    fail "rollout ainda não concluído; use ./setup.sh status e consulte os logs dos hooks"
}

show_status() {
    local url
    "${east[@]}" -n argocd get applications
    url=$(gateway_url)
    printf 'Gateway: %s\n' "$url"
    curl -fsS --max-time 5 "$url/_lab/status"
}

setup() {
    local manifest="$state/install-$argo_version.yaml" endpoint repo ref revision=
    [[ $argo_version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "ARGOCD_VERSION inválido"
    [[ $drain_seconds =~ ^([0-9]|[1-5][0-9]|60)$ ]] || fail "DRAIN_SECONDS deve estar entre 0 e 60"
    [[ $wait_seconds =~ ^[1-9][0-9]*$ ]] || fail "WAIT_SECONDS deve ser um inteiro positivo"
    if [[ ! -s $manifest ]]; then
        curl --fail --silent --show-error --location --retry 2 \
            "https://raw.githubusercontent.com/argoproj/argo-cd/$argo_version/manifests/install.yaml" -o "$manifest.tmp"
        mv "$manifest.tmp" "$manifest"
    fi
    if [[ ! -s $state/token ]]; then
        LC_ALL=C od -An -tx1 -N24 /dev/urandom | tr -d ' \n' > "$state/token"
    fi
    create_cluster east
    create_cluster west
    mkdir -p "$state/git"
    start_gateway
    endpoint="http://$(gateway_ip):8080"
    repo=${REPO_URL:-}
    if [[ -n $repo ]]; then
        [[ $repo == https://* || $repo == http://* ]] || fail "REPO_URL precisa usar HTTP ou HTTPS"
        ref=${GIT_REF:-HEAD}
    else
        repo="$endpoint/git/lab.git"
        ref=main
        if ! git --git-dir="$state/git/lab.git" rev-parse --verify refs/heads/main >/dev/null 2>&1; then
            publish_snapshot
            revision=$(git --git-dir="$state/git/lab.git" rev-parse refs/heads/main)
        fi
    fi
    [[ $repo != *$'\n'* && $ref != *$'\n'* && $repo != *$'\r'* && $ref != *$'\r'* ]] ||
        fail "REPO_URL e GIT_REF não podem conter quebras de linha"
    apply_argocd east "$manifest"
    apply_argocd west "$manifest"
    register_west
    configure_east_argocd
    wait_argocd east
    wait_argocd west
    apply_appset "$repo" "$ref" "$endpoint"
    wait_for_apps "$repo" "$ref" "$revision"
    printf '%s\n' "$repo" > "$state/repo"
    printf '%s\n' "$ref" > "$state/ref"
    show_status
    printf 'Interface do Argo CD: ./setup.sh ui east  ou  ./setup.sh ui west\n'
}

cleanup() {
    local region
    if docker inspect "$gateway" >/dev/null 2>&1 &&
        [[ $(docker inspect --format '{{index .Config.Labels "lab.active-active-argo.owner"}}' "$gateway") == "$state" ]]; then
        docker rm -f "$gateway" >/dev/null
    fi
    for region in east west; do
        if [[ -f $state/$region-owned ]]; then
            kind delete cluster --name "$lab_name-$region" --kubeconfig "$KUBECONFIG"
            rm -f -- "$state/$region-owned"
        fi
    done
    rm -f -- "$KUBECONFIG" "$state/token" "$state/repo" "$state/ref"
    rm -rf -- "$state/git"
}

use_region() {
    [[ $1 == east || $1 == west ]] || fail "use east ou west"
    [[ -s $KUBECONFIG ]] || fail "execute ./setup.sh primeiro"
}

case "${1:-up}" in
    up)
        for cmd in docker kind kubectl git curl; do check_command "$cmd"; done
        docker info >/dev/null 2>&1 || fail "inicie o Docker e confira o contexto ativo"
        lock_lab
        setup
        ;;
    publish)
        lock_lab
        [[ -s $state/repo && $(cat "$state/repo") == */git/lab.git ]] ||
            fail "publish requer o laboratório configurado com Git local"
        publish_snapshot
        ;;
    status) show_status ;;
    url) gateway_url ;;
    ui)
        region=${2:-east}
        use_region "$region"
        exec kubectl --context "kind-$lab_name-$region" -n argocd port-forward --address 127.0.0.1 svc/argocd-server :443
        ;;
    password)
        region=${2:-east}
        use_region "$region"
        kubectl --context "kind-$lab_name-$region" -n argocd get secret argocd-initial-admin-secret \
            -o jsonpath='{.data.password}' | decode64
        printf '\n'
        ;;
    down)
        [[ -d $state ]] || exit 0
        docker info >/dev/null 2>&1 || fail "inicie o Docker para remover o laboratório"
        lock_lab
        cleanup
        ;;
    *) fail "uso: ./setup.sh [up|publish|status|url|ui [east|west]|password [east|west]|down]" ;;
esac
