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
    superuser:
      username: postgres
      password: ${POSTGRES_PASSWORD}
    replication:
      username: replicator
      password: ${REPLICATION_PASSWORD}
  parameters:
    unix_socket_directories: '/tmp'
  # Hooks that pause/resume PgBouncer and switch HAProxy at once on a planned leader change.
  before_stop: /opt/patroni/bin/python /usr/local/bin/patroni_hooks.py before_stop
  callbacks:
    on_role_change: /opt/patroni/bin/python /usr/local/bin/patroni_hooks.py
    on_start: /opt/patroni/bin/python /usr/local/bin/patroni_hooks.py
    on_restart: /opt/patroni/bin/python /usr/local/bin/patroni_hooks.py
YAML

exec /opt/patroni/bin/patroni /tmp/patroni.yml
