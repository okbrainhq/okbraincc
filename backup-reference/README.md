# OkBrain Backup System Reference — Prodbox & Prodbox-Sandbox

This document contains everything needed to implement the OkBrain backup system **inside the OkBrain macOS app** (Swift), without cron jobs or external tools. All data is sourced from the `~/projects/brain/.agent/skills/backup` directory and verified against `macbook-air.local:2222`.

---

## Overview

There are **two backup targets** running from the MacBook Pro host:

1. **Prodbox Main Backup** (`prodbox.local` VM) — daily at 3:30 AM
2. **Prodbox Sandbox Backup** (`prodbox-sandbox.local` VM) — daily at 3:45 AM

Both use `rsync --link-dest` for space-efficient snapshots and `sqlite3 .backup` for safe database dumps.

---

## What Gets Backed Up

### Prodbox Main Backup

| Source (VM) | Destination (Mac) | Method |
|---|---|---|
| `/var/www/brain/brain.db` | `~/prodbox-backups/db/brain-YYYY-MM-DD.db` | `sqlite3 .backup` → `scp` |
| `/var/www/brain-data/` | `~/prodbox-backups/brain-data/YYYY-MM-DD/` | `rsync --link-dest` |
| `/var/www/brain-data/uploads/` | `~/prodbox-backups/brain-uploads/YYYY-MM-DD/` | `rsync --link-dest` |
| `/home/brain-sandbox/apps/` | `~/prodbox-backups/brain-sandbox/YYYY-MM-DD/` | `rsync --link-dest` (sudo) |
| `/home/brain-sandbox/skills/` | `~/prodbox-backups/brain-sandbox-skills/YYYY-MM-DD/` | `rsync --link-dest` (sudo) |
| `/home/brain-sandbox/upload_images/` | `~/prodbox-backups/brain-sandbox-upload-images/YYYY-MM-DD/` | `rsync --link-dest` (sudo) |

### Prodbox Sandbox Backup

| Source (VM) | Destination (Mac) | Method |
|---|---|---|
| `/home/brain-sandbox/apps/` | `~/prodbox-sandbox-backups/apps/YYYY-MM-DD/` | `rsync --link-dest` (sudo) |
| `/home/brain-sandbox/upload_images/` | `~/prodbox-sandbox-backups/upload_images/YYYY-MM-DD/` | `rsync --link-dest` (sudo) |
| `/home/brain-sandbox/skills/` | `~/prodbox-sandbox-backups/skills/YYYY-MM-DD/` | `rsync --link-dest` (sudo) |
| `/var/www/brain-data/` | `~/prodbox-sandbox-backups/brain-data/YYYY-MM-DD/` | `rsync --link-dest` (sudo) |

- **Retention**: 30 days
- **Space efficiency**: `rsync --link-dest` hardlinks unchanged files from the previous day via a `latest` symlink. Only changed files consume extra disk space.

---

## Verified Remote State (as of 2026-05-25)

From `macbook-air.local:2222`:

- Both LaunchAgents are loaded and idle (`launchctl list` shows exit code 0):
  - `com.user.prodbox-backup` — last ran 2026-05-25 03:30
  - `com.user.prodbox-sandbox-backup` — last ran 2026-05-25 03:45
- All `latest` symlinks point to `2026-05-25` (except `brain-sandbox` which points to `2026-05-22` because those directories no longer exist on the remote VM).
- Disk usage on the Mac:
  - `~/prodbox-backups/db`: 6.1G (database snapshots)
  - `~/prodbox-backups/brain-data`: 22M
  - `~/prodbox-backups/brain-uploads`: 38M
  - `~/prodbox-backups/brain-sandbox`: 206M
  - `~/prodbox-backups/brain-sandbox-skills`: 0B
  - `~/prodbox-backups/brain-sandbox-upload-images`: 120K
  - `~/prodbox-sandbox-backups/apps`: 1.3G
  - `~/prodbox-sandbox-backups/brain-data`: 44M
  - `~/prodbox-sandbox-backups/skills`: 0B
  - `~/prodbox-sandbox-backups/upload_images`: 1.3M

