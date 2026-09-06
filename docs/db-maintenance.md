# DB Maintenance: automatic online history and agent-image cleanup

## Policy, schedule and migration

The existing `DBMaintenanceStore` timer runs **Dry Run → Apply online**, cleaning aged tool execution history and eligible agent images without stopping Brain. There is no parallel image job. Source defaults remain **enabled, every 1440 minutes (24 hours), older than 10 days**. Existing `dbMaintenance.scheduleEnabled`, `scheduleIntervalMinutes`, `retentionDays`, `remoteHost`, and last-attempt settings keep their values and interval-based behavior. An explicitly disabled schedule stays disabled. Vacuum is separate, manual/offline, and never scheduled or run on startup.

Image cleanup is **enabled automatically**, under the user's explicit authorization; no additional confirmation, typed phrase, downtime permission, writer audit or external-reference acknowledgement is required for online Apply. Normal daily history Apply was already online; this replaces the previous offline image opt-in, not the existing online history behavior.

Settings migration lives in the Store, not in audit decoding:

- `dbMaintenance.safety.v2` is the versioned policy/migration marker. When absent, import v1 settings and replace the old preview-only `deleteImages=false` policy with automatic online cleanup.
- Missing/blank/whitespace-only uploads roots use the source default **`/var/www/brain-data/uploads`**. Existing nonblank custom roots, DB paths, hosts, writer settings and schedule customizations are preserved. Saving a blank root also uses that default, rather than silently disabling images.
- The UI keeps a normal image-cleanup switch. An explicit v2 disabling is preserved on later launches; migration does not repeatedly enable it. Scope edits do not disable online images. Host/DB/service edits revoke only manual Vacuum acknowledgements.
- Legacy settings data and persisted run configurations are not rewritten into the new policy. Old run JSON, including v1 preview/offline settings and reports, remains decodable and truthful. New run configurations explicitly record `imagePolicyVersion=2` and the frozen schedule interval/enabled state.

## Scope and backend dependency

Only aged FILE-EDIT/SHELL/TOOL execution records, tool-call/result chat events and finished-job output are history targets. **Conversations, messages, jobs, actual repository edits/files and user uploads are not deletion targets.** Image deletion is limited to backend-proven agent assets: both upload age AND owning conversation/recent activity must be older than the configured retention, with inactive jobs. User/unknown/legacy, shared, pinned and retained-reference images remain protected.

CC does not reimplement selection, provenance, schema migration or image deletion. It requires the released Brain history CLI's safe tool-history scope and the new sibling image CLI's **`--online`** support. The online backend requires WAL plus Python `sqlite3.setconfig` / `SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE` support (to avoid a hidden checkpoint on close), and owns schema/reference/hash preparation and short validated critical sections. CC neither switches journal modes nor bypasses backend checks. Source availability is not proof of deployment; no production release or compatibility claim is made by these fixtures.

Required counterpart files:

- `/var/www/brain/scripts/deploy/cleanup-old-execution-history.sh` advertising `--tool-history-only`, `--db`, `--days`, `--apply`, `--no-checkpoint` for online Apply, and `--vacuum` for manual Vacuum.
- `/var/www/brain/scripts/deploy/cleanup-agent-images.py` advertising `--db`, `--uploads-dir`, `--days`, `--batch-size`, `--after-id`, `--apply`, **`--online`**, with the existing JSON counters/items/reasons/`next_after_id` contract, `mode: "apply"` and `execution_mode: "online"` for online Apply.
- The counterpart provenance schema. CC does not backfill unknown assets into agent provenance or perform remote migrations.

Local/remote Python, SSH, DB access and correct uploads ownership are still operational dependencies, not additional user opt-ins. CC checks existing canonical DB/root paths; the counterpart's exact per-row `storage_root`, hash, ownership and reference checks remain authoritative. Wrong/unavailable paths must fail or preserve/report protected rows, never authorize deletion in another directory.

## Invocation and online/offline separation

The three shell entry points `exec` the shared Python transport. Settings travel as base64 JSON through SSH; paths are argv, never shell source. The target is a validated alias/hostname or user@hostname, not SSH options. No legacy fallback or convenience image delegation is used.

