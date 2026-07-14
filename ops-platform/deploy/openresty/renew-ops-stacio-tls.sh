#!/bin/sh
set -eu

lego_image=${LEGO_IMAGE:-goacme/lego@sha256:39e65153badce8c67fa16caed2f89ebb15db5747ffbbd502603ce0bbaf2ed218}
openresty_container=${OPENRESTY_CONTAINER:-1Panel-openresty-3cVK}
site_root=${SITE_ROOT:-/opt/1panel/www/sites/ops.stacio.cn}
domain=${DOMAIN:-ops.stacio.cn}
acme_email=${ACME_EMAIL:-acme@1paneldev.com}
dns_account_id=${DNS_ACCOUNT_ID:-3}
action=${1:-renew}

case "$action" in
  run|renew) ;;
  *)
    echo "Usage: $0 [run|renew]" >&2
    exit 2
    ;;
esac

credentials=$(
  python3 - "$dns_account_id" <<'PY'
import json
import shlex
import sqlite3
import sys

account_id = int(sys.argv[1])
database = sqlite3.connect("file:/opt/1panel/db/agent.db?mode=ro", uri=True)
row = database.execute(
    "select authorization from website_dns_accounts where id = ? and type = 'AliYun'",
    (account_id,),
).fetchone()
if not row:
    raise SystemExit(f"AliYun DNS account {account_id} was not found")
authorization = json.loads(row[0])
print("ALICLOUD_ACCESS_KEY=" + shlex.quote(authorization["accessKey"]))
print("ALICLOUD_SECRET_KEY=" + shlex.quote(authorization["secretKey"]))
PY
)
eval "$credentials"
export ALICLOUD_ACCESS_KEY ALICLOUD_SECRET_KEY

docker run --rm \
  -e ALICLOUD_ACCESS_KEY \
  -e ALICLOUD_SECRET_KEY \
  -v "$site_root/ssl:/var/lib/lego" \
  "$lego_image" \
  --path /var/lib/lego \
  --email "$acme_email" \
  --dns alidns \
  --dns.propagation-wait 45s \
  --key-type ec256 \
  --domains "$domain" \
  --accept-tos \
  "$action"

docker exec "$openresty_container" openresty -t
docker exec "$openresty_container" openresty -s reload
