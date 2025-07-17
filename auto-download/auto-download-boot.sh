#!/system/bin/sh
# Script boot untuk menjalankan auto-download.sh
# Letakkan script ini di /data/adb/service.d/ dengan nama auto-download-boot.sh
# dan pastikan memiliki izin eksekusi (chmod +x)

# Tunggu beberapa saat untuk memastikan sistem sudah siap
sleep 30

# Path ke script auto-download.sh
SCRIPT_PATH="/data/adb/auto-download/auto-download.sh"

# Pastikan direktori yang diperlukan ada
mkdir -p /data/adb/auto-download
mkdir -p /data/adb/auto-download/download_temp

# File log untuk boot
BOOT_LOG="/data/adb/auto-download/boot.log"

# Path ke file PID lock
PID_FILE="/data/adb/auto-download/auto-download.pid"
LOCK_FILE="/data/adb/auto-download/auto-download.lock"

# Fungsi untuk logging
log_boot() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $1" >> "$BOOT_LOG"
}

# Buat log baru setiap kali boot
echo "--- Boot pada $(date '+%Y-%m-%d %H:%M:%S') ---" > "$BOOT_LOG"

# Periksa apakah script utama ada
if [ ! -f "$SCRIPT_PATH" ]; then
    log_boot "ERROR: Script utama tidak ditemukan di $SCRIPT_PATH"
    
    # Coba salin dari direktori service.d jika ada
    if [ -f "/data/adb/service.d/auto-download.sh" ]; then
        cp "/data/adb/service.d/auto-download.sh" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
        log_boot "Script disalin dari /data/adb/service.d/ ke $SCRIPT_PATH"
    else
        log_boot "Script tidak ditemukan di /data/adb/service.d/ juga"
        exit 1
    fi
fi

# Pastikan script memiliki izin eksekusi
chmod +x "$SCRIPT_PATH"
log_boot "Izin eksekusi diberikan ke $SCRIPT_PATH"

# Periksa apakah script sudah berjalan menggunakan PID lock
if [ -f "$LOCK_FILE" ]; then
    EXISTING_PID=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ -n "$EXISTING_PID" ] && kill -0 "$EXISTING_PID" 2>/dev/null; then
        # Periksa apakah PID tersebut benar-benar auto-download.sh
        if ps -p "$EXISTING_PID" | grep -q "auto-download.sh\|sh.*auto-download"; then
            log_boot "Script auto-download.sh sudah berjalan dengan PID $EXISTING_PID"
            exit 0
        else
            # PID bukan auto-download.sh, hapus lock file
            log_boot "Menghapus lock file yang tidak valid (PID $EXISTING_PID bukan auto-download.sh)"
            rm -f "$LOCK_FILE" "$PID_FILE" 2>/dev/null
        fi
    else
        # PID tidak valid, hapus lock file
        log_boot "Menghapus lock file yang sudah tidak valid (PID $EXISTING_PID tidak berjalan)"
        rm -f "$LOCK_FILE" "$PID_FILE" 2>/dev/null
    fi
fi

# Fallback: periksa menggunakan ps jika lock file tidak ada
PID=$(ps -ef | grep "[a]uto-download.sh" | grep -v auto-download-boot | head -1 | awk '{print $2}')
if [ -n "$PID" ] && [ "$PID" -eq "$PID" ] 2>/dev/null; then
    log_boot "Script auto-download.sh sudah berjalan dengan PID $PID (detected via ps)"
    exit 0
fi

# Jalankan script utama
log_boot "Menjalankan script auto-download.sh..."
sh "$SCRIPT_PATH" > /dev/null 2>&1 &

# Tunggu sebentar
sleep 5

# Periksa apakah script berhasil dijalankan
NEW_PID=$(ps -ef | grep "[a]uto-download.sh" | grep -v auto-download-boot | head -1 | awk '{print $2}')
if [ -n "$NEW_PID" ] && [ "$NEW_PID" -eq "$NEW_PID" ] 2>/dev/null; then
    log_boot "Script auto-download.sh berhasil dijalankan dengan PID $NEW_PID"
else
    log_boot "PERINGATAN: Script auto-download.sh gagal dijalankan"
    
    # Coba jalankan dengan cara lain
    log_boot "Mencoba menjalankan dengan cara lain..."
    nohup sh "$SCRIPT_PATH" > /dev/null 2>&1 &
    
    sleep 5
    
    # Periksa lagi
    FINAL_PID=$(ps -ef | grep "[a]uto-download.sh" | grep -v auto-download-boot | head -1 | awk '{print $2}')
    if [ -n "$FINAL_PID" ] && [ "$FINAL_PID" -eq "$FINAL_PID" ] 2>/dev/null; then
        log_boot "Script auto-download.sh berhasil dijalankan dengan PID $FINAL_PID pada percobaan kedua"
    else
        log_boot "KRITIS: Script auto-download.sh gagal dijalankan setelah beberapa percobaan"
    fi
fi

# Tunggu beberapa saat untuk memastikan auto-download.sh sudah berjalan dengan baik
sleep 30

# Catat pesan terakhir sebelum menghapus file boot.log
log_boot "Proses boot selesai"

# Buat salinan log boot untuk referensi (opsional)
# cp "$BOOT_LOG" "/data/adb/auto-download/boot_last.log" 2>/dev/null

# Hapus file boot.log setelah auto-download.sh berjalan
rm -f "$BOOT_LOG"

exit 0