---

## Directory Layout on the Mac

```
~/prodbox-backups/
  backup.log
  backup-stdout.log
  backup-stderr.log
  db/
    brain-2026-05-25.db
    brain-2026-05-24.db
    ...
  brain-data/
    2026-05-25/
    2026-05-24/
    ...
    latest -> 2026-05-25
  brain-uploads/
    2026-05-25/
    2026-05-24/
    ...
    latest -> 2026-05-25
  brain-sandbox/
    2026-05-22/
    ...
    latest -> 2026-05-22
  brain-sandbox-skills/
    2026-05-22/
    ...
    latest -> 2026-05-22
  brain-sandbox-upload-images/
    2026-05-22/
    ...
    latest -> 2026-05-22

~/prodbox-sandbox-backups/
  backup.log
  backup-stdout.log
  backup-stderr.log
  apps/
    2026-05-25/
    ...
    latest -> 2026-05-25
  upload_images/
    2026-05-25/
    ...
    latest -> 2026-05-25
  skills/
    2026-05-25/
    ...
    latest -> 2026-05-25
  brain-data/
    2026-05-25/
    ...
    latest -> 2026-05-25
```

---

## Key Technical Details for Swift Implementation

### 1. Database Backup

**Current approach (bash):**
```bash
ssh arunoda@prodbox.local "sqlite3 /var/www/brain/brain.db \".backup /tmp/prodbox-backup-$(date +%s).db\""
scp arunoda@prodbox.local:/tmp/prodbox-backup-xxx.db ~/prodbox-backups/db/brain-YYYY-MM-DD.db
ssh arunoda@prodbox.local "rm -f /tmp/prodbox-backup-xxx.db"
```

**Swift translation:**
- Use `Process` (NSTask) to run `ssh` with the sqlite3 `.backup` command remotely.
- Use `Process` to run `scp` to pull the temp file down.
- Clean up the remote temp file via another `ssh` invocation.
- Alternative: stream the backup directly over SSH without temp files: `ssh host "sqlite3 db .backup -" > local_file` (if sqlite3 supports stdout backup; test this).

### 2. Directory Backup (rsync --link-dest)

**Current approach (bash):**
```bash
rsync -az --delete --link-dest="~/prodbox-backups/brain-data/latest" \
  arunoda@prodbox.local:/var/www/brain-data/ \
  ~/prodbox-backups/brain-data/YYYY-MM-DD/
ln -snf YYYY-MM-DD ~/prodbox-backups/brain-data/latest
```

