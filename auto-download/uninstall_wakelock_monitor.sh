#!/system/bin/sh
# Uninstaller untuk Wakelock Monitor auto-download.sh

TARGET_MONITOR="/system/bin/wakelock_monitor_autodownload.sh"
TARGET_INIT="/system/etc/init/wakelock_autodownload_monitor.rc"
LOG_FILE="/data/adb/auto-download/wakelock_monitor.log"

echo "=== Wakelock Monitor Uninstaller ==="
echo ""

# Cek apakah script dijalankan sebagai root
if [ "$(id -u)" != "0" ]; then
    echo "ERROR: This script must be run as root"
    echo "Please run: su -c '$0'"
    exit 1
fi

# Stop service jika sedang berjalan
echo "Stopping wakelock monitor service..."
setprop ctl.stop wakelock_autodownload_monitor 2>/dev/null

# Kill process jika masih berjalan
MONITOR_PID=$(ps | grep wakelock_monitor_autodownload.sh | grep -v grep | awk '{print $2}')
if [ -n "$MONITOR_PID" ]; then
    echo "Killing monitor process: $MONITOR_PID"
    kill "$MONITOR_PID" 2>/dev/null
fi

# Mount system sebagai read-write
echo "Mounting /system as read-write..."
mount -o remount,rw /system
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to mount /system as read-write"
    exit 1
fi

# Remove files
echo "Removing installed files..."

if [ -f "$TARGET_MONITOR" ]; then
    rm -f "$TARGET_MONITOR"
    echo "✓ Removed: $TARGET_MONITOR"
else
    echo "- Monitor script not found: $TARGET_MONITOR"
fi

if [ -f "$TARGET_INIT" ]; then
    rm -f "$TARGET_INIT"
    echo "✓ Removed: $TARGET_INIT"
else
    echo "- Init config not found: $TARGET_INIT"
fi

# Mount system sebagai read-only kembali
echo "Mounting /system as read-only..."
mount -o remount,ro /system

# Optional: remove log file
echo ""
echo "Do you want to remove the log file? ($LOG_FILE)"
echo "Enter 'y' to remove, any other key to keep:"
read -r response
if [ "$response" = "y" ] || [ "$response" = "Y" ]; then
    rm -f "$LOG_FILE" 2>/dev/null
    echo "✓ Log file removed"
else
    echo "- Log file kept for reference"
fi

echo ""
echo "=== Uninstallation Complete ==="
echo ""
echo "The wakelock monitor has been removed."
echo "auto-download.sh will continue to work normally without deep sleep wake detection."
echo ""
echo "Reboot recommended to ensure all changes take effect."
echo ""