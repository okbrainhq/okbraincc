# DB Maintenance (policy v3)

## Controls and schedule

The main screen follows **Backup DB**: run history on the left, selected run details, duration/status, result counts and visible live logs on the right. The app navigation sidebar is unchanged. There are only **three primary buttons**:

- **Settings** — SSH hostname, daily on/off and retention days (default **10**). Paths and Vacuum writer services are under a collapsed Advanced section. Save validates the hostname before persisting; Cancel discards edits.
- **Start Manually** — runs daily cleanup immediately; becomes **Stop** while cleanup runs (including automatic runs).
- **Vacuum** — asks for downtime confirmation, then becomes **Stop** while Vacuum runs.

Only one operation can run at a time. Stop switches to a disabled **Stopping…** state until remote cancellation/service restoration completes. No Refresh, Open Folder, Dry Run or extra log-disclosure buttons clutter the main screen. There are no independent image switches, custom interval controls, typed confirmation phrases, or prerequisite acknowledgement checkboxes.

- Enabled maintenance runs every **24 hours after a successful cleanup** while OKBrainCC is running. It checks immediately on launch and wake, so sleep does not permanently miss a run.
- Failed, partial or warning automatic attempts retry after **one hour**, with no overlapping runs.
- Dry runs and manual Vacuum do **not** postpone scheduled cleanup.
- Existing enabled/disabled state, retention days, SSH target and custom database/uploads paths survive. Old custom intervals become daily. The old image-disable setting and partial-sweep cursors no longer suppress the unified policy; old audit records remain unchanged/decodable.
- Turning the toggle off prevents future automatic runs. An in-progress run finishes unless Stop is used. Start Manually remains available with automation off.
- The scheduler lives in the app, not a separate daemon: **leave OKBrainCC running**. There is no background cleanup while the app is quit.

## Exact retention scope

Ages use the record's UTC timestamp and a single SQLite UTC cutoff for each execution, not the conversation's last activity time. Invalid/undated records are retained.

| Data | Policy |
| --- | --- |
| `tool_call_logs` | Expire old Code Project calls and web-search-family calls. |
| `chat_events` | Expire only `tool_call` / `tool_result` in the same scope. Web results can be paired by conversation + call ID even when the result has no tool name. |
| `conversation_tool_jobs` | Clear aged completed scoped tool output/error payloads; retain job/link rows. |
| `job_events` | Expire old `output` only for dedicated Code Project shell/screenshot jobs, or explicitly linked shell/run-app tool jobs. **Never blanket-prune terminal-job output**: chat jobs also store assistant text here. |
| Code Project images | Delete old image files with project ownership proven by upload metadata or same-user Code Project references; retain an upload tombstone. This includes attributable legacy and user-uploaded images, not just agent screenshots. |
| Conversations, messages, summaries, assistant/user text events, thoughts, chat-job output | **Never deleted or rewritten by this maintenance.** |
| Ordinary non-search tools outside Code Projects, documents, repository files, non-project uploads | Not retention targets. |

The web-search family is explicitly `internet_search`, `internet_search_premium`, `news_search`, `image_search`, and `read_url`, with optional `functions.` namespace. Do not infer scope from a substring like “search” (that would include unrelated fact/document searches).

**Project image links in preserved chat text may stop loading after expiry.** The text/Markdown/HTML itself remains byte-for-byte unchanged. Non-project references, pins, unproven ownership and active *linked* jobs protect files. Unrelated idle/running jobs do not globally block all images. An upload without attributable project ownership cannot safely be treated as a project image; it remains protected and counted in the report.

Reference discovery runs before log pruning so that legacy upload links are still available. Durable `job_queue.input.conversationId` links help classify project tool output even after older tool logs have already been pruned. Derived FTS/vector indexes are not canonical references; canonical tables are scanned. Unknown virtual reference stores fail closed.

## Daily DB work vs manual Vacuum

Normal cleanup stays **online**, with no `sudo`, service queries, or shutdown:

1. Open the existing database (never create it) and run `PRAGMA quick_check`.
2. Determine the scoped history and image candidates.
3. Prune history in short, revalidated batches; preserve all chat text.
4. Process the **whole eligible image inventory**, in 50-file critical sections. There is no old 300-rows-per-day ceiling or persisted UUID cursor.
5. Run bounded `PRAGMA optimize` and a **PASSIVE** WAL checkpoint. A contended image pass does not prevent this DB work after history cleanup.

These operations make freed pages reusable and maintain the DB without a full rewrite. They do **not** promise an immediate reduction in the main DB file size.

**Vacuum is separate and manual.** A single confirmation explains downtime and asks the operator to confirm that the configured writer services cover all writers. Consent applies to that run only, not future runs. Vacuum:

