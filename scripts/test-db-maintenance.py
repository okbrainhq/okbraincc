#!/usr/bin/env python3
"""Fixture-only integration tests. Never use real SSH/systemctl, CC state, or Brain data.
These test CC orchestration against contract doubles, NOT the upstream deletion algorithm.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
RUNNERS = ROOT / "scripts/deploy/BackupAgent"

FAKE_SSH = r'''
import base64, json, os, pathlib, re, shlex, sys
root = pathlib.Path(os.environ["FIXTURE_ROOT"]).resolve()
assert sys.argv[-2] == "fixture", "REFUSING any non-fixture SSH target"
args = shlex.split(sys.argv[-1])
assert args[:3] == ["python3", "-u", "-c"] and args[4] == "--remote"
config = json.loads(base64.b64decode(args[5]))
assert pathlib.Path(config["database"]).resolve().is_relative_to(root)
assert not config["uploads"] or pathlib.Path(config["uploads"]).resolve().is_relative_to(root)
with (root / "trace").open("a") as f: f.write(json.dumps(["ssh", os.getpid()]) + "\n")
encoded = re.search(r"base64.b64decode\('([^']+)'\)", args[3]).group(1)
source = base64.b64decode(encoded).decode()
source = source.replace('HISTORY_SCRIPT = "/var/www/brain/scripts/deploy/cleanup-old-execution-history.sh"', 'HISTORY_SCRIPT = ' + repr(str(root / "history.sh")))
image = root / ("missing-image.py" if os.environ.get("CASE") == "missing_image" else "images.py")
source = source.replace('IMAGE_SCRIPT = "/var/www/brain/scripts/deploy/cleanup-agent-images.py"', 'IMAGE_SCRIPT = ' + repr(str(image)))
source = source.replace('SYSTEMCTL = "/bin/systemctl"', 'SYSTEMCTL = ' + repr(str(root / "bin/systemctl")))
os.execv(sys.executable, [sys.executable, "-u", "-c", source, "--remote", args[5]])
'''

FAKE_SUDO = r'''
import os, pathlib, sys
expected = str(pathlib.Path(os.environ["FIXTURE_ROOT"]) / "bin/systemctl")
assert sys.argv[1] == "-n" and sys.argv[2] == expected, "REFUSING real sudo"
os.execv(expected, [expected] + sys.argv[3:])
'''

FAKE_SYSTEMCTL = r'''
import json, os, pathlib, sys, time
root = pathlib.Path(os.environ["FIXTURE_ROOT"])
args = sys.argv[1:]
assert args[0] in ("show", "start", "stop")
service = args[-1]
assert service in ("brain", "fixture-worker"), "Only explicitly configured fixture services allowed"
with (root / "trace").open("a") as f: f.write(json.dumps(["systemctl"] + args) + "\n")
state_path = root / "services.json"
states = json.loads(state_path.read_text())
case = os.environ.get("CASE")
if args[0] == "show":
    print("LoadState=" + ("not-found" if case == "unknown_service" else "loaded"))
    print("ActiveState=" + states[service])
else:
    if args[0] == "stop":
        if case != "stop_lies": states[service] = "inactive"
        state_path.write_text(json.dumps(states))
        if case == "stop_fail": sys.exit(1)
        if case == "signal_stop":
            (root / "hanging").write_text("stop")
            time.sleep(60)
    else:
        if case == "restart_fail": sys.exit(1)
        states[service] = "active"
        state_path.write_text(json.dumps(states))
'''

FAKE_HISTORY = r'''
import json, os, pathlib, sqlite3, sys, time
root = pathlib.Path(os.environ["FIXTURE_ROOT"])
args = sys.argv[1:]
with (root / "trace").open("a") as f: f.write(json.dumps(["history"] + args) + "\n")
case = os.environ.get("CASE")
if "--help" in args:
    print("fixture --db --days --apply --vacuum" + ("" if case == "old" else " --tool-history-only"))
    sys.exit(0)
if case == "unknown_flag": sys.exit(2)
assert "--tool-history-only" in args, "unsafe legacy branch would delete SmartDoc chats!"
db = args[args.index("--db") + 1]
apply = "--apply" in args
con = sqlite3.connect(db if apply else pathlib.Path(db).as_uri() + "?mode=ro", uri=not apply)
count = lambda sql: con.execute(sql).fetchone()[0]
rows = [
 ("tool_call_logs(all)", count("select count(*) from tool_call_logs where aged=1")),
 ("chat_events.tool_history", count("select count(*) from chat_events where aged=1 and kind in ('tool_call','tool_result')")),
 ("chat_events.news_search(tool_call+tool_result)", count("select count(*) from chat_events where aged=1 and tool='news_search' and kind in ('tool_call','tool_result')")),
 ("job_events.output(all_terminal_jobs)", count("select count(*) from job_events where aged=1 and kind='output' and job_id in (select id from jobs where finished=1)")),
 ("smart_doc_conversations(delete)", 1 if case == "unsafe_scope" else 0),
 ("smart_doc_jobs(delete)", 0)]
print("cutoff_utc\t2026-01-01T00:00:00Z")
print("category\trows\tapprox_payload")
for label, value in rows: print(f"{label}\t{value}\t{value*20} B")
print("PRIVATE_CHAT_BODY_SENTINEL")  # Must NOT reach CC logs.
if apply:
    (root / "history-applied").write_text("yes")
    if case == "signal_history":
        (root / "hanging").write_text("history")
        time.sleep(60)
    con.execute("delete from tool_call_logs where aged=1")
    con.execute("delete from chat_events where aged=1 and kind in ('tool_call','tool_result')")
    con.execute("delete from job_events where aged=1 and kind='output' and job_id in (select id from jobs where finished=1)")
    con.commit()
    if case == "history_failure": sys.exit(1)
'''

FAKE_IMAGES = r'''
import argparse, collections, json, os, pathlib, sqlite3, sys, time
root = pathlib.Path(os.environ["FIXTURE_ROOT"])
args = sys.argv[1:]
with (root / "trace").open("a") as f: f.write(json.dumps(["images"] + args) + "\n")
p = argparse.ArgumentParser()
p.add_argument("--db", required=True); p.add_argument("--uploads-dir", required=True)
p.add_argument("--days", type=int, required=True); p.add_argument("--batch-size", type=int, required=True)
p.add_argument("--after-id", default="0"); p.add_argument("--apply", action="store_true")
p.add_argument("--offline", action="store_true"); p.add_argument("--confirm-app-db-scope", action="store_true")
a = p.parse_args()
case = os.environ.get("CASE")
if case == "schema" or case == "schema_after" and (root / "history-applied").exists():
    print(json.dumps({"error":"schema missing PRIVATE_CHAT_BODY_SENTINEL"})); sys.exit(2)
if case == "invalid_json": print("PRIVATE_CHAT_BODY_SENTINEL"); sys.exit(0)
if a.apply:
    assert a.offline and a.confirm_app_db_scope
    assert all(s == "inactive" for s in json.loads((root / "services.json").read_text()).values()), "not all writers offline"
    if case == "signal_images":
        (root / "hanging").write_text("images")
        time.sleep(60)
con = sqlite3.connect(a.db if a.apply else pathlib.Path(a.db).as_uri() + "?mode=ro", uri=not a.apply)
con.row_factory = sqlite3.Row
rows = con.execute("select * from assets where id>? order by id limit ?", (int(a.after_id), a.batch_size)).fetchall()
out = dict(mode="apply" if a.apply else "dry-run", database=a.db, uploads_directory=a.uploads_dir,
 retention_days=a.days, cutoff_utc="2026-01-01T00:00:00Z", scope="known-agent-only", inventory=[],
 examined=len(rows), candidates=0, candidate_bytes=0, deleted=0, deleted_bytes=0,
 missing_finalized=0, errors=0, items=[], next_after_id=rows[-1]["id"] if len(rows)==a.batch_size else None,
 reference_scan_bytes=123, reasons={}, extra="PRIVATE_IMAGE_CONTENT_SENTINEL")
for r in con.execute("select origin,count(*) rows,sum(bytes) recorded_bytes from assets group by origin"):
    out["inventory"].append(dict(r))
for row in rows:
    r = dict(row)
    f = pathlib.Path(a.uploads_dir) / r["filename"]
    if r["deleted"]: reason="already_finalized"
    elif r["origin"] == "user": reason="protected_user"
    elif r["origin"] == "unknown": reason="protected_unknown"
    elif r["pinned"]: reason="pinned"
    elif not r["aged"]: reason="too_recent"
    elif con.execute("select count(*) from chat_events where image_id=?", (r["id"],)).fetchone()[0]: reason="retained_db_reference"
    elif not f.exists():
        reason="missing_file"
        if a.apply:
            con.execute("update assets set deleted=1 where id=?", (r["id"],))
            out["missing_finalized"]+=1; reason="missing_finalized"
    else:
        out["candidates"]+=1; out["candidate_bytes"]+=r["bytes"]
        reason="candidate"
        if a.apply:
            if case == "image_partial" and r["id"]==1:
                out["errors"]+=1; reason="file_error"
            else:
                f.unlink(); con.execute("update assets set deleted=1 where id=?", (r["id"],))
                out["deleted"]+=1; out["deleted_bytes"]+=r["bytes"]; reason="deleted"
    out["items"].append(dict(id=r["id"], filename=r["filename"], bytes=r["bytes"], reason=reason, content="PRIVATE_IMAGE_CONTENT_SENTINEL"))
    out["reasons"][reason]=out["reasons"].get(reason, 0)+1
if a.apply: con.commit()
if case == "wrong_mode": out["mode"]="apply"
if case == "dry_mutation": out["deleted"]=1
if case == "stall": out["next_after_id"]=a.after_id or "0"
if case == "scope_mismatch": out["uploads_directory"]="/untrusted"
print(json.dumps(out))
sys.exit(1 if out["errors"] else 0)
'''


class MaintenanceFixtures(unittest.TestCase):
    def setUp(self):
        parent = ROOT / ".build/maintenance-fixtures"
        parent.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="case-", dir=parent)
        self.root = Path(self.temp.name).resolve()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.uploads = self.root / "uploads ' ; $literal"
        self.uploads.mkdir()
        self.db = self.root / "fixture brain.db"
        self.env = dict(os.environ, FIXTURE_ROOT=str(self.root), PATH=str(self.bin) + os.pathsep + os.environ["PATH"])
        for key in list(self.env):
            if key.startswith("OKBRAINCC_DB_MAINTENANCE_"): del self.env[key]
        self.setting("REMOTE_HOST", "fixture")
        self.setting("DATABASE", str(self.db))
        self.setting("UPLOADS_DIRECTORY", str(self.uploads))
        self.setting("WRITER_SERVICES", "brain fixture-worker")
        for name, source in [("bin/ssh", FAKE_SSH), ("bin/sudo", FAKE_SUDO), ("bin/systemctl", FAKE_SYSTEMCTL),
                             ("history.py", FAKE_HISTORY), ("images.py", FAKE_IMAGES)]:
            path = self.root / name
            path.write_text("#!" + sys.executable + "\n" + source)
            path.chmod(0o755)
        (self.root / "history.sh").write_text('#!/bin/bash\nexec python3 "$FIXTURE_ROOT/history.py" "$@"\n')
        (self.root / "services.json").write_text(json.dumps({"brain":"active", "fixture-worker":"inactive"}))
        (self.root / "repo").mkdir()
        (self.root / "repo/edited.swift").write_text("actual repository edits stay")
        (self.uploads / "untracked-user-upload.png").write_text("USER_UPLOAD")
        con = sqlite3.connect(self.db)
        con.executescript("""
          create table conversations(id integer, kind text, body text);
          insert into conversations values(1,'SmartDoc','PRIVATE_CHAT_BODY_SENTINEL');
          create table messages(id integer, body text); insert into messages values(1,'retained message');
          create table jobs(id integer, finished integer); insert into jobs values(1,1),(2,0);
          create table tool_call_logs(id integer, kind text, aged integer);
          insert into tool_call_logs values(1,'FILE-EDIT',1),(2,'SHELL',1),(3,'TOOL',1),(4,'SHELL',0);
          create table chat_events(id integer, kind text, tool text, aged integer, image_id integer);
          insert into chat_events values(1,'tool_call','news_search',1,2),(2,'tool_result','news_search',1,2),
            (3,'message','',1,7),(4,'tool_result','shell',0,7);
          create table job_events(id integer, job_id integer, kind text, aged integer);
          insert into job_events values(1,1,'output',1),(2,2,'output',1),(3,1,'status',1);
          create table assets(id integer primary key, filename text, origin text, bytes integer, aged integer, pinned integer, deleted integer default 0);
        """)
        for i, origin, pinned in [(1,"agent_tool",0),(2,"agent_tool",0),(3,"user",0),(4,"unknown",0),
                                  (5,"agent_tool",1),(6,"agent_tool",0),(7,"agent_tool",0)]:
            con.execute("insert into assets values(?,?,?,?,?,?,0)", (i,f"{i}.webp",origin,12,1,pinned))
            if i != 6: (self.uploads / f"{i}.webp").write_bytes(b"FIXTURE_WEBP")
        con.commit(); con.close()

    def tearDown(self):
        self.temp.cleanup()

    def setting(self, key, value):
        self.env["OKBRAINCC_DB_MAINTENANCE_" + key] = value

    def consent(self):
        for key in ("DELETE_IMAGES", "DOWNTIME_ACKNOWLEDGED", "WRITERS_ACKNOWLEDGED", "EXTERNAL_REFERENCES_ACKNOWLEDGED"):
            self.setting(key, "1")

    def run_action(self, action="apply", case=None, expected=0):
        if case: self.env["CASE"] = case
        process = subprocess.run(["bash", str(RUNNERS / f"db-maintenance-{action}.sh")], env=self.env,
                                 text=True, capture_output=True, timeout=30)
        self.assertEqual(process.returncode, expected, process.stdout + process.stderr)
        self.assertNotIn("PRIVATE_CHAT_BODY_SENTINEL", process.stdout)
        self.assertNotIn("PRIVATE_IMAGE_CONTENT_SENTINEL", process.stdout)
        result = [line[len("CC_RESULT "):] for line in process.stdout.splitlines() if line.startswith("CC_RESULT ")]
        return (json.loads(result[-1]) if result else None), process.stdout

    def trace(self):
        path = self.root / "trace"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def count(self, table):
        with sqlite3.connect(self.db) as con: return con.execute("select count(*) from " + table).fetchone()[0]

    def verify_retained(self):
        self.assertEqual(self.count("conversations"), 1)
        self.assertEqual(self.count("messages"), 1)
        self.assertEqual(self.count("jobs"), 2)
        self.assertEqual(self.count("job_events"), 2)
        self.assertEqual(self.count("chat_events"), 2)
        self.assertEqual(self.count("tool_call_logs"), 1)
        for filename in ("3.webp", "4.webp", "5.webp", "7.webp", "untracked-user-upload.png"):
            self.assertTrue((self.uploads / filename).exists())
        self.assertEqual((self.root / "repo/edited.swift").read_text(), "actual repository edits stay")

    def verify_flags(self):
        for command in self.trace():
            if command[0] == "history": self.assertIn("--tool-history-only", command)

    def test_dryrun_readonly_no_stop_zero_actual_deletions(self):
        self.consent()  # Even opted-in settings cannot mutate a Dry Run.
        before = hashlib.sha256(self.db.read_bytes()).digest()
        files = {p.name: p.read_bytes() for p in self.uploads.iterdir()}
        report, output = self.run_action("dry-run")
        self.assertEqual(before, hashlib.sha256(self.db.read_bytes()).digest())
        self.assertEqual(files, {p.name:p.read_bytes() for p in self.uploads.iterdir()})
        self.assertFalse(any(c[0] == "systemctl" for c in self.trace()))
        self.assertEqual(report["images"]["deleted"], 0)
        self.assertEqual(report["images"]["missingFinalized"], 0)
        self.assertEqual(report["history"], "dry_run_zero_deletions")
        self.assertIn("PRE-APPLY CANDIDATES", output)
        self.assertIn("retained_db_reference", output)
        self.verify_flags()

    def test_default_apply_is_preview_no_downtime_and_retains_chats_uploads(self):
        report, output = self.run_action()
        self.assertEqual(report["images"]["mode"], "preview")
        self.assertEqual(report["images"]["deleted"], 0)
        self.assertEqual(report["images"]["candidates"], 2)
        self.assertFalse(any(c[0] == "systemctl" for c in self.trace()))
        self.verify_retained(); self.verify_flags()
        self.assertIn("actual deleted rows/bytes NOT reported", output)

    def test_unconfigured_images_still_cleans_safe_history_with_warning(self):
        self.setting("UPLOADS_DIRECTORY", "")
        report, output = self.run_action()
        self.assertEqual(report["outcome"], "warning")
        self.assertIn("uploads_directory_not_configured", output)
        self.verify_retained(); self.verify_flags()

    def test_opted_in_offline_images_deleted_not_missing_tombstones(self):
        self.consent()
        report, output = self.run_action()
        self.assertEqual(report["images"]["deleted"], 2)
        self.assertEqual(report["images"]["deletedBytes"], 24)
        self.assertEqual(report["images"]["missingFinalized"], 1)
        self.assertEqual(self.count("assets"), 7)  # Tombstones, not deleted rows.
        self.assertFalse((self.uploads / "1.webp").exists())
        self.assertFalse((self.uploads / "2.webp").exists())
        self.assertEqual(json.loads((self.root / "services.json").read_text()), {"brain":"active","fixture-worker":"inactive"})
        self.assertNotIn(["systemctl","start","fixture-worker"], self.trace())
        self.assertIn("images_preapply_readonly_probe_not_sweep_totals", output)
        self.verify_retained(); self.verify_flags()

    def test_vacuum_already_off_never_started(self):
        self.consent(); self.setting("DELETE_IMAGES", "0")
        (self.root / "services.json").write_text(json.dumps({"brain":"inactive","fixture-worker":"inactive"}))
        report, _ = self.run_action("vacuum")
        self.assertEqual(report["images"]["deleted"], 0)
        self.assertFalse(any(c[0] == "systemctl" and c[1] in ("stop","start") for c in self.trace()))
        self.assertTrue(any(c[0] == "history" and "--vacuum" in c for c in self.trace()))
        self.verify_flags()

    def test_vacuum_restores_after_cleanup_failure(self):
        self.consent(); self.setting("DELETE_IMAGES", "0")
        report, _ = self.run_action("vacuum", case="history_failure", expected=2)
        self.assertTrue(report["partial"])
        self.assertEqual(json.loads((self.root / "services.json").read_text())["brain"], "active")
        self.verify_flags()

    def test_old_unknown_unsafe_scope_or_schema_fail_before_deletion(self):
        for case in ("old", "unknown_flag", "unsafe_scope", "schema", "invalid_json", "wrong_mode", "dry_mutation", "scope_mismatch", "missing_image"):
            with self.subTest(case=case):
                report, _ = self.run_action(case=case, expected=2)
                self.assertEqual(report["outcome"], "failed")
                self.assertEqual(self.count("tool_call_logs"), 4)
                self.assertFalse((self.root / "history-applied").exists())
                self.assertFalse(any(c[0] == "systemctl" for c in self.trace()))
        self.verify_flags()

    def test_stop_failure_restores_even_if_stop_changed_state(self):
        self.consent()
        report, _ = self.run_action(case="stop_fail", expected=2)
        self.assertEqual(report["outcome"], "failed")
        self.assertFalse((self.root / "history-applied").exists())
        self.assertEqual(json.loads((self.root / "services.json").read_text())["brain"], "active")
        self.assertIn(["systemctl","start","brain"], self.trace())

    def test_inactive_verification_not_exit_code_alone(self):
        self.consent()
        report, _ = self.run_action(case="stop_lies", expected=2)
        self.assertIn("writer_not_inactive", report["error"])
        self.assertFalse((self.root / "history-applied").exists())

    def test_unknown_service_fails_before_any_stop(self):
        self.consent()
        report, _ = self.run_action(case="unknown_service", expected=2)
        self.assertEqual(report["outcome"], "failed")
        self.assertFalse(any(c[0] == "systemctl" and c[1] == "stop" for c in self.trace()))

    def test_restart_failure_visible_not_success(self):
        self.consent()
        report, _ = self.run_action(case="restart_fail", expected=4)
        self.assertTrue(report["restorationFailed"])
        self.assertEqual(report["outcome"], "partial")

    def test_image_partial_is_nonzero_but_reports_real_counts_and_errors(self):
        self.consent()
        report, _ = self.run_action(case="image_partial", expected=1)
        self.assertEqual(report["images"]["deleted"], 1)
        self.assertEqual(report["images"]["errors"], 1)
        self.assertEqual(report["images"]["reasons"]["file_error"], 1)
        self.assertTrue(report["images"]["cursorCanAdvance"])
        self.assertEqual(report["outcome"], "partial")
        self.assertEqual(json.loads((self.root / "services.json").read_text())["brain"], "active")

    def test_schema_failure_after_history_is_partial_and_restores(self):
        self.consent()
        report, _ = self.run_action(case="schema_after", expected=2)
        self.assertTrue(report["partial"])
        self.assertIn("image_schema_unavailable", report["error"])
        self.assertEqual(json.loads((self.root / "services.json").read_text())["brain"], "active")
        self.assertTrue((self.uploads / "1.webp").exists())

    def test_bounds_resume_past_protected_rows_without_starvation(self):
        self.consent()
        with sqlite3.connect(self.db) as con:
            con.execute("delete from assets")
            for i in range(1, 351):
                con.execute("insert into assets values(?,?,?,?,1,0,0)", (i,f"large-{i}.webp","user" if i <= 300 else "agent_tool",12))
                (self.uploads / f"large-{i}.webp").write_bytes(b"FIXTURE_WEBP")
        report, _ = self.run_action()
        self.assertEqual(report["images"]["examined"], 300)
        self.assertEqual(report["images"]["deleted"], 0)
        self.assertEqual(report["outcome"], "incomplete")
        self.assertEqual(report["images"]["nextAfterID"], "300")
        self.setting("AFTER_ID", report["images"]["nextAfterID"])
        report, _ = self.run_action()
        self.assertEqual(report["images"]["deleted"], 50)
        self.assertTrue(report["images"]["sweepComplete"])
        self.assertTrue((self.uploads / "large-1.webp").exists())

    def test_stalled_cursor_blocks_no_false_complete(self):
        self.setting("AFTER_ID", "1")
        report, _ = self.run_action("dry-run", case="stall", expected=2)
        self.assertFalse(report["images"]["cursorCanAdvance"])
        self.assertIn("stalled", report["error"])

    def test_malicious_settings_rejected_before_ssh(self):
        for key, value in [("REMOTE_HOST","-oProxyCommand=touch sentinel"), ("REMOTE_HOST","fixture;touch sentinel"),
                           ("RETENTION_DAYS","10;touch sentinel"), ("DATABASE","/tmp/../live.db"),
                           ("WRITER_SERVICES","brain;touch-sentinel"), ("DELETE_IMAGES","yes")]:
            original = self.env.get("OKBRAINCC_DB_MAINTENANCE_" + key)
            self.setting(key, value)
            self.run_action(expected=2)
            self.assertEqual(self.trace(), [])
            if original is None: self.env.pop("OKBRAINCC_DB_MAINTENANCE_" + key)
            else: self.setting(key, original)

    def test_deletion_requires_every_ack_and_explicit_path(self):
        self.consent()
        for key in ("DOWNTIME_ACKNOWLEDGED", "WRITERS_ACKNOWLEDGED", "EXTERNAL_REFERENCES_ACKNOWLEDGED", "UPLOADS_DIRECTORY"):
            original = self.env["OKBRAINCC_DB_MAINTENANCE_" + key]
            self.setting(key, "" if key == "UPLOADS_DIRECTORY" else "0")
            self.run_action(expected=2)
            self.assertEqual(self.trace(), [])
            self.setting(key, original)

    def signal_flow(self, case, kill_parent=False, vacuum=False, check_lock=False):
        self.consent(); self.env["CASE"] = case
        action = "vacuum" if vacuum else "apply"
        process = subprocess.Popen(["bash", str(RUNNERS / f"db-maintenance-{action}.sh")], env=self.env,
                                   text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic()+15
            while not (self.root / "hanging").exists() and time.monotonic()<deadline: time.sleep(0.05)
            self.assertTrue((self.root / "hanging").exists(), "fixture never reached signal point")
            if check_lock:
                report, _ = self.run_action("dry-run", expected=2)
                self.assertIn("database_lock", report["error"])
            if kill_parent: process.kill()
            else: process.terminate()
            output, _ = process.communicate(timeout=20)
            reports = [json.loads(s[len("CC_RESULT "):]) for s in output.splitlines() if s.startswith("CC_RESULT ")]
            self.assertTrue(reports, output)
            self.assertEqual(reports[-1]["outcome"], "stopped", output)
            self.assertEqual(json.loads((self.root / "services.json").read_text()), {"brain":"active","fixture-worker":"inactive"})
            self.assertNotIn(["systemctl","start","fixture-worker"], self.trace())
            self.verify_flags()
        finally:
            if process.poll() is None:
                process.terminate()
            process.communicate(timeout=20)

    def test_signal_during_stop_restores(self): self.signal_flow("signal_stop")
    def test_signal_during_vacuum_restores(self): self.signal_flow("signal_history", vacuum=True)
    def test_signal_during_images_and_cooperative_lock(self): self.signal_flow("signal_images", check_lock=True)
    def test_parent_death_stdin_watchdog_restores(self): self.signal_flow("signal_images", kill_parent=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
