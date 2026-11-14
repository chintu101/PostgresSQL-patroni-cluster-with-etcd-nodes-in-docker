"""Patroni hooks: hold client queries in PgBouncer during a planned leader change.

before_stop (old leader, before Patroni stops PostgreSQL; Patroni waits for this):
    PAUSE PgBouncer (running transactions finish, new queries wait), then mark this node down in
    HAProxy's write pool, then start a watchdog.
on_role_change / on_start / on_restart, when this node is now the primary:
    mark this node up in HAProxy's write pool (others down), then RESUME PgBouncer.
watchdog: if PgBouncer is still paused while HAProxy has had a leader for 5 s, RESUME it.

Run by Patroni as: python patroni_hooks.py before_stop
                   python patroni_hooks.py <on_role_change|on_start|on_restart> <role> <cluster>
HAProxy's health checks remain the fallback; a failing hook never blocks Patroni.
"""
import os, socket, subprocess, sys, threading, time
import psycopg2

NODE = os.environ.get("NODE_NAME", "?")
PASSWORD = os.environ.get("POSTGRES_PASSWORD", "")
PGBOUNCER = (os.environ.get("PGBOUNCER_HOST", "pgbouncer"), 6432)
HAPROXY_API = (os.environ.get("HAPROXY_API_HOST", "haproxy"), 9999)
NODES = ["pg1", "pg2", "pg3", "pg4", "pg5"]
LOG = "/tmp/patroni-hooks.log"


def log(msg):
    line = f"{time.strftime('%Y-%m-%d %H:%M:%S')}.{int(time.time() * 1000) % 1000:03d} UTC patroni-hook[{NODE}] {msg}"
    print(line, file=sys.stderr, flush=True)
    try:
        with open(LOG, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


def haproxy(cmd):
    try:
        with socket.create_connection(HAPROXY_API, timeout=2) as s:
            s.sendall((cmd + "\n").encode())
            s.shutdown(socket.SHUT_WR)
            return s.recv(65536).decode().strip()
    except OSError as e:
        log(f"haproxy '{cmd}' failed: {e}")
        return None


def bouncer(cmd, timeout=5.0):
    """Run an admin command on PgBouncer; returns rows, or None on error/timeout."""
    result = {}

    def run():
        try:
            conn = psycopg2.connect(host=PGBOUNCER[0], port=PGBOUNCER[1], dbname="pgbouncer",
                                    user="postgres", password=PASSWORD, connect_timeout=3)
            conn.autocommit = True
            with conn.cursor() as cur:
                cur.execute(cmd)
                result["rows"] = cur.fetchall() if cur.description else []
                result["cols"] = [d[0] for d in cur.description] if cur.description else []
            conn.close()
        except Exception as e:
            result["error"] = str(e).strip().splitlines()[0]

    t = threading.Thread(target=run, daemon=True)
    t.start()
    t.join(timeout)
    if t.is_alive():
        log(f"pgbouncer {cmd} still running after {timeout}s; continuing")
        return None
    if "error" in result:
        log(f"pgbouncer {cmd}: {result['error']}")
        return None
    return result


def local_is_primary():
    try:
        conn = psycopg2.connect(host="127.0.0.1", port=5432, dbname="postgres", user="postgres",
                                password=PASSWORD, connect_timeout=2)
        with conn.cursor() as cur:
            cur.execute("SELECT NOT pg_is_in_recovery()")
            primary = cur.fetchone()[0]
        conn.close()
        return primary
    except Exception as e:
        log(f"local primary check failed: {str(e).strip().splitlines()[0]}")
        return False


def bouncer_paused():
    r = bouncer("SHOW DATABASES", timeout=3)
    if not r:
        return None
    i = r["cols"].index("paused")
    return any(row[i] for row in r["rows"])


def haproxy_has_leader():
    out = haproxy("show servers state primary") or ""
    # columns: be_id be_name srv_id srv_name srv_addr srv_op_state ... ; op_state 2 = running/UP
    return any(len(f) > 5 and f[1] == "primary" and f[5] == "2" for f in (l.split() for l in out.splitlines()))


def before_stop():
    if not local_is_primary():
        return  # replica stopping: nothing to do
    t0 = time.time()
    log("leader stopping: PAUSE pgbouncer")
    bouncer("PAUSE", timeout=10)
    log(f"pgbouncer paused after {time.time() - t0:.2f}s; marking primary/{NODE} down in haproxy")
    haproxy(f"set server primary/{NODE} health down")
    subprocess.Popen([sys.executable, os.path.abspath(__file__), "watchdog"], start_new_session=True,
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    log(f"before_stop done in {time.time() - t0:.2f}s")


def became_primary(action):
    log(f"{action}: this node is primary; haproxy primary/{NODE} up, others down; RESUME pgbouncer")
    for n in NODES:
        haproxy(f"set server primary/{n} health {'up' if n == NODE else 'down'}")
    r = bouncer("RESUME", timeout=5)
    log("pgbouncer resumed" if r is not None else "pgbouncer RESUME not applied (see above; likely not paused)")


def watchdog():
    leader_since = None
    for _ in range(120):  # up to ~60 s
        time.sleep(0.5)
        paused = bouncer_paused()
        if paused is False:
            return  # resumed normally
        if haproxy_has_leader():
            leader_since = leader_since or time.time()
            if paused and time.time() - leader_since >= 5:
                log("watchdog: haproxy has a leader but pgbouncer still paused after 5 s; RESUME")
                bouncer("RESUME", timeout=5)
                return
        else:
            leader_since = None
    log("watchdog: gave up after 60 s")


if __name__ == "__main__":
    action = sys.argv[1] if len(sys.argv) > 1 else ""
    role = sys.argv[2] if len(sys.argv) > 2 else ""
    try:
        if action == "before_stop":
            before_stop()
        elif action == "watchdog":
            watchdog()
        elif action in ("on_role_change", "on_start", "on_restart") and role in ("primary", "master"):
            became_primary(action)
    except Exception as e:  # never fail Patroni because of a hook
        log(f"{action} error: {e}")
    sys.exit(0)
