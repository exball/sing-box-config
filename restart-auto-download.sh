#!/bin/bash

# Script untuk me-restart auto-download.sh
# Gunakan: sh restart-auto-download.sh

# Path ke script auto-download.sh
SCRIPT_PATH="/data/adb/auto-download/auto-download.sh"

# Path ke file PID
PID_FILE="/data/adb/auto-download/auto-download.pid"

# Path ke file boot.log
BOOT_LOG_FILE="/data/adb/auto-download/boot.log"

# Path ke file log
LOG_FILE="/data/adb/auto-download/restart.log"

# Fungsi untuk logging
log_message() {
    local message="$1"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    # Echo ke konsol dengan timestamp
    echo "$timestamp: $message"
    
    # Tulis ke file log
    if [ -n "$LOG_FILE" ]; then
        echo "$timestamp: $message" >> "$LOG_FILE"
    fi
}

# Pastikan direktori log ada
mkdir -p "$(dirname "$LOG_FILE")"

# Inisialisasi file log
log_message "===== MEMULAI PROSES RESTART ====="

# Hapus file boot.log jika ada untuk mencegah deteksi mode boot yang salah
if [ -f "$BOOT_LOG_FILE" ]; then
    log_message "Menghapus file boot.log untuk mencegah deteksi mode boot yang salah..."
    rm -f "$BOOT_LOG_FILE"
    if [ ! -f "$BOOT_LOG_FILE" ]; then
        log_message "File boot.log berhasil dihapus"
    else
        log_message "PERINGATAN: Gagal menghapus file boot.log"
    fi
fi

log_message "Memeriksa apakah script auto-download.sh sedang berjalan..."

# Cari semua PID yang terkait dengan auto-download.sh
ALL_PIDS=$(ps -ef | grep auto-download.sh | grep -v grep | grep -v restart | awk '{print $2}')

# Cek apakah file PID ada
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    log_message "PID dari file PID: $OLD_PID"
    
    # Cek apakah proses dengan PID tersebut masih berjalan
    if kill -0 "$OLD_PID" 2>/dev/null; then
        log_message "Menghentikan proses auto-download.sh dengan PID $OLD_PID..."
        kill "$OLD_PID"
        
        # Tunggu beberapa detik untuk memastikan proses benar-benar berhenti
        sleep 3
        
        # Periksa lagi apakah proses masih berjalan
        if kill -0 "$OLD_PID" 2>/dev/null; then
            log_message "Proses masih berjalan, mencoba menghentikan paksa..."
            kill -9 "$OLD_PID"
            sleep 2
        fi
    else
        log_message "Tidak ada proses yang berjalan dengan PID $OLD_PID"
    fi
    
    # Hapus file PID lama
    rm -f "$PID_FILE"
    log_message "File PID lama dihapus"
else
    log_message "File PID tidak ditemukan"
fi

# Hentikan semua proses auto-download.sh yang mungkin masih berjalan
if [ -n "$ALL_PIDS" ]; then
    log_message "Menemukan proses auto-download.sh yang berjalan: $ALL_PIDS"
    for pid in $ALL_PIDS; do
        log_message "Menghentikan proses dengan PID $pid..."
        kill "$pid" 2>/dev/null
    done
    
    # Tunggu sebentar
    sleep 3
    
    # Periksa lagi dan paksa hentikan jika masih berjalan
    STILL_RUNNING=$(ps -ef | grep auto-download.sh | grep -v grep | grep -v restart | awk '{print $2}')
    if [ -n "$STILL_RUNNING" ]; then
        log_message "Beberapa proses masih berjalan, menghentikan paksa: $STILL_RUNNING"
        for pid in $STILL_RUNNING; do
            kill -9 "$pid" 2>/dev/null
        done
        sleep 2
    fi
fi

# Periksa sekali lagi apakah ada proses yang masih berjalan
RUNNING_PID=$(ps -ef | grep auto-download.sh | grep -v grep | grep -v restart | awk '{print $2}')
if [ -n "$RUNNING_PID" ]; then
    log_message "PERINGATAN: Proses auto-download.sh masih berjalan dengan PID $RUNNING_PID"
    log_message "Mencoba menghentikan paksa untuk terakhir kali..."
    for pid in $RUNNING_PID; do
        kill -9 "$pid" 2>/dev/null
    done
    sleep 2
fi

# Pastikan script memiliki izin eksekusi
if [ -f "$SCRIPT_PATH" ]; then
    chmod +x "$SCRIPT_PATH"
    log_message "Memberikan izin eksekusi ke $SCRIPT_PATH"
else
    log_message "KESALAHAN FATAL: Script $SCRIPT_PATH tidak ditemukan!"
    exit 1
fi

# Jalankan script baru dengan nohup untuk memastikan tetap berjalan
log_message "Memulai script auto-download.sh yang baru..."
nohup "$SCRIPT_PATH" > /dev/null 2>&1 &
NEW_PID=$!
log_message "Script baru dijalankan dengan PID $NEW_PID"

# Tunggu sebentar untuk memastikan script berjalan
sleep 5

# Periksa apakah script berjalan
VERIFY_PID=$(ps -ef | grep auto-download.sh | grep -v grep | grep -v restart | awk '{print $2}')
if [ -n "$VERIFY_PID" ]; then
    log_message "Verifikasi: Script auto-download.sh berhasil dijalankan dengan PID: $VERIFY_PID"
    
    # Simpan PID baru ke file PID
    echo "$VERIFY_PID" > "$PID_FILE"
    log_message "PID baru disimpan ke file PID"
else
    log_message "PERINGATAN: Script auto-download.sh gagal dijalankan, mencoba sekali lagi..."
    
    # Coba jalankan dengan sh
    nohup sh "$SCRIPT_PATH" > /dev/null 2>&1 &
    NEW_PID=$!
    log_message "Mencoba menjalankan dengan 'sh', PID: $NEW_PID"
    
    # Tunggu sebentar
    sleep 5
    
    # Verifikasi lagi
    VERIFY_PID=$(ps -ef | grep auto-download.sh | grep -v grep | grep -v restart | awk '{print $2}')
    if [ -n "$VERIFY_PID" ]; then
        log_message "Verifikasi kedua: Script auto-download.sh berhasil dijalankan dengan PID: $VERIFY_PID"
        echo "$VERIFY_PID" > "$PID_FILE"
        log_message "PID baru disimpan ke file PID"
    else
        log_message "KESALAHAN FATAL: Script auto-download.sh gagal dijalankan setelah beberapa percobaan"
    fi
fi

log_message "===== PROSES RESTART SELESAI ====="