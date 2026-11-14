#!/bin/sh
# Writes the auth file from the environment (only the auth user is listed; every other user's
# password is looked up in PostgreSQL with auth_query), then starts PgBouncer.
set -e
umask 077
printf '"postgres" "%s"\n' "$POSTGRES_PASSWORD" > /tmp/userlist.txt
exec pgbouncer /etc/pgbouncer/pgbouncer.ini
