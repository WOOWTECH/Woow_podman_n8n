#!/usr/bin/env python3
"""Isolated Podman queue smoke test; never touches the installed n8n containers.

Starts its own PostgreSQL, Valkey, n8n main/worker/webhook and two runner containers.
It requires the pinned images to be present locally. All test resources are removed.
"""

import json
import os
import pathlib
import secrets
import socket
import subprocess
import tempfile
import time
import urllib.request


ROOT = pathlib.Path(__file__).resolve().parents[1]
SUFFIX = secrets.token_hex(4)
PREFIX = f"n8nq{SUFFIX}"


def pinned_image(path):
    for line in (ROOT / "quadlet" / path).read_text(encoding="utf-8").splitlines():
        if line.startswith("Image="):
            return line.split("=", 1)[1]
    raise ValueError(f"Image= is missing from {path}")


N8N_IMAGE = pinned_image("n8n.container")
RUNNERS_IMAGE = pinned_image("optional/n8n-runners.container")
PG_IMAGE = pinned_image("n8n-postgres.container")
VALKEY_IMAGE = pinned_image("queue/n8n-valkey.container")
containers = []
volumes = []
secret_names = []
network = f"{PREFIX}-net"


def podman(*args, timeout=120):
    result = subprocess.run(
        ["podman", *args], capture_output=True, text=True, timeout=timeout, check=False
    )
    if result.returncode:
        raise RuntimeError(f"podman {args[0]} failed: {result.stderr[-1000:]}")
    return result.stdout.strip()


def wait_for(name, check, timeout=180):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if check():
                print(f"ok   {name}", flush=True)
                return
        except (subprocess.SubprocessError, OSError):
            pass
        time.sleep(2)
    raise TimeoutError(f"{name} did not become ready")


def http_ok(url):
    try:
        with urllib.request.urlopen(url, timeout=3) as response:
            return response.status == 200
    except OSError:
        return False


def port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def run_container(role, image, args, command=()):
    name = f"{PREFIX}-{role}"
    containers.append(name)
    podman("run", "-d", "--name", name, "--network", network, *args, image, *command)
    return name


def secret_file(directory, role):
    name = f"{PREFIX}-{role}"
    path = directory / role
    path.write_text(secrets.token_urlsafe(36), encoding="ascii")
    os.chmod(path, 0o600)
    podman("secret", "create", name, str(path))
    secret_names.append(name)
    return name


def mounted(name):
    role = name.rsplit("-", 1)[1]
    target = {"db": "n8n-db-password", "valkey": "n8n-valkey-password",
              "runners": "n8n-runners-auth-token"}[role]
    return ["--secret", f"{name},type=mount,target={target}"]


def envs(mapping):
    result = []
    for key, value in mapping.items():
        result.extend(["--env", f"{key}={value}"])
    return result


