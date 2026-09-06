# DB Maintenance: tool history and proven agent images

## Scope and defaults

This extends the existing `DBMaintenanceStore` timer and **Dry Run → Apply** flow. There is no new scheduler, and Vacuum is never automatic. Existing `dbMaintenance.scheduleEnabled`, `scheduleIntervalMinutes`, `retentionDays`, `remoteHost`, and last-attempt keys remain in use: source defaults are enabled, 1440 minutes, 10 days. Old run JSON decodes without the new optional configuration/report fields.

Only aged execution records are targeted: FILE-EDIT/SHELL/TOOL history, tool-call/result chat events, and finished-job output. Conversations, messages, jobs, actual repository edits/files, user uploads and unknown/legacy images are not deletion targets. CC does not classify provenance, migrate schemas, or implement its own image-deletion algorithm. The released Brain CLIs own those decisions.

New and migrated installations have **image preview only**, a blank uploads path, and all destructive acknowledgements off. `brain` is the documented default writer service, not an assertion that it controls every deployed writer. An unset uploads path allows safe history cleanup but produces an explicit image-unavailable warning. A configured but unavailable/invalid image CLI/schema/root blocks Apply during read-only preflight; it never silently falls back.

## Release and enable procedure (operator actions, NOT performed by this change)

1. **Release counterpart Brain code AND the provenance schema first**, through the Brain project's reviewed release procedure. Merged source is not proof of deployment. Required files on the target:
   - `/var/www/brain/scripts/deploy/cleanup-old-execution-history.sh` with `--tool-history-only`, current safe-scope report, `--db`, `--days`, `--apply`, and `--vacuum` for manual Vacuum.
   - Sibling `/var/www/brain/scripts/deploy/cleanup-agent-images.py` with the supplied read-only JSON/batch/cursor contract and gated offline Apply.
   - Creation-time provenance records/schema. Do not backfill user/unknown/legacy images as agents to make them eligible.
2. Review/merge/release this CC change separately. **No merge, production deployment, installation or app launch was performed here.** The app bundle must contain all three wrappers plus `BackupAgent/db-maintenance.py` (the existing build script copies that directory).
3. Ensure local and remote `python3`, SSH access, counterpart readability, app DB access, and appropriate uploads ownership are available. CC does not install dependencies, run migrations or elevate cleanup itself.
4. In **DB Maintenance → Settings**, verify the SSH host and existing canonical app DB path. Enter the actual canonical uploads `storage_root`. Brain source indicates `/var/www/brain-data/uploads`, but the operator must verify deployed configuration/overrides and provenance roots. CC deliberately does not prefill it. Save with image deletion **off**.
5. Run **Dry Run** and review the scope, candidate table, image inventory/item metadata, protection reasons, errors and sweep cursor. Dry Run does not stop services, delete files, finalize tombstones or write DB/remote progress files. Local audit logs/progress are expected writes.
6. Before enabling image removal, audit the complete writer set: the app, jobs/workers, filesystem writers, timers, sockets, live service overrides and external processes. Source documents only `brain` running `npm start`; that does **not** establish that live deployments have no other writers. All writers must be controlled by the explicitly configured systemd services, unable to reactivate or write during the window. Do not affirm this if an uncontrolled/non-systemd writer exists.
7. Arrange a downtime policy covering **manual AND scheduled Apply**. The existing timer remains interval-based; this feature does not add a time-of-day maintenance window. For manual-only downtime, turn the existing automatic schedule off before opting in. Audit external references and pin required images; DB reference scanning cannot replace this operator affirmation.
8. Confirm narrowly scoped sudo privileges for the configured units. The default mutations are exactly `sudo -n /bin/systemctl stop brain` and `sudo -n /bin/systemctl start brain`, compatible with the documented old sudoers entries without `.service`. State checks use unprivileged `/bin/systemctl show --property=LoadState --property=ActiveState brain`. Other unit names/suffixes need their own reviewed stop/start permissions. No broad sudoers changes are made by CC.
9. Check the downtime, all-writers-controlled and external-reference-audited/pinned boxes, type **DELETE AGENT IMAGES**, enable the explicit image-deletion toggle, then **Save & Done**. No affirmation is automatically checked. Changing host, DB, uploads or service scope in the UI revokes these permissions.
10. Use **Apply + Images (offline)** and its manual confirmation to verify the intended run. Thereafter scheduled Apply uses the saved opt-in as well. Disabling image deletion returns Apply to history cleanup + image preview without downtime. Vacuum always requires separate manual confirmation and the downtime/all-writers prerequisites.

## Invocation and safety contract

The three existing shell entry points now `exec` the shared Python transport. Every history invocation, including capability checks, preflight, Apply and Vacuum, carries **`--tool-history-only`**. CC checks advertised safe flags, executes a read-only history report, and requires tool-history rows plus zero SmartDoc conversation/job candidates before destructive execution. Unknown flags/old counterparts/nonzero exits are failures, not legacy fallback triggers.

CC deliberately invokes the **standalone sibling image CLI** inside this same flow rather than the history script's `--agent-images-dir` convenience delegation. That convenience interface does not expose CC's bounded continuation controls. CC does not send `--apply-images` to the history script or assume that history `--apply` would apply images.

- History: `bash CLEANUP --tool-history-only --db DB --days N` (plus `--apply`, and `--vacuum` only for manual Vacuum).
- Image preview: `python3 IMAGE_CLI --db DB --uploads-dir EXPLICIT_ROOT --days N --batch-size 100 [--after-id CURSOR]`.
- Image deletion: the same image command with **all** of `--apply --offline --confirm-app-db-scope`, only after verified offline prerequisites.

