#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(dirname "$script_dir")
cd "$project_dir"

env_file=${ENV_FILE:-.env}
if [ ! -f "$env_file" ]; then
  echo "Missing $env_file. Run ./scripts/bootstrap-production-env.sh first." >&2
  exit 1
fi
if [ ! -e .env ] && [ ! -L .env ] && [ "$env_file" != ".env" ]; then
  case "$env_file" in
    /*) env_link=$env_file ;;
    *) env_link=$(CDPATH= cd -- "$(dirname -- "$env_file")" && pwd)/$(basename -- "$env_file") ;;
  esac
  ln -s "$env_link" .env
fi
if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required" >&2
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  echo "Docker daemon access failed. Run this script with an account allowed to use Docker." >&2
  exit 1
fi

compose() {
  docker compose --env-file "$env_file" "$@"
}

docker compose --env-file "$env_file" config --quiet
docker compose --env-file "$env_file" up -d --build

attempt=0
api_healthy=false
while [ "$attempt" -lt 45 ]; do
  if compose exec -T api node -e \
    "fetch('http://127.0.0.1:8080/api/v1/health').then((response)=>process.exit(response.ok?0:1)).catch(()=>process.exit(1))" \
    >/dev/null 2>&1; then
    api_healthy=true
    break
  fi
  attempt=$((attempt + 1))
  sleep 2
done

if [ "$api_healthy" != true ]; then
  compose logs --tail=200 api worker web
  echo "API health check did not become ready" >&2
  exit 1
fi

if ! compose exec -T web wget -qO- http://127.0.0.1/ >/dev/null 2>&1; then
  compose logs --tail=200 web
  echo "Web health check failed" >&2
  exit 1
fi

docker compose --env-file "$env_file" ps
echo "Production deployment is healthy."
echo "API health endpoint: /api/v1/health"
