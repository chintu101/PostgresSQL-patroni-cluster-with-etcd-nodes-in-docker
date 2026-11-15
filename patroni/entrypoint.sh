#!/bin/bash
set -e

cat > /tmp/patroni.yml <<YAML
scope: pg-lab
name: ${NODE_NAME}

restapi:
  listen: 0.0.0.0:8008
  connect_address: ${NODE_NAME}:8008

etcd3:
  hosts: etcd1:2379,etcd2:2379,etcd3:2379

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: true
      parameters:
        max_connections: 100
  initdb:
    - encoding: UTF8
    - data-checksums
  pg_hba:
    - host replication replicator all md5
    - host all all all md5
  users:
    admin:
      password: admin
      options: [createrole, createdb]

postgresql:
  listen: 0.0.0.0:5432
  connect_address: ${NODE_NAME}:5432
  data_dir: /var/lib/postgresql/data/pgdata
  bin_dir: /usr/lib/postgresql/16/bin
  authentication:
    # Superuser (Patroni, pg_rewind) and replication connections between nodes; TLS mode from compose.
    superuser:
      username: postgres
      password: ${POSTGRES_PASSWORD}
      sslmode: ${PG_TLS_SSLMODE:-prefer}
      sslrootcert: /tls/ca.crt
    replication:
      username: replicator
      password: ${REPLICATION_PASSWORD}
      sslmode: ${PG_TLS_SSLMODE:-prefer}
      sslrootcert: /tls/ca.crt
  parameters:
    unix_socket_directories: '/tmp'
    # Certificates from the pg-lab-tls volume (tls/make-certs.sh), mounted read-only at /tls.
    ssl: 'on'
    ssl_cert_file: /tls/server.crt
    ssl_key_file: /tls/server.key
  # Written to pg_hba.conf by Patroni on every start. Loopback stays trust (Patroni, hooks);
  # network connections use the type and method from compose (phase 2: hostssl, scram-sha-256).
  pg_hba:
    - local all all trust
    - host all all 127.0.0.1/32 trust
    - host all all ::1/128 trust
    - local replication all trust
    - host replication all 127.0.0.1/32 trust
    - host replication all ::1/128 trust
    - ${PG_HBA_TYPE:-host} replication replicator all ${PG_HBA_METHOD:-md5}
    - ${PG_HBA_TYPE:-host} all all all ${PG_HBA_METHOD:-md5}
  # Hooks that pause/resume PgBouncer and switch HAProxy at once on a planned leader change.
  before_stop: /opt/patroni/bin/python /usr/local/bin/patroni_hooks.py before_stop
  callbacks:
    on_role_change: /opt/patroni/bin/python /usr/local/bin/patroni_hooks.py
    on_start: /opt/patroni/bin/python /usr/local/bin/patroni_hooks.py
    on_restart: /opt/patroni/bin/python /usr/local/bin/patroni_hooks.py
YAML

exec /opt/patroni/bin/patroni /tmp/patroni.yml
