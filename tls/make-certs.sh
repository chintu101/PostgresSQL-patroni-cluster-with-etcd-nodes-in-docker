#!/usr/bin/env bash
# Creates the lab CA and the server certificates inside a throwaway container, straight into the
# Docker volume pg-lab-tls, so private keys never land on the host disk.
#   bash tls/make-certs.sh          # create what is missing (existing CA and certs are kept)
#   RENEW=1 bash tls/make-certs.sh  # reissue the server certs (same CA); restart the services afterwards
# Volume layout (each service mounts only its own folder, read-only, at /tls):
#   ca/ca.key  ca/ca.crt                       root only; never mounted
#   pg1 ... pg5/{server.key,server.crt,ca.crt}  owned by uid 999 (postgres in the Patroni image)
#   pgbouncer/{server.key,server.crt,ca.crt}    owned by uid 100 (postgres in the PgBouncer image)
# Only the public CA certificate is copied out, to tls/ca.crt (git-ignored).
set -euo pipefail
cd "$(dirname "$0")/.."
VOLUME=pg-lab-tls
IMAGE=pg-lab-patroni   # has OpenSSL already; nothing is downloaded

docker volume inspect "$VOLUME" >/dev/null 2>&1 || docker volume create "$VOLUME" >/dev/null

docker run --rm -i --network none --user root --entrypoint bash -e RENEW="${RENEW:-0}" \
  -v "$VOLUME":/tls "$IMAGE" -s <<'EOF'
set -euo pipefail
umask 077
cd /tls
if [ ! -f ca/ca.key ]; then
  mkdir -p ca
  openssl req -x509 -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -sha256 -days 3650 \
    -keyout ca/ca.key -out ca/ca.crt -subj "/CN=pg-lab CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
  chmod 0644 ca/ca.crt
  echo "CA created"
else
  echo "CA exists, kept"
fi

issue() {  # issue <name> <uid> <gid> <subjectAltName>
  local name=$1 uid=$2 gid=$3 sans=$4
  if [ -f "$name/server.crt" ] && [ "$RENEW" != 1 ]; then echo "$name: exists, kept"; return; fi
  mkdir -p "$name"
  openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout "$name/server.key" -out "$name/server.csr" -subj "/CN=$name" 2>/dev/null
  printf '%s\n' "basicConstraints=critical,CA:FALSE" "keyUsage=critical,digitalSignature" \
    "extendedKeyUsage=serverAuth" "subjectAltName=$sans" > "$name/ext.cnf"
  openssl x509 -req -sha256 -days 825 -in "$name/server.csr" -CA ca/ca.crt -CAkey ca/ca.key \
    -set_serial "0x$(openssl rand -hex 16)" -extfile "$name/ext.cnf" -out "$name/server.crt" 2>/dev/null
  rm -f "$name/server.csr" "$name/ext.cnf"
  cp ca/ca.crt "$name/ca.crt"
  chown -R "$uid:$gid" "$name"
  chmod 0755 "$name"; chmod 0644 "$name/server.crt" "$name/ca.crt"; chmod 0600 "$name/server.key"
  echo "$name: issued"
}

for n in pg1 pg2 pg3 pg4 pg5; do
  issue "$n" 999 999 "DNS:$n,DNS:haproxy,DNS:localhost,IP:127.0.0.1"
done
issue pgbouncer 100 102 "DNS:pgbouncer,DNS:localhost,IP:127.0.0.1"

for n in pg1 pg2 pg3 pg4 pg5 pgbouncer; do
  openssl verify -CAfile ca/ca.crt "$n/server.crt" >/dev/null
  printf '%-10s %s | %s\n' "$n" "$(openssl x509 -in "$n/server.crt" -noout -ext subjectAltName | tail -1 | sed 's/^ *//')" \
    "$(openssl x509 -in "$n/server.crt" -noout -enddate)"
done
EOF

mkdir -p tls
docker run --rm --network none --user root --entrypoint cat -v "$VOLUME":/tls:ro "$IMAGE" /tls/ca/ca.crt > tls/ca.crt
echo "CA certificate copied to tls/ca.crt"