**Swift translation:**
- The app can shell out to `rsync` (it's pre-installed on macOS) using `Process`.
- `--link-dest` creates hardlinks automatically when `rsync` detects unchanged files.
- After success, update the `latest` symlink using `FileManager.createSymbolicLink`.
- For sudo-required paths (sandbox), the VM must allow passwordless sudo for rsync, or the app must use an SSH key with appropriate permissions. The current setup uses `--rsync-path="sudo rsync"` which implies the SSH user has passwordless sudo for rsync.

### 3. Space-Efficient Snapshots

The `latest` symlink is critical. On each run:
1. Create the date-stamped directory.
2. Run `rsync` with `--link-dest=.../latest`.
3. `rsync` will hardlink identical files instead of copying them.
4. After success, repoint `latest` to the new date directory.

If `latest` does not exist (first run), omit `--link-dest`.

### 4. Cleanup / Retention

Delete everything older than 30 days:
- DB files: `find db -name "brain-*.db" -mtime +30 -delete`
- Snapshot dirs: `find brain-data -maxdepth 1 -mindepth 1 -type d -name "20*" -mtime +30 -exec rm -rf {} \;`

In Swift, use `FileManager` to enumerate directories, compare `modificationDate` or parse the date from the directory name, and remove old ones.

### 5. Restore

Restore runs **from the Mac** and **pushes to the VM**:
1. Stop the remote app: `ssh host "sudo systemctl stop brain"`
2. Restore DB: `scp local_db host:remote_db`, remove WAL/SHM first.
3. Restore dirs: `rsync -az --delete local_dir/ host:remote_dir/`
4. Fix ownership for sandbox: `ssh host "sudo chown -R brain-sandbox:brain-sandbox /home/brain-sandbox/apps/"`
5. Start app: `ssh host "sudo systemctl start brain"`

Restore supports partial restores via flags: `--db-only`, `--data-only`, `--uploads-only`, `--sandbox-only`, etc.

### 6. Status Check

The status checker verifies:
- LaunchAgents are loaded (not applicable for in-app implementation; instead check last backup timestamp).
- `latest` symlink exists and points to today's date (or warn if stale).
- DB file for today exists.
- Count snapshots and show total disk usage.
- Check recent log errors.

For the app, a status view should show:
- Last successful backup date/time per target.
- Number of retained snapshots.
- Disk usage per component.
- Whether today's backup is complete.
- Any error messages from the last run.

### 7. Scheduling Without Cron / LaunchAgents

The requirement is **no cron or external tools**. Use one of these macOS-native approaches:

**Option A: `BGTaskScheduler` (modern, recommended)**
- Register a `BGProcessingTaskRequest` for each backup target.
- The system will launch the app in the background at appropriate times.
- Requires the "Background processing" capability in entitlements.

**Option B: `Timer` + App Lifecycle**
- When the app is running, use a `Timer` to trigger backups at scheduled times (3:30 AM and 3:45 AM).
- If the app isn't running, the backup is missed. This is acceptable if the app is a menubar/background app that stays alive.

**Option C: `UNUserNotificationCenter` + local notifications**
- Schedule a local notification to remind the user to open the app, then run the backup.
- Less automatic.

**Recommended: Option A (`BGTaskScheduler`)** for automatic daily background execution, combined with a manual "Run Now" button in the UI.

---

## SSH / Connection Details

- **Prodbox main VM**: `arunoda@prodbox.local`
- **Prodbox sandbox VM**: `arunoda@prodbox-sandbox.local`
- **MacBook host**: `macbook-air.local:2222` (this is where the app runs)

The app must have SSH key-based authentication configured (no password prompts). The current setup uses the user's default SSH keys (`~/.ssh/id_rsa` or `~/.ssh/id_ed25519`).

For sudo rsync on the VMs, the user `arunoda` has passwordless sudo for the rsync command (configured via `/etc/sudoers.d/` on the VMs).

---

## Original Scripts

All original bash scripts and plist files are preserved in `original-scripts/`:
- `backup-prodbox.sh`
- `restore-prodbox.sh`
- `backup-prodbox-sandbox.sh`
- `restore-prodbox-sandbox.sh`
- `check-prodbox-status.sh`
- `com.user.prodbox-backup.plist`
- `com.user.prodbox-sandbox-backup.plist`

These are the **exact** files running on the MacBook, verified via `diff` against the remote copies.

---

## Implementation Checklist for the Swift Agent

- [ ] Create a `BackupService` Swift class.
- [ ] Implement `runProdboxBackup()` and `runSandboxBackup()`.
- [ ] Use `Process` to invoke `ssh`, `scp`, and `rsync`.
- [ ] Store backups under `~/prodbox-backups/` and `~/prodbox-sandbox-backups/`.
- [ ] Create date-stamped directories (`YYYY-MM-DD`).
- [ ] Manage `latest` symlinks after successful backup.
- [ ] Implement 30-day retention cleanup.
- [ ] Implement restore methods (full + partial: db-only, data-only, uploads-only, sandbox-only).
- [ ] Add a status/dashboard view showing last backup, snapshot count, disk usage, and errors.
- [ ] Schedule daily runs using `BGTaskScheduler` (or `Timer` if simpler).
- [ ] Add manual "Backup Now" and "Restore..." buttons.
- [ ] Parse backup output and write to `backup.log` for diagnostics.
