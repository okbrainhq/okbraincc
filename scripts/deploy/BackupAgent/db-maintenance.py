#!/usr/bin/env python3
"""CC-only transport/orchestration. Counterpart CLIs own all data selection/deletion.
No remote migrations, image selection, shell interpolation, or legacy/offline image fallback.
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

HISTORY_SCRIPT = "/var/www/brain/scripts/deploy/cleanup-old-execution-history.sh"
IMAGE_SCRIPT = "/var/www/brain/scripts/deploy/cleanup-agent-images.py"
SYSTEMCTL = "/bin/systemctl"
DEFAULT_UPLOADS = "/var/www/brain-data/uploads"
BATCH_SIZE = 100
MAX_BATCHES = 3
RESULT_PREFIX = "CC_RESULT "
ONLINE_TRANSIENT_REASONS = {"online-db-busy", "online-snapshot-changed", "online-lock-budget-exceeded", "online-run-budget-exceeded"}
ONLINE_CANCEL_REASONS = {"cancelled:SIGTERM", "cancelled:SIGINT"}
ONLINE_BLOCKED_REASONS = ONLINE_TRANSIENT_REASONS | ONLINE_CANCEL_REASONS | {"online-requires-wal", "online-no-close-checkpoint-control"}


class Blocked(Exception):
    def __init__(self, reason, code=2):
        super().__init__(reason)
        self.code = code


class Deferred(Blocked):
    """Verified online contention/budget report with no confirmed or unconfirmed image deletion."""
    pass


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

    def command(self, args, restoring=False, timeout=600):
        if not restoring:
            self.check_cancel()
        # A separate group lets us terminate the whole cleanup CLI before restoring writers.
        child = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, start_new_session=True)
        start = time.monotonic()
        try:
            while True:
                try:
                    stdout, stderr = child.communicate(timeout=0.2)
                    return child.returncode, stdout.decode("utf-8", "replace"), stderr.decode("utf-8", "replace")
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
                child.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.communicate()
            raise

    def help_check(self):
        code, output, _ = self.command(["bash", HISTORY_SCRIPT, "--tool-history-only", "--help"])
        needed = ["--tool-history-only", "--db", "--days", "--apply"]
        if self.c["action"] == "vacuum":
            needed.append("--vacuum")
        else:
            needed.append("--no-checkpoint")
        if code or any(flag not in output for flag in needed):
            raise Blocked("history_counterpart_not_released_or_safe_flags_unsupported")

    def image_help_check(self):
        code, output, _ = self.command(["python3", IMAGE_SCRIPT, "--help"])
        flags = set(re.findall(r"--[a-z][a-z0-9-]*", output))
        needed = {"--db", "--uploads-dir", "--days", "--batch-size", "--after-id", "--apply", "--online"}
        if code or not needed.issubset(flags):
            raise Blocked("image_counterpart_online_unsupported_release_brain_first")
        log("Image preflight: --online supported; no offline/legacy fallback.")

    def history(self, apply=False):
        phase = "history_apply" if apply else "history_dry_run"
        log("PHASE " + phase + ": following rows/approx_payload are PRE-APPLY CANDIDATES, not actual deletions.")
        log("chat_events.news_search overlaps chat_events.tool_history; never sum these rows. No chat/message/job deletion.")
        args = ["bash", HISTORY_SCRIPT, "--tool-history-only", "--db", self.c["database"], "--days", str(self.c["days"])]
        if apply:
            args.append("--apply")
            if self.c["action"] == "vacuum":
                args.append("--vacuum")
            else:
                args.append("--no-checkpoint")  # Online history must not request a TRUNCATE checkpoint.
            self.mutated = True  # Even a failed command can have committed part of its work.
            self.report["history"] = "apply_started_actual_counts_unavailable"
        code, output, stderr = self.command(args)
        labels = ["tool_call_logs(all)", "chat_events.tool_history", "chat_events.news_search(tool_call+tool_result)",
                  "job_events.output(all_terminal_jobs)", "smart_doc_conversations(delete)", "smart_doc_jobs(delete)"]
        rows = {}
        for line in output.splitlines():
            for label in labels:
                if line.strip().startswith(label):
                    tail = line.strip()[len(label):]
                    # Only metadata columns may reach persistent CC logs. Suppress other CLI output.
                    if re.fullmatch(r"[\s|:=0-9.,+-]*(?:[KMGT]?i?B|bytes)?[\s|0-9.,+-]*", tail):
                        log("  " + label + tail)
                        match = re.search(r"\d+", tail)
                        if match:
                            rows[label] = int(match.group())
            if re.fullmatch(r"\s*cutoff_utc[\s|:=0-9TZ.+-]*", line) or re.fullmatch(r"[0-9]{4}-[0-9TZ :.+|-]+", line):
                log("  " + line.strip())
        if code:
            log(f"ERROR {phase}: exit={code}; diagnostic_bytes={len(stderr.encode())}; raw diagnostics suppressed.")
            raise Blocked("history_command_failed_actual_changes_unknown" if apply else "history_dry_run_failed")
        if ("chat_events.tool_history" not in rows or rows.get("smart_doc_conversations(delete)") != 0
                or rows.get("smart_doc_jobs(delete)") != 0):
            raise Blocked("history_safe_scope_report_missing_or_nonzero_chat_job_candidates")
        self.report["history"] = "apply_succeeded_actual_counts_unavailable" if apply else "dry_run_zero_deletions"
        log("History Apply command succeeded; actual deleted rows/bytes NOT reported by counterpart."
            if apply else "History Dry Run: actual deletions=0; no service stop or data mutation.")

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

    @staticmethod
    def image_failure_reason(raw, output, stderr):
        # Frozen machine-readable reasons only; never forward arbitrary diagnostics or body text.
        if isinstance(raw, dict):
            for key in ("blocked", "error", "reason"):
                value = raw.get(key)
                if isinstance(value, str) and value in ONLINE_BLOCKED_REASONS:
                    return value
        diagnostic = output + stderr
        if re.search(r"schema|no such (table|column)|migrat", diagnostic, re.I):
            return "image_schema_unavailable_release_brain_first"
        if re.search(r"storage_root|root.mismatch", diagnostic, re.I):
            return "image_storage_root_mismatch"
        return "image_cli_blocked"

    def image_batch(self, after, apply=False, phase="images_preview"):
        args = ["python3", IMAGE_SCRIPT, "--db", self.c["database"], "--uploads-dir", self.c["uploads"],
                "--days", str(self.c["days"]), "--batch-size", str(BATCH_SIZE)]
        if after:
            args += ["--after-id", after]
        if apply:
            args += ["--apply", "--online"]
            self.mutated = True
        code, output, stderr = self.command(args)
        try:
            raw = json.loads(output)
        except (ValueError, TypeError):
            raw = None
        numeric = ["examined", "candidates", "candidate_bytes", "deleted", "deleted_bytes", "missing_finalized", "errors", "reference_scan_bytes"]
        reason = self.image_failure_reason(raw, output, stderr) if code else None
        if reason == "online-no-close-checkpoint-control":
            log("BLOCKED: online runtime requires Python sqlite3.setconfig + SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE to avoid a hidden close-checkpoint. Operational prerequisite, not consent; no offline fallback.")
        if apply and code == 1 and reason == "image_cli_blocked":
            reason = "image_online_partial_see_reasons"
        full_counters = isinstance(raw, dict) and all(type(raw.get(k)) is int and raw[k] >= 0 for k in numeric)
        if not full_counters:
            if code:
                log(f"ERROR {phase}: {reason}; exit={code}; no complete verified report; raw diagnostics suppressed.")
                raise Blocked(reason)  # No assumptions about deletion/cursor from a generic blocked shape.
            raise Blocked("image_report_invalid_json" if raw is None else "image_report_missing_or_invalid_counters")
        # Online failed reports still contain confirmed commits and protection/error metadata.
        # Parse/validate them BEFORE classifying the exit, rather than discarding useful partial counts.
        if not apply and code not in (0, 1):
            raise Blocked(reason)
        if apply and raw.get("execution_mode") != "online":
            raise Blocked("image_report_execution_mode_not_online")
        if raw.get("mode") not in (("apply",) if apply else ("dry-run", "dry_run")):
            raise Blocked("image_report_wrong_mode")
        if raw.get("database") != self.c["database"] or raw.get("uploads_directory") != self.c["uploads"] or raw.get("retention_days") != self.c["days"]:
            raise Blocked("image_report_scope_mismatch")
        if (raw["examined"] > BATCH_SIZE or raw["candidates"] > raw["examined"]
                or raw["deleted"] + raw["missing_finalized"] > raw["examined"]):
            raise Blocked("image_report_exceeded_batch_bound")
        if not apply and any(raw[k] for k in ("deleted", "deleted_bytes", "missing_finalized")):
            raise Blocked("image_dry_run_reported_mutation")
        if code and not raw["errors"]:
            raise Blocked("image_exit_error_without_error_count")
        if "next_after_id" not in raw:
            raise Blocked("image_report_missing_continuation")
        next_id = raw["next_after_id"]
        if apply and code:
            # Failed online batches intentionally repeat their input cursor, including "" at start.
            # Never adopt any backend continuation on failure, even if it claims another value.
            next_id = after
        elif next_id is not None:
            if type(next_id) not in (str, int) or not token(str(next_id)) or str(next_id) == after:
                raise Blocked("image_cursor_invalid_or_stalled")
            next_id = str(next_id)
        reasons = raw.get("reasons")
        inventory, items = raw.get("inventory"), raw.get("items")
        if (not isinstance(reasons, dict) or any(not token(k) or type(v) is not int or v < 0 for k, v in reasons.items())
                or not isinstance(inventory, list) or not isinstance(items, list) or len(items) > BATCH_SIZE):
            raise Blocked("image_report_invalid_metadata")
        # Deliberate metadata allowlist: never forward unknown fields, image bytes or chat content.
        safe = {k: raw[k] for k in numeric}
        safe.update(mode=raw["mode"], database=self.c["database"], uploads_directory=self.c["uploads"],
                    retention_days=self.c["days"], next_after_id=next_id, reasons=reasons, inventory=[], items=[])
        if apply:
            safe["execution_mode"] = "online"
        if reason:
            safe["blocked"] = reason
        cutoff = raw.get("cutoff_utc", "")
        if isinstance(cutoff, str) and re.fullmatch(r"[0-9TZ :.+-]{10,40}", cutoff):
            safe["cutoff_utc"] = cutoff
        for row in inventory:
            if (not isinstance(row, dict) or not token(row.get("origin"))
                    or any(type(row.get(k)) is not int or row[k] < 0 for k in ("rows", "recorded_bytes"))):
                raise Blocked("image_inventory_invalid")
            safe["inventory"].append({k: row[k] for k in ("origin", "rows", "recorded_bytes")})
        for row in items:
            if not isinstance(row, dict) or not token(row.get("reason")) or type(row.get("bytes")) is not int or row["bytes"] < 0:
                raise Blocked("image_item_invalid")
            identifier = str(row.get("id", ""))
            filename = row.get("filename", "")
            safe["items"].append(dict(id=identifier if token(identifier) else "redacted",
                                      filename=filename if isinstance(filename, str) and re.fullmatch(r"[A-Za-z0-9._-]{1,180}", filename) else "redacted",
                                      bytes=row["bytes"], reason=row["reason"]))
        log("PHASE " + phase + ": candidates are not deletions; missing_finalized are tombstones, NOT deleted files.")
        log("CC_IMAGE_REPORT " + json.dumps(safe, sort_keys=True))
        return safe, code, reason

    def sweep(self, apply=False):
        totals = dict(mode="online-apply" if apply else "preview", batches=0, examined=0, candidates=0, candidateBytes=0,
                      deleted=0, deletedBytes=0, missingFinalized=0, errors=0, reasons={}, nextAfterID=self.c["afterID"] or None,
                      sweepComplete=False, cursorCanAdvance=False, unconfirmedBatch=False)
        self.report["images"] = totals
        after = self.c["afterID"]
        seen = {after}
        for _ in range(MAX_BATCHES):
            totals["unconfirmedBatch"] = apply
            batch, exit_code, reason = self.image_batch(after, apply, "images_online_apply_after_history" if apply else "images_preview")
            totals["unconfirmedBatch"] = apply and (
                any(key.startswith("unconfirmed-") and count > 0 for key, count in batch["reasons"].items())
                or any(item["reason"].startswith("unconfirmed-") for item in batch["items"]))
            totals["batches"] += 1
            for key, source in [("examined", "examined"), ("candidates", "candidates"), ("candidateBytes", "candidate_bytes"),
                                ("deleted", "deleted"), ("deletedBytes", "deleted_bytes"), ("missingFinalized", "missing_finalized"), ("errors", "errors")]:
                totals[key] += batch[source]
            for protection_reason, count in batch["reasons"].items():
                totals["reasons"][protection_reason] = totals["reasons"].get(protection_reason, 0) + count
            if apply and (exit_code or batch["errors"] or totals["unconfirmedBatch"]):
                # ANY failed online batch invalidates progress for this run, including exit 1.
                # Keep confirmed counters from earlier batches, but retry from this run's saved input.
                totals.update(nextAfterID=self.c["afterID"] or None, sweepComplete=False, cursorCanAdvance=False)
                log(f"Online image batch exit={exit_code}; confirmed counters retained; unconfirmed={totals['unconfirmedBatch']}. Sweep NOT complete; saved cursor unchanged; retry next scheduled cycle.")
                if reason in ONLINE_CANCEL_REASONS:
                    raise Cancelled(reason)
                if (reason in ONLINE_TRANSIENT_REASONS and not totals["deleted"] and not totals["missingFinalized"]
                        and not totals["unconfirmedBatch"]):
                    raise Deferred(reason)
                raise Blocked(reason or "image_online_partial_see_reasons", code=exit_code if exit_code in (1, 2) else 2)
            after = batch["next_after_id"]
            if after is not None and after in seen:
                raise Blocked("image_cursor_cycle")
            seen.add(after)
            # Only successful online batches (or completed read-only preview batches) may advance.
            totals["nextAfterID"] = after
            totals["sweepComplete"] = after is None
            totals["cursorCanAdvance"] = True
            if after is None:
                break
        log("Image sweep: " + ("reached end of this traversal; later sweeps recheck protected/error rows."
                                if totals["sweepComplete"] else "BOUNDED / INCOMPLETE; resume after " + after + " on next run. NOT entire upload inventory cleaned."))
        log("Only proven eligible agent files are considered. User uploads, unknown/legacy images and retained references remain protected.")
        return totals["errors"]

    def execute(self):
        validate(self.c, self.c["action"])
        self.watchdog()
        lock_fd = None
        code = 0
        try:
            db = self.c["database"]
            if os.path.realpath(db) != db or not stat.S_ISREG(os.lstat(db).st_mode):
                raise Blocked("database_must_be_existing_canonical_regular_file")
            # Advisory directory-inode lock: no remote lock/state files are created.
            # Do not flock SQLite itself (it conflicts with SQLite locks on macOS fixtures).
            # All CC mutation + batches + restoration share this lock; Apply re-preflights under it.
            lock_fd = os.open(os.path.dirname(db), os.O_RDONLY | os.O_NOFOLLOW | os.O_DIRECTORY)
            try:
                fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise Blocked("another_cc_maintenance_holds_database_lock")
            if self.c["uploads"]:
                root = self.c["uploads"]
                if os.path.realpath(root) != root or not os.path.isdir(root):
                    raise Blocked("uploads_must_be_explicit_existing_canonical_directory")
            log("Scope: tool execution history only; conversations/messages/jobs/repository edits/files/user uploads are retained.")
            image_apply = self.c["deleteImages"] and self.c["action"] == "apply"
            log("Mode: " + ("manual offline Vacuum; images preview only." if self.c["action"] == "vacuum" else "online; Brain not stopped; no service checks/stop/start."))
            log(f"Settings: cutoff_age_days={self.c['days']}; image_policy={'online cleanup' if self.c['deleteImages'] and self.c['action'] != 'vacuum' else 'preview only'}; after_id={self.c['afterID'] or 'start'}; bound={MAX_BATCHES}x{BATCH_SIZE}")
            log("Images require old upload AND old owning chat/recent activity, inactive jobs; backend owns eligibility and root/hash/reference checks.")
            self.help_check()
            if self.c["uploads"]:
                self.image_help_check()
            self.history()
            if self.c["action"] == "dryRun":
                if self.c["uploads"]:
                    code = 1 if self.sweep() else 0
            else:
                # Detect undeployed image CLI/schema/root BEFORE any data deletion or stop.
                if self.c["uploads"]:
                    probe, _, _ = self.image_batch(self.c["afterID"], phase="images_preapply_readonly_probe_not_sweep_totals")
                    if probe["errors"]:
                        raise Blocked("image_preapply_probe_has_errors")
                if self.c["action"] == "vacuum":
                    self.stop_writers()
                    self.verify_offline()
                self.history(apply=True)
                if self.c["uploads"]:
                    code = 1 if self.sweep(apply=image_apply) else 0
            if not self.c["uploads"]:
                log("Images SKIPPED: uploads_directory_not_configured. History safe mode only; verify storage_root and configure preview. No images deleted.")
            self.check_cancel()
            self.report["outcome"] = ("partial" if code else "warning" if not self.c["uploads"] else
                                      "incomplete" if not self.report["images"]["sweepComplete"] else "success")
            if code:
                self.report["error"] = "image_per_file_errors_see_reasons"
                self.report["partial"] = True
        except Deferred as error:
            code = 2
            self.report.update(outcome="deferred", error=str(error), partial=self.mutated)
            log("Online images deferred: no confirmed image deletions or unconfirmed unlinks; NOT a completed sweep. History may have completed; scheduler retries next cycle.")
        except Cancelled as error:
            code = 130
            reason = str(error) if str(error) in ONLINE_CANCEL_REASONS else "cancelled_remote_child_terminated"
            self.report.update(outcome="stopped", error=reason, partial=self.mutated)
            log("CANCELLED: cleanup terminated; Apply may be partial. " + ("Restoring only previously active Vacuum writers." if self.c["action"] == "vacuum" else "Online; Brain not stopped."))
        except Exception as error:
            code = error.code if isinstance(error, Blocked) else 2
            # Do not leak arbitrary exception / counterpart content into logs.
            reason = str(error) if isinstance(error, Blocked) else "remote_preflight_or_execution_error:" + type(error).__name__
            self.report.update(outcome="partial" if self.mutated else "failed", error=reason, partial=self.mutated)
            log("ERROR: " + reason)
        finally:
            images = self.report["images"]
            if code and images and images["mode"] == "online-apply":
                images.update(nextAfterID=self.c["afterID"] or None, sweepComplete=False, cursorCanAdvance=False)
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
