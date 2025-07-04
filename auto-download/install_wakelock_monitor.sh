#!/system/bin/sh
# Installer untuk Wakelock Monitor auto-download.sh
# Script ini akan menginstall dan mengkonfigurasi wakelock monitoring

SCRIPT_DIR="$(dirname "$0")"
MONITOR_SCRIPT="$SCRIPT_DIR/wakelock_monitor_autodownload.sh"
INIT_CONFIG="$SCRIPT_DIR/wakelock_autodownload_monitor.rc"

# Target locations
TARGET_MONITOR="/system/bin/wakelock_monitor_autodownload.sh"
TARGET_INIT="/system/etc/init/wakelock_autodownload_monitor.rc"

echo "=== Wakelock Monitor Installer for auto-download.sh ==="
echo ""

# Cek apakah script dijalankan sebagai root
if [ "$(id -u)" != "0" ]; then
    echo "ERROR: This script must be run as root"
    echo "Please run: su -c '$0'"
    exit 1
fi

# Cek apakah file source ada
if [ ! -f "$MONITOR_SCRIPT" ]; then
    echo "ERROR: Monitor script not found: $MONITOR_SCRIPT"
    exit 1
fi

if [ ! -f "$INIT_CONFIG" ]; then
    echo "ERROR: Init config not found: $INIT_CONFIG"
    exit 1
fi

# Cek apakah sistem mendukung wakelock monitoring
echo "Checking system compatibility..."
if [ ! -f "/sys/power/wakeup_count" ]; then
    echo "WARNING: /sys/power/wakeup_count not found"
    echo "Wakelock monitoring may not work on this system"
    echo ""
fi

if [ ! -f "/sys/power/wake_lock" ]; then
    echo "WARNING: /sys/power/wake_lock not found"
    echo "Wakelock monitoring may not work on this system"
    echo ""
fi

# Mount system sebagai read-write
echo "Mounting /system as read-write..."
mount -o remount,rw /system
if [ $? -ne 0 ]; then
    echo "ERROR: Failed to mount /system as read-write"
    echo "Make sure you have root access and system partition is not protected"
    exit 1
fi

# Copy monitor script
echo "Installing monitor script..."
cp "$MONITOR_SCRIPT" "$TARGET_MONITOR"
if [ $? -eq 0 ]; then
    chmod 755 "$TARGET_MONITOR"
    echo "✓ Monitor script installed: $TARGET_MONITOR"
else
    echo "✗ Failed to install monitor script"
    exit 1
fi

# Copy init configuration
echo "Installing init configuration..."
mkdir -p "/system/etc/init" 2>/dev/null
cp "$INIT_CONFIG" "$TARGET_INIT"
if [ $? -eq 0 ]; then
    chmod 644 "$TARGET_INIT"
    echo "✓ Init configuration installed: $TARGET_INIT"
else
    echo "✗ Failed to install init configuration"
    exit 1
fi

# Mount system sebagai read-only kembali
echo "Mounting /system as read-only..."
mount -o remount,ro /system

echo ""
echo "=== Installation Complete ==="
echo ""
echo "Next steps:"
echo "1. Reboot your device to activate the init service"
echo "2. Check if auto-download.sh is running: ps | grep auto-download"
echo "3. Monitor logs:"
echo "   - auto-download.sh: tail -f /data/adb/auto-download/auto-download.log"
echo "   - wakelock monitor: tail -f /data/adb/auto-download/wakelock_monitor.log"
echo ""
echo "To test deep sleep wake detection:"
echo "1. Turn off screen and wait for deep sleep"
echo "2. Wake device and check logs for wake events"
echo ""
echo "To uninstall:"
echo "  rm $TARGET_MONITOR"
echo "  rm $TARGET_INIT"
echo "  reboot"
echo ""