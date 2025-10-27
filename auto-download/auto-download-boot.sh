#!/system/bin/sh
# Script boot untuk menjalankan auto-download.sh
# Letakkan script ini di /data/adb/service.d/ dengan nama auto-download-boot.sh
# dan pastikan memiliki izin eksekusi (chmod +x)

# Tunggu beberapa saat untuk memastikan sistem sudah siap
sleep 30

# Path ke script auto-download.sh
SCRIPT_PATH="/data/adb/auto-download/restart-auto-download.sh"

# Pastikan direktori yang diperlukan ada
mkdir -p /data/adb/auto-download
mkdir -p /data/adb/auto-download/download_temp

# File log untuk boot
BOOT_LOG="/data/adb/auto-download/boot.log"

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
    if [ -f "/data/adb/service.d/restart-auto-download.sh" ]; then
        cp "/data/adb/service.d/restart-auto-download.sh" "$SCRIPT_PATH"
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

# Periksa apakah script sudah berjalan
PID=$(ps -ef | grep "[a]uto-download.sh" | grep -v auto-download-boot | head -1 | awk '{print $2}')
if [ -n "$PID" ] && [ "$PID" -eq "$PID" ] 2>/dev/null; then
    log_boot "Script auto-download.sh sudah berjalan dengan PID $PID"
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