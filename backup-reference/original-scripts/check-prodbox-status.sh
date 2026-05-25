#!/bin/bash

# check-status.sh
# Check the status of Prodbox backups on the MacBook Pro host.
# Run this on the MacBook Pro to see backup health at a glance.

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

DATE=$(date +%Y-%m-%d)

print_header() {
    echo ""
    echo "========================================"
    echo "$1"
    echo "========================================"
}

print_ok() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

check_launchagent() {
    local label=$1
    local name=$2
    local status=$(launchctl list | grep "$label" | awk '{print $1, $2, $3}' || true)
    
    if [ -z "$status" ]; then
        print_error "$name LaunchAgent is NOT loaded"
        return 1
    fi
    
    local pid=$(echo "$status" | awk '{print $1}')
    local exit_code=$(echo "$status" | awk '{print $2}')
    
    if [ "$pid" = "-" ]; then
        print_ok "$name LaunchAgent is loaded (idle, last exit: $exit_code)"
    else
        print_warn "$name LaunchAgent is RUNNING (pid: $pid)"
    fi
    
    return 0
}

check_backup_dir() {
    local dir=$1
    local name=$2
    
    if [ ! -d "$dir" ]; then
        print_error "$name backup directory does not exist: $dir"
        return 1
    fi
    
    local latest_date=$(readlink "$dir/latest" 2>/dev/null || true)
    if [ -z "$latest_date" ]; then
        print_error "$name has no 'latest' symlink"
        return 1
    fi
    
    if [ "$latest_date" = "$DATE" ]; then
        print_ok "$name latest backup is TODAY ($latest_date)"
    else
        print_warn "$name latest backup is $latest_date (today is $DATE)"
    fi
    
    # Count snapshots
    local count=$(find "$dir" -maxdepth 1 -mindepth 1 -type d -name "20*" | wc -l | tr -d ' ')
    echo "  Snapshots: $count"
    
    # Disk usage
    local size=$(du -sh "$dir" 2>/dev/null | cut -f1)
    echo "  Total size: $size"
    
    return 0
}

check_db_backup() {
    local dir=$1
    local today_file="$dir/brain-$DATE.db"
    
    if [ ! -f "$today_file" ]; then
        print_warn "Today's database backup NOT found: brain-$DATE.db"
        return 1
    fi
    
    local size=$(du -h "$today_file" | cut -f1)
    print_ok "Today's database backup exists: brain-$DATE.db ($size)"
    
    local count=$(find "$dir" -name "brain-*.db" | wc -l | tr -d ' ')
    echo "  Database snapshots: $count"
    
    return 0
}

check_log_errors() {
    local log=$1
    local name=$2
    
    if [ ! -f "$log" ]; then
        echo "  Log file not found: $log"
        return 0
    fi
    
    local errors=$(grep -i "error\|failed\|permission denied" "$log" 2>/dev/null | tail -5 || true)
    if [ -n "$errors" ]; then
        print_error "$name has recent errors:"
        echo "$errors" | sed 's/^/    /'
    else
        print_ok "$name has no recent errors"
    fi
    
    # Show last log line
    local last_line=$(tail -1 "$log" 2>/dev/null || true)
    if [ -n "$last_line" ]; then
        echo "  Last log: $last_line"
    fi
}

# ── Main ──────────────────────────────────────────────────────

print_header "Prodbox Backup Status Check"
echo "Date: $DATE"
echo "Host: $(hostname)"
echo ""

# 1. LaunchAgents
print_header "LaunchAgents"
check_launchagent "com.user.prodbox-backup" "Prodbox Main"
check_launchagent "com.user.prodbox-sandbox-backup" "Prodbox Sandbox"

# 2. Main Backup
print_header "Prodbox Main Backup"
BACKUP_DIR="$HOME/prodbox-backups"
if [ -d "$BACKUP_DIR" ]; then
    check_db_backup "$BACKUP_DIR/db"
    check_backup_dir "$BACKUP_DIR/brain-data" "brain-data"
    check_backup_dir "$BACKUP_DIR/brain-uploads" "brain-uploads"
    check_backup_dir "$BACKUP_DIR/brain-sandbox" "brain-sandbox/apps"
    check_backup_dir "$BACKUP_DIR/brain-sandbox-skills" "brain-sandbox/skills"
    check_backup_dir "$BACKUP_DIR/brain-sandbox-upload-images" "brain-sandbox/upload_images"
    check_log_errors "$BACKUP_DIR/backup-stderr.log" "Main backup stderr"
else
    print_error "Prodbox backup directory not found: $BACKUP_DIR"
fi

# 3. Sandbox Backup
print_header "Prodbox Sandbox Backup"
SANDBOX_DIR="$HOME/prodbox-sandbox-backups"
if [ -d "$SANDBOX_DIR" ]; then
    check_backup_dir "$SANDBOX_DIR/apps" "sandbox/apps"
    check_backup_dir "$SANDBOX_DIR/upload_images" "sandbox/upload_images"
    check_backup_dir "$SANDBOX_DIR/skills" "sandbox/skills"
    check_backup_dir "$SANDBOX_DIR/brain-data" "sandbox/brain-data"
    check_log_errors "$SANDBOX_DIR/backup-stderr.log" "Sandbox backup stderr"
else
    print_error "Sandbox backup directory not found: $SANDBOX_DIR"
fi

print_header "Summary"
echo "Check complete. Review any warnings or errors above."
echo ""