- History preview: `bash CLEANUP --tool-history-only --db DB --days N`.
- Online history Apply: the same command plus **`--apply --no-checkpoint`**, avoiding an explicit TRUNCATE checkpoint while Brain is running. Its capability is checked before mutation. Manual Vacuum remains `--apply --vacuum`, without `--no-checkpoint`.
- Image preview: `python3 IMAGE_CLI --db DB --uploads-dir ROOT --days N --batch-size 100 [--after-id CURSOR]`.
- **Online image Apply:** the same image command plus **`--apply --online`**. Never `--offline`, `--confirm-app-db-scope` or any consent flag.

Preflight checks the exact advertised `--online` flag, safe history scope, image schema/report and root before mutation. An old/incompatible CLI, invalid report or failed preflight blocks Apply before history/image changes; no offline/legacy retry is attempted. Apply repeats its read-only preflight under the existing advisory lock on the DB parent-directory inode (no remote progress/lock-file writes). This lock cooperates only with updated CC runners, not arbitrary Brain writers; the online image CLI owns live-writer concurrency safety.

**Dry Run and normal Apply perform no service queries, `systemctl`, `sudo`, stop/start or offline permission checks**, even when old writer settings/permissions are invalid or unavailable. The UI directly presents automatic online cleanup and **Apply + Images (online)**, with no image approval dialog. Logs explicitly say **`online; Brain not stopped`**, the frozen schedule/retention policy, and the actual cutoff reported by each CLI.

### Manual Vacuum only

Vacuum retains a separate manual confirmation, downtime and all-writers-controlled requirements. It snapshots configured units, accepts only loaded/stable active or inactive states, stops and verifies writers, runs history cleanup/compaction, and restores only previously active services. Stop/state/restart failures remain non-success outcomes. Default stop/start commands retain `sudo -n /bin/systemctl stop brain` / `start brain`; other units need their own reviewed permissions. Images are **preview-only during Vacuum**, even if normal online cleanup is enabled. Vacuum never changes that saved image policy.

Stop/CC quit uses the existing bounded cancellation protocol over SSH stdin: terminate the cleanup child process group, then restore writers only for Vacuum. Heartbeat/EOF detection also handles parent death. Online cancellation does not query or restore services. Missing terminal reports or interrupted deleting batches remain unconfirmed/possibly partial; logging failures block phase advancement and request cancellation. Host loss/SIGKILL cannot be reported as safely recovered.

## Reports, persistence, bounded progress and deferral

A paired Dry Run and Apply use one immutable host/DB/root/retention/policy/schedule/start-cursor configuration. Edits affect later runs. The CLIs compute cutoff at execution time; Dry Run is not an exact frozen deletion manifest. History pruning may remove references and change post-prune image eligibility, so preflight candidates are not presented as actual deletions.

Persistent metadata-only `.json` and complete `.log` audit files remain in:

- Production: `~/okbraincc-db-maintenance/runs/<run-id>.{json,log}`
- Development: `~/okbraincc-db-maintenance-dev/runs/<run-id>.{json,log}`

Audit retention uses the existing retention setting. Logs are not silently truncated at 120,000 characters. Known history table metadata and allowlisted image metadata/reasons are retained; chat/image bodies and arbitrary CLI diagnostics are not forwarded.

History output is labelled **pre-Apply candidate rows / approximate payload**. `chat_events.news_search` overlaps tool-history rows and is never summed. Dry Run actual deletions are zero. Apply reports history command outcome but does not invent actual history deleted-row/byte counters absent from the backend.

Image reports retain per-batch inventory, examined/candidate/deleted counts and bytes, missing-file finalizations, errors, item IDs/filenames, protection reasons, reference-scan bytes and continuation. Candidate estimates and **confirmed actual deletions** remain distinct. The backend counts only confirmed tombstone commits; `unconfirmed-*` item/reason metadata identifies an unlink whose later commit failed and whose provenance remains for retry. Missing finalizations are tombstones, not deleted files. CC validates and retains full partial-exit reports rather than discarding their confirmed counts. Interrupted/invalid reports and explicit unconfirmed unlinks are marked **unconfirmed**; confirmed totals never account for unknown changes.

