# PgBouncer from Debian's own package (no third-party image).
FROM debian:trixie-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends pgbouncer \
    && rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /usr/local/bin/entrypoint-pgbouncer.sh
RUN chmod +x /usr/local/bin/entrypoint-pgbouncer.sh
USER postgres
EXPOSE 6432
ENTRYPOINT ["/usr/local/bin/entrypoint-pgbouncer.sh"]
