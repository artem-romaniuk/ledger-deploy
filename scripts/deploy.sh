#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

services=(api web)

usage() {
    cat <<'EOF'
usage: deploy.sh [tag] [service=tag ...]

  deploy.sh                          every image on the tag from .env
  deploy.sh sha-1a2b3c4              every image on sha-1a2b3c4
  deploy.sh api=sha-1a2b3c4          only api, everything else from .env
  deploy.sh sha-1a2b3c4 web=latest   everything on sha-1a2b3c4 except web

services: api (api, migrate), web
EOF
}

die() { echo "deploy.sh: $*" >&2; exit 1; }

valid_tag() { [[ $1 =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$ ]]; }

all_tag=""
declare -A service_tag=()

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            usage >&2
            die "unknown option '$arg'"
            ;;
        *=*)
            name=${arg%%=*}
            tag=${arg#*=}
            [[ " ${services[*]} " == *" $name "* ]] || die "unknown service '$name' — known: ${services[*]}"
            valid_tag "$tag" || die "'$tag' is not a valid image tag"
            service_tag[$name]=$tag
            ;;
        *)
            [ -z "$all_tag" ] || die "two tags for every service: '$all_tag' and '$arg'"
            valid_tag "$arg" || die "'$arg' is not a valid image tag"
            all_tag=$arg
            ;;
    esac
done

for f in .env .app.env; do
    [ -f "$f" ] || die "deploy/$f is missing — copy $f.example and fill it in"
done

[ -n "$all_tag" ] && export LEDGER_TAG="$all_tag"
for name in "${services[@]}"; do
    tag=${service_tag[$name]:-$all_tag}
    [ -n "$tag" ] && export "LEDGER_${name^^}_TAG=$tag"
done

echo "images:"
docker compose config --images | sort -u | sed 's/^/  /'

docker network inspect ledger_edge > /dev/null 2>&1 || docker network create ledger_edge

docker compose pull
docker compose up -d --remove-orphans
docker image prune -f > /dev/null
docker compose ps
