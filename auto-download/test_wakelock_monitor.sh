#!/system/bin/sh
# Testing script untuk Wakelock Monitor auto-download.sh

AUTODOWNLOAD_PID_FILE="/data/adb/auto-download/auto-download.pid"
MONITOR_LOG="/data/adb/auto-download/wakelock_monitor.log"
AUTODOWNLOAD_LOG="/data/adb/auto-download/auto-download.log"

echo "=== Wakelock Monitor Test Script ==="
echo ""

# Fungsi untuk menampilkan status
show_status() {
    echo "=== Current Status ==="
    
    # Cek auto-download.sh
    if [ -f "$AUTODOWNLOAD_PID_FILE" ]; then
        AUTODOWNLOAD_PID=$(cat "$AUTODOWNLOAD_PID_FILE")
        if kill -0 "$AUTODOWNLOAD_PID" 2>/dev/null; then
            echo "✓ auto-download.sh is running (PID: $AUTODOWNLOAD_PID)"
        else
            echo "✗ auto-download.sh PID file exists but process not running"
        fi
    else
        echo "✗ auto-download.sh PID file not found"
    fi
    
    # Cek wakelock monitor
    MONITOR_PID=$(ps | grep wakelock_monitor_autodownload.sh | grep -v grep | awk '{print $2}')
    if [ -n "$MONITOR_PID" ]; then
        echo "✓ Wakelock monitor is running (PID: $MONITOR_PID)"
    else
        echo "✗ Wakelock monitor is not running"
    fi
    
    # Cek file monitoring
    if [ -f "/sys/power/wakeup_count" ]; then
        WAKEUP_COUNT=$(cat /sys/power/wakeup_count 2>/dev/null)
        echo "✓ Wakeup count available: $WAKEUP_COUNT"
    else
        echo "✗ Wakeup count not available"
    fi
    
    if [ -f "/sys/power/wake_lock" ]; then
        WAKE_LOCKS=$(cat /sys/power/wake_lock 2>/dev/null)
        if [ -n "$WAKE_LOCKS" ]; then
            echo "✓ Active wakelocks: $WAKE_LOCKS"
        else
            echo "✓ No active wakelocks"
        fi
    else
        echo "✗ Wakelock file not available"
    fi
    
    echo ""
}

# Fungsi untuk test signal
test_signal() {
    echo "=== Testing Signal Communication ==="
    
    if [ -f "$AUTODOWNLOAD_PID_FILE" ]; then
        AUTODOWNLOAD_PID=$(cat "$AUTODOWNLOAD_PID_FILE")
        if kill -0 "$AUTODOWNLOAD_PID" 2>/dev/null; then
            echo "Sending SIGUSR1 to auto-download.sh (PID: $AUTODOWNLOAD_PID)..."
            
            # Ambil timestamp sebelum signal
            BEFORE_TIME=$(date "+%Y-%m-%d %H:%M:%S")
            
            # Kirim signal
            kill -USR1 "$AUTODOWNLOAD_PID" 2>/dev/null
            
            if [ $? -eq 0 ]; then
                echo "✓ Signal sent successfully"
                echo "Check the auto-download.sh log for wake event processing..."
                echo ""
                
                # Tunggu sebentar dan cek log
                sleep 2
                echo "Recent log entries after signal:"
                if [ -f "$AUTODOWNLOAD_LOG" ]; then
                    tail -5 "$AUTODOWNLOAD_LOG" | grep -A5 -B5 "Deep sleep wake"
                else
                    echo "Log file not found: $AUTODOWNLOAD_LOG"
                fi
            else
                echo "✗ Failed to send signal"
            fi
        else
            echo "✗ auto-download.sh is not running"
        fi
    else
        echo "✗ auto-download.sh PID file not found"
    fi
    
    echo ""
}

# Fungsi untuk monitor logs real-time
monitor_logs() {
    echo "=== Real-time Log Monitoring ==="
    echo "Press Ctrl+C to stop monitoring"
    echo ""
    
    # Monitor kedua log file secara bersamaan
    {
        if [ -f "$MONITOR_LOG" ]; then
            tail -f "$MONITOR_LOG" | sed 's/^/[MONITOR] /' &
        fi
        
        if [ -f "$AUTODOWNLOAD_LOG" ]; then
            tail -f "$AUTODOWNLOAD_LOG" | sed 's/^/[AUTO-DL] /' &
        fi
        
        wait
    }
}

# Fungsi untuk simulate deep sleep test
simulate_deep_sleep_test() {
    echo "=== Deep Sleep Simulation Test ==="
    echo ""
    echo "This test will:"
    echo "1. Turn off the screen"
    echo "2. Wait for potential deep sleep"
    echo "3. Wake the device"
    echo "4. Check for wake detection"
    echo ""
    echo "Make sure to monitor the logs during this test."
    echo "Press Enter to continue or Ctrl+C to cancel..."
    read
    
    echo "Turning off screen..."
    input keyevent POWER
    
    echo "Waiting 60 seconds for potential deep sleep..."
    echo "Device should enter deep sleep during this time..."
    sleep 60
    
    echo "Waking device..."
    input keyevent POWER
    
    echo "Waiting for wake detection..."
    sleep 5
    
    echo "Checking recent logs for wake events:"
    if [ -f "$MONITOR_LOG" ]; then
        echo "=== Monitor Log ==="
        tail -10 "$MONITOR_LOG" | grep -i wake
    fi
    
    if [ -f "$AUTODOWNLOAD_LOG" ]; then
        echo "=== Auto-download Log ==="
        tail -10 "$AUTODOWNLOAD_LOG" | grep -i "wake\|signal"
    fi
}

# Menu utama
while true; do
    echo "=== Test Menu ==="
    echo "1. Show Status"
    echo "2. Test Signal Communication"
    echo "3. Monitor Logs (Real-time)"
    echo "4. Simulate Deep Sleep Test"
    echo "5. Exit"
    echo ""
    echo "Choose option (1-5): "
    read -r choice
    
    case $choice in
        1)
            show_status
            ;;
        2)
            test_signal
            ;;
        3)
            monitor_logs
            ;;
        4)
            simulate_deep_sleep_test
            ;;
        5)
            echo "Exiting..."
            exit 0
            ;;
        *)
            echo "Invalid option. Please choose 1-5."
            ;;
    esac
    
    echo "Press Enter to continue..."
    read
    clear
done