#!/system/bin/sh
# Wakelock Monitor khusus untuk auto-download.sh
# Monitor deep sleep wake events dan trigger recalculation

LOG_FILE="/data/adb/auto-download/wakelock_monitor.log"
AUTODOWNLOAD_PID_FILE="/data/adb/auto-download/auto-download.pid"
WAKEUP_COUNT_FILE="/sys/power/wakeup_count"
WAKE_LOCK_FILE="/sys/power/wake_lock"

# Fungsi logging
log_monitor() {
    local message="$1"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $message" >> "$LOG_FILE"
}

# Pastikan direktori log ada
mkdir -p "/data/adb/auto-download" 2>/dev/null

# Inisialisasi log
log_monitor "Wakelock Monitor for auto-download.sh started"
log_monitor "Monitoring files: $WAKEUP_COUNT_FILE, $WAKE_LOCK_FILE"

# Cek apakah file monitoring tersedia
if [ ! -f "$WAKEUP_COUNT_FILE" ]; then
    log_monitor "ERROR: $WAKEUP_COUNT_FILE not found - wakelock monitoring not supported"
    exit 1
fi

# Fungsi untuk mengirim signal ke auto-download.sh
send_wake_signal() {
    local reason="$1"
    
    if [ -f "$AUTODOWNLOAD_PID_FILE" ]; then
        local AUTODOWNLOAD_PID=$(cat "$AUTODOWNLOAD_PID_FILE" 2>/dev/null)
        
        if [ -n "$AUTODOWNLOAD_PID" ] && kill -0 "$AUTODOWNLOAD_PID" 2>/dev/null; then
            # Kirim SIGUSR1 untuk trigger recalculation
            if kill -USR1 "$AUTODOWNLOAD_PID" 2>/dev/null; then
                log_monitor "Signal sent to auto-download.sh PID: $AUTODOWNLOAD_PID ($reason)"
                return 0
            else
                log_monitor "Failed to send signal to PID: $AUTODOWNLOAD_PID"
                return 1
            fi
        else
            log_monitor "auto-download.sh PID not found or not running: $AUTODOWNLOAD_PID"
            return 1
        fi
    else
        log_monitor "auto-download.sh PID file not found: $AUTODOWNLOAD_PID_FILE"
        return 1
    fi
}

# Simpan state awal
last_wakeup_count=$(cat "$WAKEUP_COUNT_FILE" 2>/dev/null || echo "0")
last_active_locks=""

log_monitor "Initial wakeup count: $last_wakeup_count"

# Monitor menggunakan inotify untuk efisiensi
{
    # Monitor wakeup count untuk deteksi wake dari deep sleep
    inotifywait -m -e modify "$WAKEUP_COUNT_FILE" 2>/dev/null | while read path action file; do
        current_wakeup_count=$(cat "$WAKEUP_COUNT_FILE" 2>/dev/null || echo "0")
        
        # Deteksi peningkatan wakeup count (indikasi wake dari deep sleep)
        if [ "$current_wakeup_count" -gt "$last_wakeup_count" ]; then
            log_monitor "Wake from deep sleep detected - count: $last_wakeup_count → $current_wakeup_count"
            send_wake_signal "deep sleep wake"
        fi
        
        last_wakeup_count=$current_wakeup_count
    done &
    
    # Monitor wakelock changes untuk deteksi transisi ke deep sleep
    inotifywait -m -e modify "$WAKE_LOCK_FILE" 2>/dev/null | while read path action file; do
        current_active_locks=$(cat "$WAKE_LOCK_FILE" 2>/dev/null || echo "")
        
        # Log perubahan wakelock untuk debugging
        if [ "$current_active_locks" != "$last_active_locks" ]; then
            if [ -z "$current_active_locks" ] && [ -n "$last_active_locks" ]; then
                log_monitor "All wakelocks released - deep sleep imminent"
            elif [ -n "$current_active_locks" ] && [ -z "$last_active_locks" ]; then
                log_monitor "Wakelock acquired - system staying awake: $current_active_locks"
                # Bisa juga trigger recalculation saat ada wakelock baru
                send_wake_signal "wakelock acquired"
            fi
        fi
        
        last_active_locks=$current_active_locks
    done &
    
    # Fallback monitoring menggunakan polling (jika inotify gagal)
    while true; do
        sleep 30  # Check setiap 30 detik sebagai fallback
        
        current_wakeup_count=$(cat "$WAKEUP_COUNT_FILE" 2>/dev/null || echo "0")
        if [ "$current_wakeup_count" -gt "$last_wakeup_count" ]; then
            log_monitor "Fallback: Wake event detected - count: $last_wakeup_count → $current_wakeup_count"
            send_wake_signal "fallback detection"
            last_wakeup_count=$current_wakeup_count
        fi
    done &
    
    # Wait untuk semua background processes
    wait
}