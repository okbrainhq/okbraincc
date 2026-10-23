#!/usr/bin/env python3
"""Transport for the app-bundled retention engine; no separately deployed Brain scripts.
Normal maintenance stays online. Only explicit manual Vacuum stops configured writers.
"""
import base64
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import signal
import stat
import subprocess
import sys
import threading
import time

SYSTEMCTL = "/bin/systemctl"
DEFAULT_UPLOADS = "/var/www/brain-data/uploads"
RESULT_PREFIX = "CC_RESULT "



class Blocked(Exception):
    def __init__(self, reason, code=2):
        super().__init__(reason)
        self.code = code


class Cancelled(Exception):
    pass


def log(message):
    try:
        print(message, flush=True)
    except OSError:
        # SSH/CC may have disconnected. Restoration must NEVER depend on a writable log pipe.
        pass


def token(value):
    return isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9_.:+-]{1,200}", value) is not None


def valid_path(value):
    return (isinstance(value, str) and value.startswith("/") and value != "/"
            and len(value) <= 1024 and value == value.strip()
            and all(ord(c) >= 32 and ord(c) != 127 for c in value)
            and all(p not in (".", "..") for p in value.split("/")))


def validate(config, action):
    if action not in ("dryRun", "apply", "vacuum"):
        raise Blocked("invalid_action")
    if not re.fullmatch(r"(?:[A-Za-z0-9_][A-Za-z0-9_.-]*@)?[A-Za-z0-9][A-Za-z0-9.-]*", config["host"]):
        raise Blocked("invalid_ssh_host_use_alias_or_user_at_hostname")
    if not valid_path(config["database"]):
        raise Blocked("invalid_database_path")
    if config["uploads"] and not valid_path(config["uploads"]):
        raise Blocked("invalid_uploads_path")
    if type(config["days"]) is not int or not 1 <= config["days"] <= 365:
        raise Blocked("invalid_retention_days")
    if config["afterID"] and not token(config["afterID"]):
        raise Blocked("invalid_sweep_cursor")
    if type(config["deleteImages"]) is not bool:
        raise Blocked("invalid_image_policy")
    if config["deleteImages"] and not config["uploads"]:
        raise Blocked("image_cleanup_requires_uploads_directory")
    # Offline safety belongs ONLY to manual Vacuum. Online work has no writer/permission checks.
    if action == "vacuum":
        services = config["services"]
        if (not isinstance(services, list) or len(services) > 20 or len(set(services)) != len(services)
                or any(not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.@-]{0,100}", s) for s in services)):
            raise Blocked("invalid_writer_services")
        if (not services or config["downtimeAcknowledged"] is not True
                or config["writersAcknowledged"] is not True):
            raise Blocked("manual_vacuum_requires_downtime_and_all_writers_controlled_acknowledgements")


def local_config(action):
    def env(key, default=""):
        return os.environ.get("OKBRAINCC_DB_MAINTENANCE_" + key, default)

    def flag(key, default="0"):
        value = env(key, default)
        if value not in ("0", "1"):
            raise Blocked("invalid_boolean_setting")
        return value == "1"

    days = env("RETENTION_DAYS", "10")
    if not re.fullmatch(r"[0-9]{1,3}", days):
        raise Blocked("invalid_retention_days")
    return dict(host=env("REMOTE_HOST", "arunoda@prodbox.local"),
                database=env("DATABASE", "/var/www/brain/brain.db"),
                uploads=env("UPLOADS_DIRECTORY") if env("UPLOADS_DIRECTORY").strip() else DEFAULT_UPLOADS, days=int(days),
                services=env("WRITER_SERVICES", "brain").split() if action == "vacuum" else [],
                deleteImages=flag("DELETE_IMAGES", "1"),
                downtimeAcknowledged=flag("DOWNTIME_ACKNOWLEDGED") if action == "vacuum" else False,
                writersAcknowledged=flag("WRITERS_ACKNOWLEDGED") if action == "vacuum" else False,
                afterID=env("AFTER_ID"))


def client(action):
    config = local_config(action)
    validate(config, action)  # Reject malformed input before even connecting.
    config["action"] = action
    config["engineSource"] = base64.b64encode(Path(__file__).with_name("db-retention.py").read_bytes()).decode()
    encoded_config = base64.b64encode(json.dumps(config).encode()).decode()
    encoded_script = base64.b64encode(Path(__file__).read_bytes()).decode()
    # Only fixed Python plus base64 crosses the remote login shell. No settings are shell source.
    bootstrap = "import base64; exec(compile(base64.b64decode('" + encoded_script + "'), '<cc-maintenance>', 'exec'))"
    remote_command = shlex.join(["python3", "-u", "-c", bootstrap, "--remote", encoded_config])
    cancelled = threading.Event()
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, lambda *_: cancelled.set())
    process = subprocess.Popen(["ssh", "-T", "-oBatchMode=yes", "-oConnectTimeout=15",
                                "-oServerAliveInterval=10", "-oServerAliveCountMax=3", "--",
                                config["host"], remote_command], stdin=subprocess.PIPE)
    cancellation_sent_at = None
    last_ping = 0
    while process.poll() is None:
        now = time.monotonic()
        if cancelled.is_set() and cancellation_sent_at is None:
            cancellation_sent_at = now
            log("Stop requested; waiting for remote child termination" + (" and Vacuum service restoration." if action == "vacuum" else "; online; Brain not stopped."))
            try:
                process.stdin.write(b"cancel\n")
                process.stdin.flush()
            except (BrokenPipeError, OSError):
                pass
        elif not cancelled.is_set() and now - last_ping >= 3:
            try:
                process.stdin.write(b"ping\n")
                process.stdin.flush()
            except (BrokenPipeError, OSError):
                pass
            last_ping = now
        if cancellation_sent_at and now - cancellation_sent_at > 180:
            log("ERROR: remote outcome unconfirmed; no success claimed." + (" Inspect configured Vacuum writers." if action == "vacuum" else " Online run did not stop Brain."))
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
            return 130
        time.sleep(0.1)
    process.stdin.close()
    return process.returncode if process.returncode >= 0 else 130