Each sweep remains bounded to **3 × 100 rows**, plus a distinct 100-row read-only probe before Apply. Inventory does not mean the entire uploads directory was processed. New preview and `online-apply` cursors are separate, scoped by policy version/host/DB/root/retention/mode under **`dbMaintenance.imageSweepCursors.v2`**. Obsolete v1 preview/offline cursors are not adopted. A paired Dry Run never consumes the Apply cursor. Only successful online runs advance their saved cursor. Any nonzero online exit, including per-file exit 1, keeps the entire run's original cursor and never marks the sweep complete, even when earlier batches committed successfully. Reaching the end resets the cursor for a later sweep, not a permanent assertion that all images are clean.

The frozen online failure report uses exit 2, `mode: "apply"`, `execution_mode: "online"`, `errors >= 1`, normal numeric/item/reason metadata, and `next_after_id` repeating the input cursor (including `""` at the start). Repeated cursors on failed batches are intentional, not a stalled-success error. CC recognizes these exact blocked reasons:

- `online-db-busy`, `online-snapshot-changed`, `online-lock-budget-exceeded`, `online-run-budget-exceeded`: **Deferred / retry next cycle** when the full verified report contains no confirmed image deletion/finalization or unconfirmed unlink. If some image work committed or is unconfirmed, report **partial**, not a clean deferral.
- `cancelled:SIGTERM`, `cancelled:SIGINT`: stopped, with verified counters and any unconfirmed metadata preserved.
- `online-requires-wal`: unsupported-mode blocker, **not** ordinary contention; no journal-mode change or offline fallback.
- `online-no-close-checkpoint-control`: operational runtime prerequisite, **not consent or ordinary contention**. The backend needs Python `sqlite3.setconfig` and `SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE` support to suppress hidden close-checkpoints; CC logs that requirement and does not fall back.

History may already have completed before an image deferral, and that remains visible. Partial exit 1/2 reports keep verified counts/bytes, errors, items and protection/unconfirmed reasons, but **never advance the online cursor or mark the sweep complete**. The Store additionally refuses cursor advancement on a nonzero online wrapper exit, even if a summary claims otherwise. Generic blocked responses without a complete verifiable report stay fail-closed/unconfirmed; no counts or safe outcome are inferred from them. The existing last-attempt schedule retries next cycle, with no extra timer, approval or immediate retry loop. Successful retries revisit the same starting cursor and use retained provenance for recovery.

## Focused fixture validation only

```bash
bash scripts/test-db-maintenance.sh
swift build --disable-sandbox --cache-path .build/swiftpm-cache
```

The focused script runs **36 Python integration fixtures** through real wrapper/fake-SSH subprocesses and **17 standalone Swift Store tests**, then checks shell syntax. It uses only disposable SQLite/files and isolated test preference suites, never saved live CC settings. The known default uploads path is mapped into a fixture directory by fake SSH, never accessed on a real target.

Coverage includes automatic/migrated defaults, preserved custom settings and later disabling, truthful old audits, frozen scheduled 10-day Dry Run → online Apply, exact argv, no sudo/systemctl even with missing permissions, readonly zero-deletion previews, CLI/schema/WAL/report/root failures before mutation, backend root/hash protection reports, actual vs candidate logs, partial exit 1/2 counts, confirmed-vs-unconfirmed unlinks, exact transient/cancel/WAL/runtime reasons, online history `--no-checkpoint` and unchanged Vacuum args, repeated failed cursors and no advancement on online failure, obsolete cursor isolation and bounded continuation, preserved chat/message/user-upload/repository data, audit persistence, and offline Vacuum stop/verification/restoration safety.

**Do not run `scripts/test.sh` for this work:** it kills/launches actual apps by name. No CC launch/install, merge/deployment, production contact, real service operations, live settings changes or real cleanup were performed. No real counterpart cross-test or GUI runtime verification is claimed; those can follow separately once the App worker is ready.
