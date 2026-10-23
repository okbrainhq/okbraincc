#!/usr/bin/env python3
"""Versioned CC retention engine. Runs from the app bundle over SSH, never installs/migrates.
Only Code Project tool history, web-search tool history, and proven Code Project images
expire. No message/conversation/text-output deletion. UTC ages are compared by SQLite.
"""
import base64
import collections
import hashlib
import html
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import stat
import sys
import time
import urllib.parse

WEB_TOOLS = {"internet_search", "internet_search_premium", "news_search", "image_search", "read_url"}
UUID = re.compile(r"[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}", re.I)
IMAGE_NAME = re.compile(UUID.pattern + r"\.(?:webp|png|jpe?g|gif)\Z", re.I)
REQUIRED = {
    "conversations": {"id", "user_id", "code_project_id", "active_job_id"},
    "messages": {"id", "conversation_id", "content"},
    "chat_events": {"id", "conversation_id", "kind", "content", "created_at"},
    "tool_call_logs": {"id", "conversation_id", "tool_call_id", "tool_name", "status", "created_at", "updated_at", "parent_job_id", "async_job_id"},
    "jobs": {"id", "state", "type"},
    "job_queue": {"job_id", "input"},
    "job_events": {"id", "job_id", "kind", "payload", "created_at"},
    "conversation_tool_jobs": {"id", "conversation_id", "job_id", "tool_name", "state", "updated_at", "output", "error"},
    "uploads": {"id", "user_id", "filename", "created_at", "owner_conversation_id", "storage_root", "image_sha256", "image_bytes", "deleted_at", "deletion_reason", "retention_pin", "job_id"},
}


class Unsafe(Exception):
    pass


def qi(value):
    return '"' + value.replace('"', '""') + '"'


def tool_name(value):
    return value.removeprefix("functions.") if isinstance(value, str) else ""


def payload_name(value):
    try:
        data = json.loads(value)
        return tool_name(data.get("tool_name", "")) if isinstance(data, dict) else ""
    except (ValueError, TypeError):
        return ""


def payload_call(value):
    try:
        data = json.loads(value)
        return str(data.get("call_id", "")) if isinstance(data, dict) else ""
    except (ValueError, TypeError):
        return ""


def normalized(value):
    for _ in range(64):
        new = html.unescape(urllib.parse.unquote(value)).replace("\\/", "/")
        new = re.sub(r"\\u([0-9a-fA-F]{4})", lambda m: chr(int(m[1], 16)), new)
        if new == value:
            return new.lower()
        value = new
    raise Unsafe("reference_encoding_too_deep")


def open_directory(path):
    # Reject symlinks in every component; never derive a filesystem path from chat text.
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for part in Path(path).parts[1:]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
        return fd
    except BaseException:
        os.close(fd)
        raise


def identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_nlink, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def inspect_image(root, row):
    try:
        fd = os.open(row["filename"], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=root)
    except FileNotFoundError:
        return None
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or not 12 <= info.st_size <= 50 * 1024 * 1024:
            raise Unsafe("unsafe_image_file")
        data = bytearray()
        while len(data) <= info.st_size:
            chunk = os.read(fd, min(65536, info.st_size + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
        if len(data) != info.st_size or identity(info) != identity(os.fstat(fd)):
            raise Unsafe("image_changed")
        extension = row["filename"].lower().rsplit(".", 1)[1]
        valid = {"webp": data[:4] == b"RIFF" and data[8:12] == b"WEBP" and int.from_bytes(data[4:8], "little") + 8 == len(data),
                 "png": data[:8] == b"\x89PNG\r\n\x1a\n", "jpg": data[:3] == b"\xff\xd8\xff",
                 "jpeg": data[:3] == b"\xff\xd8\xff", "gif": data[:6] in (b"GIF87a", b"GIF89a")}[extension]
        if not valid:
            raise Unsafe("not_an_image")
        if row["image_sha256"] and hashlib.sha256(data).hexdigest() != row["image_sha256"]:
            raise Unsafe("image_hash_mismatch")
        if row["image_bytes"] is not None and row["image_bytes"] != info.st_size:
            raise Unsafe("image_size_mismatch")
        return fd, info
    except BaseException:
        os.close(fd)
        raise


class Retention:
    def __init__(self, config):
        self.c = config
        self.db = None
        self.deadline = time.monotonic() + 900
        self.changed = False
        self.report = dict(outcome="failed", history="not_run", images=None, restorationFailed=False,
                           partial=False, error=None, historyCounts={}, databaseCheck=None, compaction=None)

    def progress(self, message):
        # Metadata only: never include chat content, image filenames, or tool payloads.
        print('CC_PROGRESS ' + message, flush=True)

    def check_budget(self):
        if time.monotonic() > self.deadline:
            raise Unsafe("maintenance_time_budget_exceeded")

    def connect(self, apply):
        path = self.c["database"]
        if os.path.realpath(path) != path or not stat.S_ISREG(os.lstat(path).st_mode):
            raise Unsafe("database_not_canonical_regular_file")
        self.db = sqlite3.connect(Path(path).as_uri() + ("?mode=rw" if apply else "?mode=ro"),
                                  uri=True, isolation_level=None, timeout=1)
        self.db.row_factory = sqlite3.Row
        self.db.create_function("web_tool", 1, lambda n: int(tool_name(n) in WEB_TOOLS), deterministic=True)
        self.db.create_function("event_tool", 1, payload_name, deterministic=True)
        self.db.create_function("event_call", 1, payload_call, deterministic=True)
        self.db.set_progress_handler(lambda: int(time.monotonic() > self.deadline), 10000)
        self.db.execute("PRAGMA foreign_keys=ON")
        if apply and self.c["action"] != "vacuum":
            if self.db.execute("PRAGMA journal_mode").fetchone()[0] != "wal":
                raise Unsafe("online_requires_wal")
            self.db.execute("PRAGMA wal_autocheckpoint=0")
            # Suppress a surprise blocking last-connection checkpoint when supported.
            if hasattr(self.db, "setconfig") and hasattr(sqlite3, "SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE"):
                self.db.setconfig(sqlite3.SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, True)
        self.tables = {r["name"]: r["sql"] or "" for r in self.db.execute("SELECT name,sql FROM sqlite_master WHERE type='table'")}
        for table, expected in REQUIRED.items():
            columns = {r["name"] for r in self.db.execute(f"PRAGMA table_info({qi(table)})")}
            if not expected <= columns:
                raise Unsafe("unsupported_schema:" + table)
        # Defence in depth: triggers/cascades cannot turn a log prune into a chat deletion.
        def authorize(action, table, column, database, trigger):
            if database == "main":
                if action == sqlite3.SQLITE_DELETE and table not in {"tool_call_logs", "chat_events", "job_events"}:
                    return sqlite3.SQLITE_DENY
                if action == sqlite3.SQLITE_UPDATE and (table, column) not in {
                    ("uploads", "deleted_at"), ("uploads", "deletion_reason"),
                    ("conversation_tool_jobs", "output"), ("conversation_tool_jobs", "error")
                }:
                    return sqlite3.SQLITE_DENY
                if action in (sqlite3.SQLITE_INSERT, sqlite3.SQLITE_DELETE, sqlite3.SQLITE_UPDATE) and trigger:
                    return sqlite3.SQLITE_DENY
            return sqlite3.SQLITE_OK
        self.authorize = authorize
        self.progress("Checking database integrity…")
        result = [r[0] for r in self.db.execute("PRAGMA quick_check")]
        if result != ["ok"]:
            raise Unsafe("database_quick_check_failed")
        self.report["databaseCheck"] = "ok"
        self.progress("Database check passed.")
        # One UTC cutoff for this execution (SQLite handles both ISO and SQLite UTC encodings).
        self.cutoff = self.db.execute("SELECT julianday('now', ?)", (f"-{self.c['days']} days",)).fetchone()[0]

    def selection(self):
        db = self.db
        db.executescript("""
            CREATE TEMP TABLE cp AS SELECT id, user_id FROM conversations WHERE NULLIF(code_project_id,'') IS NOT NULL;
            CREATE UNIQUE INDEX temp.cp_id ON cp(id);
            CREATE TEMP TABLE busy AS SELECT c.id FROM conversations c JOIN jobs j ON j.id=c.active_job_id
                WHERE j.state IN ('running','stopping');
            CREATE UNIQUE INDEX temp.busy_id ON busy(id);
            CREATE TEMP TABLE web_calls AS
                SELECT conversation_id, tool_call_id AS call_id FROM tool_call_logs WHERE web_tool(tool_name)
                UNION SELECT conversation_id,event_call(content) FROM chat_events
                WHERE kind='tool_call' AND web_tool(event_tool(content));
            CREATE INDEX temp.web_call_key ON web_calls(conversation_id,call_id);
        """)
        self.predicates = {
            "tool_call_logs": """julianday(created_at) < :cutoff AND julianday(updated_at) < :cutoff
                AND (conversation_id IN (SELECT id FROM conversations WHERE NULLIF(code_project_id,'') IS NOT NULL) OR web_tool(tool_name))
                AND conversation_id NOT IN (SELECT id FROM busy)
                AND NOT EXISTS (SELECT 1 FROM jobs WHERE id=tool_call_logs.parent_job_id AND state IN ('running','stopping'))""",
            "chat_events": """kind IN ('tool_call','tool_result') AND julianday(created_at) < :cutoff
                AND conversation_id NOT IN (SELECT id FROM busy)
                AND (conversation_id IN (SELECT id FROM conversations WHERE NULLIF(code_project_id,'') IS NOT NULL) OR web_tool(event_tool(content)) OR EXISTS
                    (SELECT 1 FROM web_calls w WHERE w.conversation_id=chat_events.conversation_id
                     AND w.call_id != '' AND w.call_id=event_call(chat_events.content)))""",
            "conversation_tool_jobs": """julianday(updated_at) < :cutoff AND state IN ('succeeded','failed','stopped','timeout')
                AND (conversation_id IN (SELECT id FROM conversations WHERE NULLIF(code_project_id,'') IS NOT NULL) OR web_tool(tool_name))
                AND conversation_id NOT IN (SELECT id FROM busy)
                AND NOT EXISTS (SELECT 1 FROM jobs WHERE id=conversation_tool_jobs.job_id AND state IN ('running','stopping'))""",
        }
        # Only dedicated tool job output, NEVER blanket terminal-job output (which includes chat text).
        db.execute("""CREATE TEMP TABLE tool_jobs AS SELECT j.id FROM jobs j WHERE j.state IN ('succeeded','failed','stopped')
            AND (j.type IN ('code-project-shell','code-project-screenshot') OR
                (j.type IN ('persistent-shell','shell-command','run-app') AND EXISTS
                    (SELECT 1 FROM conversation_tool_jobs t WHERE t.job_id=j.id AND
                     (t.conversation_id IN (SELECT id FROM conversations WHERE NULLIF(code_project_id,'') IS NOT NULL) OR web_tool(t.tool_name)))))""")
        db.execute("CREATE UNIQUE INDEX temp.tool_job_id ON tool_jobs(id)")
        self.predicates["job_events"] = "kind='output' AND julianday(created_at)<:cutoff AND job_id IN (SELECT id FROM tool_jobs)"

    def history(self, apply):
        db = self.db
        for table, predicate in self.predicates.items():
            if table == "conversation_tool_jobs":
                predicate += " AND (output IS NOT NULL OR error IS NOT NULL)"
            candidates = db.execute(f"SELECT COUNT(*) FROM {table} WHERE {predicate}", {"cutoff": self.cutoff}).fetchone()[0]
            actual = 0
            self.report["historyCounts"][table] = {"candidates": candidates, "deleted": 0}
            self.progress(f"{table}: {candidates} expired tool-history candidates.")
            if apply:
                # Short batches, re-evaluated under the writer lock; no long exclusive delete.
                while True:
                    self.check_budget()
                    db.execute("BEGIN IMMEDIATE")
                    try:
                        # A conversation may have become active since selection().
                        live = ""
                        if table != "job_events":
                            live = f" AND NOT EXISTS (SELECT 1 FROM conversations c JOIN jobs j ON j.id=c.active_job_id WHERE c.id={table}.conversation_id AND j.state IN ('running','stopping'))"
                        else:
                            live = " AND NOT EXISTS (SELECT 1 FROM jobs j WHERE j.id=job_events.job_id AND j.state NOT IN ('succeeded','failed','stopped'))"
                        ids = [r[0] for r in db.execute(f"SELECT id FROM {table} WHERE {predicate}{live} LIMIT 500", {"cutoff": self.cutoff})]
                        if not ids:
                            db.execute("COMMIT")
                            break
                        marks = ','.join('?' for _ in ids)
                        db.set_authorizer(self.authorize)
                        try:
                            sql = (f"UPDATE {table} SET output=NULL,error=NULL" if table == "conversation_tool_jobs" else f"DELETE FROM {table}") + f" WHERE id IN ({marks})"
                            count = db.execute(sql, ids).rowcount
                        finally:
                            db.set_authorizer(lambda *_: sqlite3.SQLITE_OK)
                        db.execute("COMMIT")
                        actual += count
                        self.report["historyCounts"][table]["deleted"] = actual
                        self.changed = self.changed or count > 0
                        self.progress(f"{table}: {actual} records removed/cleared (committed).")
                    except BaseException:
                        if db.in_transaction:
                            db.execute("ROLLBACK")
                        raise
            self.report["historyCounts"][table] = {"candidates": candidates, "deleted": actual}
        self.report["history"] = "scoped_history_applied" if apply else "dry_run_zero_deletions"

    def image_plan(self):
        db = self.db
        self.progress("Scanning image ownership and protected references…")
        # Snapshot reference discovery BEFORE pruning logs; legacy upload ownership must not be lost.
        version = db.execute("PRAGMA data_version").fetchone()[0]
        db.execute("BEGIN")
        try:
            rows = [dict(r) for r in db.execute("SELECT * FROM uploads WHERE deleted_at IS NULL AND julianday(created_at) < ?", (self.cutoff,))
                    if isinstance(r['filename'], str) and IMAGE_NAME.fullmatch(r['filename'])]
            tokens = collections.defaultdict(set)
            for row in rows:
                for token in (row['id'], row['filename'].rsplit('.', 1)[0]):
                    tokens[token.lower()].add(row['id'])
            cp = dict(db.execute("SELECT id,user_id FROM conversations WHERE NULLIF(code_project_id,'') IS NOT NULL"))
            busy = {r[0] for r in db.execute("SELECT c.id FROM conversations c JOIN jobs j ON j.id=c.active_job_id WHERE j.state IN ('running','stopping')")}
            owners, protected = collections.defaultdict(set), {}
            for r in rows:
                cid = r['owner_conversation_id']
                if cid in cp and cp[cid] == r['user_id']:
                    owners[r['id']].add(cid)
                elif cid:
                    protected[r['id']] = 'non_project_owner'
                if r['retention_pin'] is not None:
                    protected[r['id']] = 'retention_pin'
                if r['storage_root'] and r['storage_root'] != self.c['uploads']:
                    protected[r['id']] = 'storage_root_mismatch'
            by_id = {r['id']: r for r in rows}
            job_conversations = collections.defaultdict(set)
            for r in db.execute("SELECT job_id,conversation_id FROM conversation_tool_jobs UNION SELECT async_job_id,conversation_id FROM tool_call_logs WHERE async_job_id IS NOT NULL"):
                job_conversations[r[0]].add(r[1])
            # Durable job inputs retain the chat link after tool logs have expired.
            # Extract only the scalar identifier in SQLite, not whole prompts into Python.
            for r in db.execute("SELECT job_id,CASE WHEN json_valid(input) THEN json_extract(input,'$.conversationId') END FROM job_queue"):
                if isinstance(r[1], str) and r[1]:
                    job_conversations[r[0]].add(r[1])
            # Skip only derived search/vector stores; canonical text remains scanned once per sweep.
            derived = set()
            for table, sql in self.tables.items():
                if re.search(r'CREATE\s+VIRTUAL\s+TABLE', sql, re.I):
                    if table not in {'fact_vec','events_fts','documents_fts'}:
                        raise Unsafe('unknown_reference_store')
                    derived.add(table)
                    derived.update(t for t in self.tables if t.startswith(table + '_'))
            for table in self.tables:
                if table.startswith('sqlite_') or table in derived or not tokens:
                    continue
                columns = [r['name'] for r in db.execute(f'PRAGMA table_info({qi(table)})') if not any(t in r['type'].upper() for t in ('BLOB','VECTOR'))]
                if not columns:
                    continue
                self.progress("Checking references in " + table)
                for record in db.execute(f"SELECT {','.join(map(qi,columns))} FROM {qi(table)}"):
                    self.check_budget()
                    record = dict(record)
                    matched = set()
                    for value in record.values():
                        if isinstance(value, str):
                            for token in UUID.findall(normalized(value)):
                                matched.update(tokens.get(token, ()))
                    if table == 'uploads':
                        matched.discard(record['id'])
                    if not matched:
                        continue
                    cids = {record['conversation_id']} if table in {'messages','chat_events','tool_call_logs','conversation_tool_jobs'} else (
                        job_conversations.get(record.get('job_id'), set()) if table in {'job_events','job_queue'} else set())
                    for uid in matched:
                        if cids and all(cid in cp and cp[cid] == by_id[uid]['user_id'] for cid in cids):
                            owners[uid].update(cids)
                        else:
                            protected[uid] = 'reference_outside_code_projects:' + table
            eligible = []
            reasons = collections.Counter()
            for row in rows:
                reason = protected.get(row['id'])
                if not reason and not owners[row['id']]:
                    reason = 'unproven_project_ownership'
                if not reason and owners[row['id']] & busy:
                    reason = 'active_project_chat'
                if not reason and row['job_id'] and db.execute("SELECT 1 FROM jobs WHERE id=? AND state IN ('running','stopping')", (row['job_id'],)).fetchone():
                    reason = 'active_image_job'
                if reason:
                    reasons[reason] += 1
                else:
                    eligible.append(row)
            self.progress(f"Image inventory: {len(rows)} examined, {len(eligible)} eligible, {sum(reasons.values())} protected.")
            return version, len(rows), eligible, dict(reasons)
        finally:
            db.execute("COMMIT")

    def images(self, plan, apply):
        version, examined, rows, reasons = plan
        summary = dict(mode='online-apply' if apply else 'preview', batches=0, examined=examined,
                       candidates=0, candidateBytes=0, deleted=0, deletedBytes=0, missingFinalized=0,
                       errors=0, reasons=reasons, nextAfterID=None, sweepComplete=False,
                       cursorCanAdvance=False, unconfirmedBatch=False)
        self.report['images'] = summary
        root = open_directory(self.c['uploads'])
        try:
            for offset in range(0, len(rows), 50):
                self.check_budget()
                batch = []
                try:
                    for row in rows[offset:offset+50]:
                        try:
                            opened = inspect_image(root, row)
                            batch.append((row, opened))
                            summary['candidates'] += 1
                            summary['candidateBytes'] += opened[1].st_size if opened else 0
                        except (Unsafe, OSError) as error:
                            reason = str(error) if isinstance(error, Unsafe) else 'image_file_unavailable'
                            summary['reasons'][reason] = summary['reasons'].get(reason, 0) + 1
                            summary['errors'] += 1
                    summary['batches'] += 1
                    if not apply:
                        self.progress(f"Image preview: {summary['candidates']} candidates checked; zero deletions.")
                        continue
                    self.db.execute('BEGIN IMMEDIATE')
                    try:
                        if self.db.execute('PRAGMA data_version').fetchone()[0] != version:
                            raise Unsafe('image_snapshot_changed_retry')
                        deleted = missing = size = 0
                        for row, opened in batch:
                            self.check_budget()
                            try:
                                current = os.stat(row['filename'], dir_fd=root, follow_symlinks=False)
                            except FileNotFoundError:
                                current = None
                            if (opened is None) != (current is None) or opened and identity(current) != identity(opened[1]):
                                raise Unsafe('image_changed_before_unlink')
                            if opened:
                                summary['unconfirmedBatch'] = True
                                os.unlink(row['filename'], dir_fd=root)
                                deleted += 1
                                size += opened[1].st_size
                            else:
                                missing += 1
                            self.db.set_authorizer(self.authorize)
                            try:
                                count = self.db.execute("UPDATE uploads SET deleted_at=strftime('%Y-%m-%dT%H:%M:%fZ','now'),deletion_reason='code-project-retention-v3' WHERE id=? AND deleted_at IS NULL", (row['id'],)).rowcount
                                if count != 1:
                                    raise Unsafe('image_tombstone_unconfirmed')
                            finally:
                                self.db.set_authorizer(lambda *_: sqlite3.SQLITE_OK)
                        self.db.execute('COMMIT')
                        summary['deleted'] += deleted
                        summary['deletedBytes'] += size
                        summary['missingFinalized'] += missing
                        summary['unconfirmedBatch'] = False
                        self.changed = self.changed or deleted + missing > 0
                        self.progress(f"Images: {summary['deleted']} removed, {summary['deletedBytes']} bytes reclaimed, {summary['missingFinalized']} missing finalized (committed).")
                    except BaseException:
                        if self.db.in_transaction:
                            self.db.execute('ROLLBACK')
                        raise
                finally:
                    for _, opened in batch:
                        if opened:
                            os.close(opened[0])
            summary['sweepComplete'] = True
        finally:
            os.close(root)

    def compact(self, vacuum=False):
        db = self.db
        if vacuum:
            # SQLite VACUUM recreates virtual tables and therefore needs the app's installed vec0 extension.
            if 'fact_vec' in self.tables:
                paths = [Path('/var/www/brain/node_modules/sqlite-vec-linux-x64/vec0.so'),
                         Path('/var/www/brain/node_modules/sqlite-vec-linux-arm64/vec0.so')]
                extension = next((p for p in paths if p.is_file()), None)
                if extension is None:
                    raise Unsafe('vacuum_requires_installed_sqlite_vec_extension')
                db.enable_load_extension(True)
                try:
                    db.load_extension(str(extension))
                finally:
                    db.enable_load_extension(False)
            size = db.execute('PRAGMA page_count').fetchone()[0] * db.execute('PRAGMA page_size').fetchone()[0]
            if shutil.disk_usage(Path(self.c['database']).parent).free < 2 * size:
                raise Unsafe('vacuum_insufficient_free_disk_space')
            self.progress('Vacuuming database (writers stopped)…')
            db.execute('VACUUM')
            self.changed = True
        self.progress('Optimizing database and checkpointing WAL…')
        db.execute('PRAGMA analysis_limit=1000')
        db.execute('PRAGMA optimize')
        checkpoint = list(db.execute('PRAGMA wal_checkpoint(' + ('TRUNCATE' if vacuum else 'PASSIVE') + ')').fetchone())
        self.report['compaction'] = 'vacuum' if vacuum else 'optimize-passive-checkpoint'
        self.report['checkpoint'] = checkpoint
        self.progress('Checkpoint finished: busy=%s, WAL pages=%s, checkpointed=%s.' % tuple(checkpoint))
        if vacuum and checkpoint[0]:
            raise Unsafe('vacuum_checkpoint_busy')

    def run(self):
        apply = self.c['action'] != 'dryRun'
        try:
            self.connect(apply)
            if self.c['action'] == 'vacuum':
                self.compact(vacuum=True)
                self.report['history'] = 'not_run_vacuum_only'
            else:
                self.selection()
                plan = self.image_plan() if self.c['deleteImages'] else None
                self.history(apply)
                image_error = None
                if plan is not None:
                    try:
                        self.images(plan, apply)
                    except Exception as error:
                        image_error = error
                # A contended image pass must not starve daily DB optimization/checkpointing.
                if apply:
                    self.compact()
                if image_error:
                    raise image_error
            self.report['outcome'] = 'warning' if self.report['images'] and self.report['images']['errors'] else 'success'
            return 0
        except Exception as error:
            reason = str(error) if isinstance(error, Unsafe) else 'retention_error:' + type(error).__name__
            unconfirmed = bool(self.report['images'] and self.report['images']['unconfirmedBatch'])
            self.report.update(outcome='partial' if self.changed or unconfirmed else 'failed',
                               partial=self.changed or unconfirmed, error=reason)
            return 2
        finally:
            if self.db:
                self.db.close()
            print('CC_RESULT ' + json.dumps(self.report, sort_keys=True), flush=True)


if __name__ == '__main__':
    sys.exit(Retention(json.loads(base64.b64decode(sys.argv[1]))).run())
