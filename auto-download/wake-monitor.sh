#!/bin/sh

# One-Shot Wake Monitor untuk Auto-Download Script
# Script ini mendeteksi deep sleep wake dan membangunkan script utama

# ===== KONFIGURASI =====
TARGET_PID="$1"
# Allow override via environment variables for testing
LOG_FILE="${LOG_FILE:-/data/adb/auto-download/wake-monitor.log}"
PID_FILE="${PID_FILE:-/data/adb/auto-download/wake-monitor.pid}"
STATE_FILE="${STATE_FILE:-/data/adb/auto-download/wake-monitor.state}"

# Validasi parameter
if [ -z "$TARGET_PID" ]; then
    echo "Usage: $0 <target_script_pid>"
    echo "Error: Target PID is required"
    exit 1
fi

# Validasi target PID exists
if ! kill -0 "$TARGET_PID" 2>/dev/null; then
    echo "Error: Target PID $TARGET_PID not found or not accessible"
    exit 1
fi

# ===== FUNGSI UTILITAS =====
log_event() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message" >> "$LOG_FILE"
}

cleanup() {
    rm -f "$PID_FILE"
    log_event "Wake monitor (PID $$) exiting for target PID $TARGET_PID"
    exit 0
}

# Setup signal handlers
trap cleanup INT TERM EXIT

# ===== INISIALISASI =====
# Pastikan direktori log ada
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null

# Save monitor PID
echo $$ > "$PID_FILE"

log_event "Wake monitor started (PID $$) for target PID $TARGET_PID"

# ===== FUNGSI DETEKSI =====
# Fungsi untuk mendeteksi deep sleep wake menggunakan multiple methods
detect_deep_sleep_wake() {
    # Baseline measurements
    local baseline_wakeup=$(cat /sys/power/wakeup_count 2>/dev/null || echo "0")
    local baseline_time=$(date +%s)
    local baseline_uptime=$(cat /proc/uptime | cut -d'.' -f1)
    
    log_event "Baseline - Wakeup: $baseline_wakeup, Time: $baseline_time, Uptime: $baseline_uptime"
    
    # Save state untuk debugging
    cat > "$STATE_FILE" << EOF
baseline_wakeup=$baseline_wakeup
baseline_time=$baseline_time
baseline_uptime=$baseline_uptime
monitor_pid=$$
target_pid=$TARGET_PID
start_time=$(date '+%Y-%m-%d %H:%M:%S')
EOF
    
    local check_count=0
    
    # Main monitoring loop
    while kill -0 "$TARGET_PID" 2>/dev/null; do
        current_wakeup=$(cat /sys/power/wakeup_count 2>/dev/null || echo "0")
        current_time=$(date +%s)
        current_uptime=$(cat /proc/uptime | cut -d'.' -f1)
        
        # Method 1: Wakeup count jump detection
        local wakeup_diff=$((current_wakeup - baseline_wakeup))
        
        # Method 2: Time gap analysis (real time vs uptime)
        local time_diff=$((current_time - baseline_time))
        local uptime_diff=$((current_uptime - baseline_uptime))
        local time_discrepancy=$((time_diff - uptime_diff))
        
        # Detection logic
        local deep_sleep_detected=false
        local detection_reason=""
        
        # More conservative detection to avoid false positives
        # Detect significant wakeup count jump (likely deep sleep wake)
        # Increased threshold and added time-based validation
        if [ "$wakeup_diff" -gt 10 ] && [ "$time_diff" -gt 30 ]; then
            deep_sleep_detected=true
            detection_reason="wakeup_count_jump:$wakeup_diff"
        # Detect significant time discrepancy (system was suspended)
        elif [ "$time_discrepancy" -gt 30 ]; then
            deep_sleep_detected=true
            detection_reason="time_discrepancy:${time_discrepancy}s"
        # Combined detection: moderate wakeup jump + some time discrepancy
        elif [ "$wakeup_diff" -gt 5 ] && [ "$time_discrepancy" -gt 10 ]; then
            deep_sleep_detected=true
            detection_reason="combined_detection:wakeup+${wakeup_diff}_time+${time_discrepancy}s"
        fi
        
        if [ "$deep_sleep_detected" = "true" ]; then
            log_event "DEEP SLEEP WAKE DETECTED!"
            log_event "  Detection reason: $detection_reason"
            log_event "  Wakeup count: $baseline_wakeup → $current_wakeup (+$wakeup_diff)"
            log_event "  Time analysis: real_time=${time_diff}s, uptime=${uptime_diff}s, discrepancy=${time_discrepancy}s"
            
            # Send wake signal to target script
            send_wake_signal "$detection_reason" "$wakeup_diff" "$time_discrepancy"
            
            # Start new monitor for next cycle and exit this one
            start_next_monitor
            cleanup
        fi
        
        # Debug logging (every 10 checks = 20 seconds)
        if [ $((check_count % 10)) -eq 0 ]; then
            log_event "Monitor check #$check_count - Wakeup: $baseline_wakeup→$current_wakeup (+$wakeup_diff), Time_diff: ${time_diff}s, Discrepancy: ${time_discrepancy}s"
        fi
        
        # Update baseline periodically to handle normal increments
        check_count=$((check_count + 1))
        if [ $((check_count % 30)) -eq 0 ]; then  # Every 30 checks (60 seconds)
            baseline_wakeup=$current_wakeup
            baseline_time=$current_time
            baseline_uptime=$current_uptime
            log_event "Baseline updated - Wakeup: $baseline_wakeup, Time: $baseline_time"
        fi
        
        # Sleep between checks
        sleep 2
    done
    
    log_event "Target PID $TARGET_PID no longer exists, monitor exiting"
}

# Fungsi untuk mengirim signal wake ke script utama
send_wake_signal() {
    local reason="$1"
    local wakeup_diff="$2"
    local time_discrepancy="$3"
    
    # Create signal data file untuk debugging
    cat > "/data/adb/auto-download/wake-signal-data" << EOF
reason=$reason
wakeup_diff=$wakeup_diff
time_discrepancy=$time_discrepancy
timestamp=$(date +%s)
monitor_pid=$$
target_pid=$TARGET_PID
EOF
    
    # Send USR1 signal to target script
    if kill -USR1 "$TARGET_PID" 2>/dev/null; then
        log_event "Wake signal (USR1) sent successfully to PID $TARGET_PID"
    else
        log_event "ERROR: Failed to send wake signal to PID $TARGET_PID"
        return 1
    fi
    
    return 0
}

# Fungsi untuk memulai monitor baru untuk cycle berikutnya
start_next_monitor() {
    log_event "Starting new wake monitor for next cycle"
    
    # Start new monitor in background
    "$0" "$TARGET_PID" &
    local new_monitor_pid=$!
    
    log_event "New wake monitor started with PID $new_monitor_pid"
}

# ===== FUNGSI UTAMA =====
main() {
    # Check apakah sudah ada monitor yang running untuk target PID ini
    if [ -f "$PID_FILE" ]; then
        local existing_pid=$(cat "$PID_FILE")
        if [ "$existing_pid" != "$$" ] && kill -0 "$existing_pid" 2>/dev/null; then
            log_event "Another monitor already running (PID $existing_pid), exiting"
            exit 0
        fi
    fi
    
    # Mulai deteksi deep sleep wake
    detect_deep_sleep_wake
}

# ===== EKSEKUSI =====
main