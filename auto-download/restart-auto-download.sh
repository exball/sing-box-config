#!/bin/sh

# Script untuk me-restart auto-download.sh
# Gunakan: sh restart-auto-download.sh


# Path ke script auto-download.sh
SCRIPT_PATH="/data/adb/auto-download/auto-download.sh"

# Path ke file boot.log
BOOT_LOG_FILE="/data/adb/auto-download/boot.log"

# Path ke file PID lock
PID_FILE="/data/adb/auto-download/auto-download.pid"
LOCK_FILE="/data/adb/auto-download/auto-download.lock"

# Hapus file boot.log jika ada untuk mencegah deteksi mode boot yang salah
if [ -f "$BOOT_LOG_FILE" ]; then
    echo "Menghapus file boot.log untuk mencegah deteksi mode boot yang salah..."
    rm -f "$BOOT_LOG_FILE"
    if [ ! -f "$BOOT_LOG_FILE" ]; then
        echo "File boot.log berhasil dihapus"
    else
        echo "PERINGATAN: Gagal menghapus file boot.log"
    fi
fi

# Hapus file PID lock untuk memastikan instance baru bisa berjalan
echo "Menghapus file PID lock..."
rm -f "$PID_FILE" "$LOCK_FILE" 2>/dev/null

echo "Memeriksa semua proses auto-download.sh yang sedang berjalan..."

# Cari semua PID yang menjalankan auto-download.sh
RUNNING_PIDS=$(ps -ef | grep "[a]uto-download.sh" | grep -v restart | awk '{print $2}')

if [ -n "$RUNNING_PIDS" ]; then
    echo "Ditemukan proses auto-download.sh yang berjalan:"
    for PID in $RUNNING_PIDS; do
        if [ -n "$PID" ] && [ "$PID" -eq "$PID" ] 2>/dev/null; then
            echo "  PID: $PID"
        fi
    done
    
    echo "Menghentikan semua proses auto-download.sh..."
    for PID in $RUNNING_PIDS; do
        if [ -n "$PID" ] && [ "$PID" -eq "$PID" ] 2>/dev/null; then
            echo "Menghentikan PID $PID..."
            kill "$PID" 2>/dev/null
        fi
    done
    
    # Tunggu beberapa detik untuk memastikan proses benar-benar berhenti
    sleep 3
    
    # Periksa apakah masih ada proses yang berjalan dan hentikan paksa jika perlu
    STILL_RUNNING=$(ps -ef | grep "[a]uto-download.sh" | grep -v restart | awk '{print $2}')
    if [ -n "$STILL_RUNNING" ]; then
        echo "Beberapa proses masih berjalan, menghentikan paksa..."
        for PID in $STILL_RUNNING; do
            if [ -n "$PID" ] && [ "$PID" -eq "$PID" ] 2>/dev/null; then
                echo "Menghentikan paksa PID $PID..."
                kill -9 "$PID" 2>/dev/null
            fi
        done
        sleep 2
    fi
else
    echo "Tidak ada proses auto-download.sh yang berjalan"
fi

# Buat file penanda untuk menandakan script dijalankan oleh restart-auto-download.sh
RESTART_FLAG_FILE="/data/adb/auto-download/restart_flag"
echo "$(date +%s)" > "$RESTART_FLAG_FILE"

# Jalankan script baru
echo "Memulai script auto-download.sh yang baru..."
nohup sh "$SCRIPT_PATH" > /dev/null 2>&1 &

# Tunggu sebentar untuk memastikan script berjalan
sleep 2

# Periksa apakah script berjalan
NEW_PID=$(ps -ef | grep "[a]uto-download.sh" | grep -v restart | head -1 | awk '{print $2}')
if [ -n "$NEW_PID" ] && [ "$NEW_PID" -eq "$NEW_PID" ] 2>/dev/null; then
    echo "Script auto-download.sh berhasil dijalankan dengan PID $NEW_PID"
else
    echo "PERINGATAN: Script auto-download.sh gagal dijalankan"
fi

echo "Proses restart selesai"