The local client validates input and passes a fixed payload plus base64 JSON through SSH. Settings are never interpolated as shell code. The target is a validated alias/hostname or user@hostname, not SSH option text. Paths are passed as argv, checked for canonical existing roots/files, and never guessed. The counterpart additionally verifies each asset's recorded root/hash/ownership/references/provenance.

Each remote invocation holds an advisory lock on the existing DB parent directory inode (no lock-file writes, and no SQLite-file lock interference). For Apply/Vacuum this spans re-preflight, service handling, history mutation, image sweep and restoration. The Store's earlier Dry Run is a separate invocation; Apply repeats preflight under the lock, rather than relying on the earlier report across an unlocked gap. The lock cooperates with other updated CC runners, not arbitrary writers or standalone CLI callers.

Before offline work, CC snapshots every configured unit's loaded/active state. Only stable active/inactive states are accepted. It records originally active units **before** stopping them, verifies every configured writer is inactive, and rechecks before every deleting image batch. Restoration runs on success, error and cancellation, starts only originally active units touched by this operation, and verifies they are active. Stop failures, unknown states, restart failures and partial cleanup remain non-success outcomes. An originally inactive unit is never auto-started.

Stop uses a cancellation message over SSH stdin, not a blind local SSH kill. Remote signal handlers/heartbeat/EOF detection terminate the cleanup child process group before restoration. Normal CC quit waits for the same cancellation/restoration path. Transport cancellation has a bounded wait; an unconfirmed outcome is explicitly failed/stopped, never success. Remote SIGKILL, host/power loss or external service changes cannot be made recoverable by this wrapper; operators must inspect uncertain runs. Logging pipe failures must not prevent restoration.

## Reports, persistence and continuation

Both Store phases use one immutable configuration snapshot (host, DB/root, retention, policy, services/affirmations and start cursor). Editing settings during a pair affects later runs, not its Apply phase. The CLIs compute their own cutoff at execution time; Dry Run is not an exact frozen deletion manifest. In particular, pre-prune image references can protect files that the post-prune image CLI later finds eligible. CC logs each phase without predicting that transition.

Persistent metadata-only `.json` and full `.log` files are stored in:

- Production: `~/okbraincc-db-maintenance/runs/<run-id>.{json,log}`
- Development: `~/okbraincc-db-maintenance-dev/runs/<run-id>.{json,log}`

Audit retention follows the existing retention setting. These maintenance logs no longer silently truncate at 120,000 characters. Write failures are visible and block phase advancement; mid-run write failure requests cancellation. New run JSON includes its frozen configuration and terminal structured report. Interrupted loads show unconfirmed remote outcome/restoration. No image/chat bodies, SQL payloads, or arbitrary counterpart diagnostics are forwarded; known table metadata and allowlisted image metadata/reasons are retained.

History output is labelled **pre-Apply candidate rows / approximate payload** even when emitted by Apply. `chat_events.news_search` overlaps `chat_events.tool_history` and is never summed. Dry Run actual deletions are zero. Apply records command success/failure but **does not invent actual deleted history row/byte counts**: the current upstream report does not supply them. A future exact-counter feature would need an upstream structured actual-deletion report; none is required for the current honest phase-labelled integration.

Image logs contain per-batch inventory, examined/candidate/deleted bytes and counts, missing-file finalizations, per-file errors, item IDs/filenames/reasons, reference scan bytes and continuation. The summary separately shows candidate vs confirmed deleted files, missing tombstones, skip/protection reasons, partial/errors and restoration failures. An interrupted/invalid Apply batch is flagged **unconfirmed**; earlier confirmed totals are not claimed to account for all possible changes.

Each sweep is bounded to **3 × 100 rows**, plus a distinct 100-row read-only probe before Apply. Inventory is context, not a claim that the whole uploads directory was processed. Incomplete sweeps have a visible next cursor. Preview and deletion use separate persistent cursors, keyed by host/DB/root/retention/policy, under `dbMaintenance.imageSweepCursors.v1`. A composite Dry Run never advances its Apply cursor. Trusted completed batches can advance past per-file errors; those rows are retried on the next traversal. Global failure never advances an unreported batch. Reaching the end resets that scope's cursor for a later traversal, not a permanent assertion that all uploads are clean.

## Focused fixture validation

Run only the safe focused entry point for this task:

```bash
bash scripts/test-db-maintenance.sh
swift build --disable-sandbox --cache-path .build/swiftpm-cache
./scripts/build.sh --dev
```

The focused script runs **21 Python integration tests** using fake SSH/sudo/systemctl and disposable SQLite/files, then **12 standalone Swift Store tests**. The standalone Swift convention matches `scripts/verify_scheduler.swift` and needs no XCTest framework or GUI launch. Fixtures refuse non-fixture hosts/paths and never operate on saved real CC settings.

Coverage includes readonly Dry Run; old/unknown safe flags; schema/root/protocol failure; default preview Apply; explicit offline Apply; initially inactive writers; stop/verification/restart failure; signal during stop/history/Vacuum/images; parent death/EOF; cooperative lock contention; partial image cleanup; missing-file vs deleted-file counts; bounded continuation past protected rows; retained conversations/messages/jobs/user uploads/repository edits; metadata redaction; legacy decoding; schedule compatibility; frozen phase settings; separate/reloaded cursors; full persistent logs; and audit write failure.

**Do not run the existing full `scripts/test.sh` for this task.** It contains name-based process kills and mock dev/prod launches. It was left unchanged and skipped. `swift test --disable-sandbox` was attempted, but the selected Command Line Tools lacked XCTest and no tests executed; the same Store scenarios were moved to the repository's standalone verification convention. No GUI verification, real upstream execution or production behavior is claimed by these contract doubles.