def main():
    for image in (N8N_IMAGE, RUNNERS_IMAGE, PG_IMAGE, VALKEY_IMAGE):
        podman("image", "exists", image)
    main_port, hook_port = port(), port()
    with tempfile.TemporaryDirectory(prefix="n8n-queue-test-") as td:
        directory = pathlib.Path(td)
        db_secret = secret_file(directory, "db")
        valkey_secret = secret_file(directory, "valkey")
        runners_secret = secret_file(directory, "runners")
        podman("network", "create", network)
        for role in ("pg", "data", "valkey"):
            name = f"{PREFIX}-{role}"
            podman("volume", "create", name)
            volumes.append(name)
        pg = run_container(
            "pg", PG_IMAGE,
            ["--volume", f"{volumes[0]}:/var/lib/postgresql/data",
             "--secret", f"{db_secret},type=env,target=POSTGRES_PASSWORD",
             *envs({"POSTGRES_USER": "n8n", "POSTGRES_DB": "n8n"})],
        )
        wait_for("PostgreSQL", lambda: subprocess.run(
            ["podman", "exec", pg, "pg_isready", "-U", "n8n", "-d", "n8n"],
            capture_output=True, check=False
        ).returncode == 0)
        valkey = run_container(
            "valkey", VALKEY_IMAGE,
            ["--volume", f"{volumes[2]}:/data",
             "--volume", f"{ROOT}/config/start-valkey.sh:/usr/local/bin/start-valkey.sh:ro",
             *mounted(valkey_secret)],
            ("/bin/sh", "/usr/local/bin/start-valkey.sh", "start"),
        )
        wait_for("Valkey authentication", lambda: subprocess.run(
            ["podman", "exec", valkey, "/bin/sh", "/usr/local/bin/start-valkey.sh", "health"],
            capture_output=True, check=False
        ).returncode == 0)

        common = {
            "DB_TYPE": "postgresdb", "DB_POSTGRESDB_HOST": pg,
            "DB_POSTGRESDB_PORT": "5432", "DB_POSTGRESDB_DATABASE": "n8n",
            "DB_POSTGRESDB_USER": "n8n",
            "DB_POSTGRESDB_PASSWORD_FILE": "/run/secrets/n8n-db-password",
            "EXECUTIONS_MODE": "queue", "QUEUE_BULL_REDIS_HOST": valkey,
            "QUEUE_BULL_REDIS_PORT": "6379",
            "QUEUE_BULL_REDIS_PASSWORD_FILE": "/run/secrets/n8n-valkey-password",
            "N8N_DEFAULT_BINARY_DATA_MODE": "database",
            "N8N_RUNNERS_MODE": "external", "N8N_NATIVE_PYTHON_RUNNER": "true",
            "N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS": "true",
            "N8N_HOST": "127.0.0.1", "N8N_PROTOCOL": "http",
            "N8N_EDITOR_BASE_URL": f"http://127.0.0.1:{main_port}/",
            "N8N_WEBHOOK_URL": f"http://127.0.0.1:{hook_port}/",
            "N8N_SECURE_COOKIE": "false", "N8N_DIAGNOSTICS_ENABLED": "false",
        }
        shared = ["--volume", f"{volumes[1]}:/home/node/.n8n",
                  *mounted(db_secret), *mounted(valkey_secret)]
        broker = {
            "N8N_RUNNERS_AUTH_TOKEN_FILE": "/run/secrets/n8n-runners-auth-token",
            "N8N_RUNNERS_BROKER_LISTEN_ADDRESS": "0.0.0.0",
        }
        main_name = f"{PREFIX}-main"
        worker_name = f"{PREFIX}-worker"

        def runner(role, broker_name):
            return run_container(
                role, RUNNERS_IMAGE,
                ["--volume", f"{ROOT}/config/n8n-task-runners.json:/etc/n8n-task-runners.json:ro",
                 "--secret", f"{runners_secret},type=env,target=N8N_RUNNERS_AUTH_TOKEN",
                 *envs({"N8N_RUNNERS_TASK_BROKER_URI": f"http://{broker_name}:5679"})],
            )

        runner("main-runners", main_name)
        main_container = run_container(
            "main", N8N_IMAGE,
            ["--publish", f"127.0.0.1:{main_port}:5678", *shared,
             *mounted(runners_secret),
             *envs({**common, **broker,
                    "N8N_DISABLE_PRODUCTION_MAIN_PROCESS": "true",
                    "N8N_EVENTBUS_LOGWRITER_LOGFULLPATH": "/home/node/.n8n/n8nEventLog-main.log"})],
            ("start",),
        )
        wait_for("main readiness", lambda: http_ok(f"http://127.0.0.1:{main_port}/healthz/readiness"), 240)
        runner("worker-runners", worker_name)
        worker = run_container(
            "worker", N8N_IMAGE,
            [*shared, *mounted(runners_secret),
             *envs({**common, **broker, "QUEUE_HEALTH_CHECK_ACTIVE": "true",
                    "N8N_EVENTBUS_LOGWRITER_LOGFULLPATH": "/home/node/.n8n/n8nEventLog-worker.log"})],
            ("worker", "--concurrency=5"),
        )
        wait_for("worker readiness", lambda: subprocess.run(
            ["podman", "exec", worker, "node", "-e",
             "fetch('http://127.0.0.1:5678/healthz/readiness').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"],
            capture_output=True, check=False
        ).returncode == 0, 180)
        hook = run_container(
            "webhook", N8N_IMAGE,
            ["--publish", f"127.0.0.1:{hook_port}:5678", *shared,
             *envs({**common,
                    "N8N_EVENTBUS_LOGWRITER_LOGFULLPATH": "/home/node/.n8n/n8nEventLog-webhook.log"})],
            ("webhook",),
        )
        wait_for("webhook health", lambda: http_ok(f"http://127.0.0.1:{hook_port}/healthz"), 180)
        def runners_ready(role):
            logs = podman("logs", role)
            return ('Registered runner "launcher-javascript"' in logs
                    and 'Registered runner "launcher-python"' in logs)

        for role in (main_container, worker):
            wait_for(f"{role} JavaScript/Python runner registration",
                     lambda role=role: runners_ready(role), 90)

        workflow = {
            "id": "QueueRuntimeProbe", "name": "Queue Runtime Probe", "active": True,
            "settings": {"executionOrder": "v1"},
            "nodes": [
                {"parameters": {"httpMethod": "POST", "path": "queue-runtime-probe",
                                "responseMode": "onReceived", "options": {}},
                 "id": "queue-webhook", "name": "Webhook", "type": "n8n-nodes-base.webhook",
                 "typeVersion": 2, "position": [240, 300], "webhookId": "queue-runtime-probe"},
                {"parameters": {"jsCode": "return [{json:{queueProbe:'ok'}}];"},
                 "id": "queue-code", "name": "Code", "type": "n8n-nodes-base.code",
                 "typeVersion": 2, "position": [460, 300]},
            ],
            "connections": {"Webhook": {"main": [[{"node": "Code", "type": "main", "index": 0}]]}},
        }
        wf_path = directory / "workflow.json"
        wf_path.write_text(json.dumps(workflow), encoding="utf-8")
        podman("cp", str(wf_path), f"{main_container}:/tmp/workflow.json")
        podman("exec", main_container, "n8n", "import:workflow", "--input=/tmp/workflow.json",
               "--activeState=fromJson", timeout=180)
        print("ok   workflow imported", flush=True)
        request = urllib.request.Request(
            f"http://127.0.0.1:{hook_port}/webhook/queue-runtime-probe",
            data=b'{}', headers={"Content-Type": "application/json"}, method="POST"
        )
        wait_for("processor accepts production webhook", lambda: http_ok_request(request), 90)
        wait_for(
            "worker completes queued Code node",
            lambda: podman(
                "exec", pg, "psql", "-U", "n8n", "-d", "n8n", "-tA", "-c",
                "SELECT status FROM execution_entity WHERE \"workflowId\"='QueueRuntimeProbe' "
                "ORDER BY id DESC LIMIT 1",
            ) == "success",
            90,
        )
        print("ok   isolated queue stack passed", flush=True)


def http_ok_request(request):
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            return response.status == 200
    except OSError:
        return False


if __name__ == "__main__":
    try:
        main()
    finally:
        for name in reversed(containers):
            subprocess.run(["podman", "stop", "--time", "30", name],
                           capture_output=True, check=False)
            subprocess.run(["podman", "rm", name], capture_output=True, check=False)
        for name in reversed(volumes):
            subprocess.run(["podman", "volume", "rm", name],
                           capture_output=True, check=False)
        subprocess.run(["podman", "network", "rm", network],
                       capture_output=True, check=False)
        for name in reversed(secret_names):
            subprocess.run(["podman", "secret", "rm", name],
                           capture_output=True, check=False)