- Records stable service states, stops configured active writers, and verifies they stopped.
- Checks the DB and available free space, loads the installed `sqlite-vec` extension when the schema needs it, runs `VACUUM`, optimizes, and truncates the WAL offline.
- Runs **no retention deletions or image sweep**.
- Restores only services that were originally active, including after stop/operation failures or cancellation. Restoration failure is always prominent/non-successful.

Default writer service: `brain`. The existing noninteractive `sudo -n /bin/systemctl stop/start` permissions are still required for manual Vacuum, not daily cleanup. Custom service names and paths are preserved from existing configuration.

## Deployment and safety

The app now bundles **both** `db-maintenance.py` (SSH/cancellation/service orchestration) and **`db-retention.py`** (versioned selection/cleanup). The runner sends the bundled engine over SSH in memory. It no longer depends on separately deployed Brain `cleanup-old-execution-history.sh` / `cleanup-agent-images.py` behavior. No remote installation or schema migration is performed.

Defaults:

- SSH target: `arunoda@prodbox.local` (from the machine running CC).
- Database: `/var/www/brain/brain.db`.
- Uploads: `/var/www/brain-data/uploads`.
- Paths must be canonical and explicit. Missing/blank saved uploads roots normalize to the source default.

Safety boundaries:

- Online writes require WAL. Database/schema/check failures occur before retention mutation.
- SQLite authorizer restrictions prevent a log delete trigger/cascade from deleting messages or other protected tables. Only selected history deletions and specific upload/job metadata updates are permitted.
- Image names must be stored UUID image filenames, never paths derived from chat text. Directory FDs, `O_NOFOLLOW`, regular-file/link-count checks, image headers, available recorded hashes/sizes, and final inode checks protect filesystem deletion.
- References are scanned under a read snapshot. A changed DB version before an image batch causes a retryable partial/failed pass, not an unsafe unlink. Retry happens hourly; active writers can postpone cleanup. This is deliberately safer than stopping Brain automatically.
- Unlinks are irreversible. Counts are confirmed only after the upload tombstone transaction commits. An interrupted/failed finalization is explicitly unconfirmed; missing files with retained ownership can be finalized on retry.
- A cooperative 15-minute engine budget bounds a run. SQLite lock contention, cancellation, file errors and transport/report loss are not presented as full success. Some earlier batches may have committed.
- The transport holds the existing directory-inode advisory lock across execution and manual service restoration. Heartbeat/EOF/cancellation terminates the child before restoring services. No recovery guarantee is made after host loss or SIGKILL.

Engine progress streams into the selected run’s logs during DB checks, reference scanning, committed cleanup batches and checkpointing. Terminal results are withheld until the transport has restored Vacuum services; interim progress never claims final success. Settings changes affect future runs only, and selected history details show the frozen target rather than the currently edited hostname.

Reports are metadata only: table counts, file counts/bytes, protection reasons, check/compaction outcomes and errors, never chat bodies or image contents. Persistent JSON/log files remain in `~/okbraincc-db-maintenance[-dev]/runs`; audit-file retention uses the selected retention days. A full eligible traversal can still contain protected/error files; it is not a claim that every uploaded file was deleted.

## Findings from read-only production inspection

The deployed image cleaner treated **all** nonterminal jobs for a user as a blocker, including idle jobs. The inspected DB had **70 idle jobs** and thousands of old project images; production reports repeatedly showed `active-or-unowned-job` and zero image deletions. The old cleaner also required old conversation activity, protected every retained text reference to an image, excluded user/legacy uploads, and visited only 300 agent rows per daily run.

The deployed history script's “tool-history-only” branch still deleted `job_events.output` across **all terminal jobs**, which includes chat jobs. The new engine narrows this to actual tool jobs and fixtures explicitly preserve chat-job text.

A read-only v3 preview passed the real production schema/DB check and identified thousands of eligible project images with **zero writes/deletions**. This is a schema/selection cross-check, not a production Apply or Vacuum test. No installed app, production configuration, service, database content or upload was changed during development.

## Validation

```bash
bash scripts/test-db-maintenance.sh
bash scripts/build.sh --dev
bash scripts/test.sh --no-launch
```

The focused suite runs real SQLite/filesystem retention fixtures, fake-SSH transport/restoration/cancellation fixtures, and isolated Swift Store/scheduler tests. It exercises exact scope, UTC date formats/cutoffs, legacy ownership, long-lived chats, >300-image sweeps, preserved chat text, cross-chat/document/pin protection, hashes/symlinks/hardlinks, concurrent-reference invalidation, unconfirmed unlinks/retry, dry-run immutability, free-space checks, per-run Vacuum confirmation, scheduling/migration, audit persistence, and service restoration.

`scripts/test.sh --no-launch` runs build/bundle/scheduler/maintenance verification without killing or launching app processes. The default script still includes mock app launch checks. GUI verification uses the full Dev app in mock mode so the sidebar remains visible; real maintenance never runs during mock UI verification.
