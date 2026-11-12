#!/usr/bin/env bash
set -eu

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
url=$("$root/setup.sh" url)

while true; do
    result=$(curl -s --max-time 2 -o /dev/null \
        -w '%{http_code} %header{x-lab-region}' "$url/") || result='000 '
    code=${result%% *}
    region=${result#* }
    printf '%s  HTTP %s  região=%s\n' "$(date +%T)" "$code" "${region:--}"
    sleep 1
done
