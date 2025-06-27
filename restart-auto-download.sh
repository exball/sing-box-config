#!/bin/bash

# Script untuk me-restart auto-download.sh
# Gunakan: sh restart-auto-download.sh

# Path ke script auto-download.sh
SCRIPT_PATH="/data/adb/auto-download/auto-download.sh"

# Path ke file PID
PID_FILE="/data/adb/auto-download/auto-download.pid"

# Path ke file boot.log
BOOT_LOG_FILE="/data/adb/auto-download/boot.log"

# File PID untuk check-update.sh
CHECK_UPDATE_PID_FILE="/data/adb/auto-download/check-update.pid"

# Fungsi untuk menghentikan proses check-update.sh
stop_check_update() {
    echo "Mencoba menghentikan proses check-update.sh..."
    
    # Cari PID dari check-update.sh dari file PID
    local check_update_pid=""
    if [ -f "$CHECK_UPDATE_PID_FILE" ]; then
        check_update_pid=$(cat "$CHECK_UPDATE_PID_FILE")
    fi
    
    # Jika tidak ada di file PID, cari menggunakan pgrep
    if [ -z "$check_update_pid" ]; then
        check_update_pid=$(ps -ef | grep check-update.sh | grep -v grep | awk '{print $2}')
    fi
    
    if [ -n "$check_update_pid" ]; then
        echo "Menghentikan check-update.sh dengan PID: $check_update_pid"
        kill -15 $check_update_pid
        sleep 1
        
        # Periksa apakah proses masih berjalan
        if kill -0 $check_update_pid 2>/dev/null || pgrep -f "check-update.sh" > /dev/null; then
            echo "Proses check-update.sh masih berjalan, mencoba kill -9..."
            kill -9 $check_update_pid 2>/dev/null
            pkill -9 -f "check-update.sh"
            sleep 1
        fi
        
        echo "Proses check-update.sh telah dihentikan"
    else
        echo "Tidak ada proses check-update.sh yang berjalan"
    fi
    
    # Hapus file PID
    rm -f "$CHECK_UPDATE_PID_FILE"
}

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

# Hentikan check-update.sh jika sedang berjalan
stop_check_update

echo "Memeriksa apakah script auto-download.sh sedang berjalan..."

# Cek apakah file PID ada
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    echo "PID lama ditemukan: $OLD_PID"
    
    # Cek apakah proses dengan PID tersebut masih berjalan
    if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "Menghentikan proses auto-download.sh dengan PID $OLD_PID..."
        kill "$OLD_PID"
        
        # Tunggu beberapa detik untuk memastikan proses benar-benar berhenti
        sleep 3
        
        # Periksa lagi apakah proses masih berjalan
        if kill -0 "$OLD_PID" 2>/dev/null; then
            echo "Proses masih berjalan, mencoba menghentikan paksa..."
            kill -9 "$OLD_PID"
            sleep 2
        fi
    else
        echo "Tidak ada proses yang berjalan dengan PID $OLD_PID"
    fi
else
    echo "File PID tidak ditemukan"
    
    # Cari PID menggunakan ps
    OLD_PID=$(ps -ef | grep auto-download.sh | grep -v grep | grep -v restart | awk '{print $2}')
    
    if [ -n "$OLD_PID" ]; then
        echo "Menemukan proses auto-download.sh dengan PID $OLD_PID"
        echo "Menghentikan proses..."
        kill "$OLD_PID"
        sleep 3
        
        # Periksa lagi apakah proses masih berjalan
        if kill -0 "$OLD_PID" 2>/dev/null; then
            echo "Proses masih berjalan, mencoba menghentikan paksa..."
            kill -9 "$OLD_PID"
            sleep 2
        fi
    fi
fi

# Periksa sekali lagi apakah ada proses yang masih berjalan
RUNNING_PID=$(ps -ef | grep auto-download.sh | grep -v grep | grep -v restart | awk '{print $2}')
if [ -n "$RUNNING_PID" ]; then
    echo "PERINGATAN: Proses auto-download.sh masih berjalan dengan PID $RUNNING_PID"
    echo "Mencoba menghentikan paksa..."
    kill -9 $RUNNING_PID
    sleep 2
fi

# Jalankan script baru
echo "Memulai script auto-download.sh yang baru..."
nohup sh "$SCRIPT_PATH" > /dev/null 2>&1 &

# Tunggu sebentar untuk memastikan script berjalan
sleep 2

# Periksa apakah script berjalan
NEW_PID=$(ps -ef | grep auto-download.sh | grep -v grep | grep -v restart | awk '{print $2}')
if [ -n "$NEW_PID" ]; then
    echo "Script auto-download.sh berhasil dijalankan dengan PID $NEW_PID"
else
    echo "PERINGATAN: Script auto-download.sh gagal dijalankan"
fi

echo "Proses restart selesai"