class Remote:
    def __init__(self, config):
        self.c = config
        self.cancel = threading.Event()
        self.last_heartbeat = time.monotonic()
        self.restore = []
        self.mutated = False
        self.report = dict(outcome="failed", history="not_run", images=None,
                           restorationFailed=False, partial=False, error=None)

    def watchdog(self):
        def read():
            for line in sys.stdin:
                if line.strip() != "ping":
                    self.cancel.set()
                    return
                self.last_heartbeat = time.monotonic()
            self.cancel.set()  # SSH disconnect or parent death, not an implicit success.
        threading.Thread(target=read, daemon=True).start()
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(sig, lambda *_: self.cancel.set())

    def check_cancel(self):
        if self.cancel.is_set() or time.monotonic() - self.last_heartbeat > 20:
            self.cancel.set()
            raise Cancelled()

    def command(self, args, restoring=False, timeout=600, stream=False):
        if not restoring:
            self.check_cancel()
        # Drain both pipes concurrently. Engine progress must arrive while work runs, not
        # after communicate() returns. Only metadata progress is forwarded; the terminal
        # report is withheld until Vacuum service restoration has been verified.
        child = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, start_new_session=True)
        captured = [[], []]

        def drain(pipe, index):
            try:
                for line in iter(pipe.readline, b''):
                    captured[index].append(line)
                    if stream and index == 0 and line.startswith(b'CC_PROGRESS '):
                        log(line.decode('utf-8', 'replace').rstrip('\r\n'))
            finally:
                pipe.close()

        readers = [threading.Thread(target=drain, args=(pipe, index), daemon=True)
                   for index, pipe in enumerate((child.stdout, child.stderr))]
        for reader in readers:
            reader.start()
        start = time.monotonic()
        try:
            while True:
                try:
                    child.wait(timeout=0.2)
                    break
                except subprocess.TimeoutExpired:
                    if not restoring:
                        self.check_cancel()
                    if time.monotonic() - start > timeout:
                        raise Blocked("command_timeout")
        except BaseException:
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
            raise
        finally:
            for reader in readers:
                reader.join()
        return child.returncode, *(b''.join(parts).decode('utf-8', 'replace') for parts in captured)

    def service_state(self, service, restoring=False):
        code, output, _ = self.command([SYSTEMCTL, "show", "--property=LoadState", "--property=ActiveState", service],
                                       restoring=restoring, timeout=90)
        fields = dict(line.split("=", 1) for line in output.splitlines() if "=" in line)
        if code or fields.get("LoadState") != "loaded" or fields.get("ActiveState") not in ("active", "inactive"):
            raise Blocked("writer_service_unknown_or_not_stably_active_or_inactive:" + service)
        return fields["ActiveState"]

    def stop_writers(self):
        states = [(service, self.service_state(service)) for service in self.c["services"]]
        for service, state in states:
            log("Writer " + service + " initially " + state)
        for service, state in states:
            if state == "active":
                # Record BEFORE stop: a failed stop can still have stopped the service.
                self.restore.append(service)
                code, _, _ = self.command(["sudo", "-n", SYSTEMCTL, "stop", service], timeout=90)
                if code:
                    raise Blocked("writer_stop_failed:" + service)
        self.verify_offline()
        log("OFFLINE verified: every configured writer inactive. Operator affirmed no other writers.")

    def verify_offline(self):
        for service in self.c["services"]:
            if self.service_state(service) != "inactive":
                raise Blocked("writer_not_inactive:" + service)

    def restore_writers(self):
        failed = False
        for service in reversed(self.restore):
            try:
                try:
                    state = self.service_state(service, restoring=True)
                except Exception:
                    state = "unknown"  # Originally active: still attempt restoration after a failed stop.
                if state != "active":
                    code, _, _ = self.command(["sudo", "-n", SYSTEMCTL, "start", service], restoring=True, timeout=90)
                    if code or self.service_state(service, restoring=True) != "active":
                        raise Blocked("restart_failed")
                log("Writer restored and verified active: " + service)
            except Exception:
                failed = True
                log("ERROR: writer restoration FAILED: " + service + "; operator intervention required.")
        self.report["restorationFailed"] = failed
        return failed

    def execute(self):
        validate(self.c, self.c["action"])
        self.watchdog()
        lock_fd = None
        code = 0
        try:
            db = self.c["database"]
            if os.path.realpath(db) != db or not stat.S_ISREG(os.lstat(db).st_mode):
                raise Blocked("database_must_be_existing_canonical_regular_file")
            lock_fd = os.open(os.path.dirname(db), os.O_RDONLY | os.O_NOFOLLOW | os.O_DIRECTORY)
            try:
                fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise Blocked("another_cc_maintenance_holds_database_lock")
            log("Policy v3: Code Project tool logs/images + web search tool logs only. ALL chat text is retained.")
            log("Daily work: quick_check, retention, optimize, passive WAL checkpoint. VACUUM is manual only.")
            log("Mode: " + ("manual offline Vacuum; no retention deletions." if self.c["action"] == "vacuum" else "online; Brain not stopped."))
            if self.c["action"] == "vacuum":
                self.stop_writers()
                self.verify_offline()
            source = self.c["engineSource"]
            # Only the signed/bundled engine and base64 configuration cross the shell boundary.
            bootstrap = "import base64;exec(compile(base64.b64decode(" + repr(source) + "),'<cc-retention>','exec'))"
            config = base64.b64encode(json.dumps({k:v for k,v in self.c.items() if k != "engineSource"}).encode()).decode()
            self.mutated = self.c["action"] != "dryRun"  # Transport interruption can leave committed batches.
            code, output, _ = self.command([sys.executable, "-u", "-c", bootstrap, config], timeout=1200, stream=True)
            result = [line[len(RESULT_PREFIX):] for line in output.splitlines() if line.startswith(RESULT_PREFIX)]
            if not result:
                raise Blocked("missing_engine_report_outcome_unconfirmed")
            report = json.loads(result[-1])
            if not isinstance(report, dict) or report.get("outcome") not in {"success","warning","failed","partial","deferred"}:
                raise Blocked("invalid_engine_report")
            self.report = report
            self.check_cancel()
        except Cancelled:
            code = 130
            self.report.update(outcome="stopped", partial=self.mutated, error="cancelled_remote_outcome_may_be_partial")
        except Exception as error:
            code = error.code if isinstance(error, Blocked) else 2
            reason = str(error) if isinstance(error, Blocked) else "remote_execution_error:" + type(error).__name__
            self.report.update(outcome="partial" if self.mutated else "failed", error=reason, partial=self.mutated)
        finally:
            if self.c["action"] == "vacuum" and self.restore_writers():
                code = 4
                self.report.update(outcome="partial" if self.mutated else "failed", partial=self.mutated,
                                   error="service_restoration_failed_operator_intervention_required")
            if lock_fd is not None:
                os.close(lock_fd)
            log(RESULT_PREFIX + json.dumps(self.report, sort_keys=True))
        return code


def main():
    try:
        if len(sys.argv) == 3 and sys.argv[1] == "--local":
            return client(sys.argv[2])
        if len(sys.argv) == 3 and sys.argv[1] == "--remote":
            config = json.loads(base64.b64decode(sys.argv[2], validate=True))
            return Remote(config).execute()
        raise Blocked("invalid_invocation")
    except Exception as error:
        log("ERROR: " + (str(error) if isinstance(error, Blocked) else "maintenance_transport_failed:" + type(error).__name__))
        return 2


if __name__ == "__main__":
    sys.exit(main())
