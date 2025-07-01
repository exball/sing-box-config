#!/bin/sh

# Script untuk memeriksa dan mengupdate file auto-download.sh
# Script ini akan memeriksa hash SHA-1 dari file tersebut dan mengunduhnya jika berbeda

# ===== KONFIGURASI DASAR =====
# URL untuk file yang akan diperiksa
SCRIPT_UPDATE_URL="https://raw.githubusercontent.com/exball/sing-box-config/refs/heads/Master/auto-download/auto-download.sh"

# Path lokal untuk file tersebut
SCRIPT_FILE="/data/adb/auto-download/auto-download.sh"

# Direktori sementara untuk file yang didownload
TEMP_DIR="/data/adb/auto-download/download_temp"

# Pengaturan jaringan
NETWORK_TEST_URL="https://www.google.com"
NETWORK_MAX_ATTEMPTS=5
NETWORK_RETRY_WAIT=3

# File log
LOG_FILE="/data/adb/auto-download/check-update.log"

# ===== PERSIAPAN =====
# Pastikan direktori yang diperlukan ada
mkdir -p /data/adb/auto-download
mkdir -p "$TEMP_DIR"

# Kosongkan log file setiap kali script dijalankan
if [ -n "$LOG_FILE" ]; then
    > "$LOG_FILE"
fi

# Variabel untuk melacak apakah header timestamp sudah ditulis
TIMESTAMP_HEADER_WRITTEN=0

# ===== FUNGSI UTILITAS =====
# Fungsi untuk logging
log_message() {
    local message="$1"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    # Echo ke konsol dengan timestamp
    echo "$timestamp: $message"
    
    # Tulis ke file log jika dikonfigurasi
    if [ -n "$LOG_FILE" ]; then
        # Jika ini adalah pesan pertama setelah log dikosongkan, tulis header timestamp
        if [ $TIMESTAMP_HEADER_WRITTEN -eq 0 ]; then
            echo "$timestamp:" >> "$LOG_FILE"
            TIMESTAMP_HEADER_WRITTEN=1
        fi
        
        # Tulis pesan tanpa timestamp
        echo "$message" >> "$LOG_FILE"
    fi
}

# Fungsi get_local_sha1 sudah didefinisikan di auto-download.sh
# (dipanggil melalui source auto-download.sh)

# Fungsi helper untuk operasi curl - pemeriksaan koneksi network
curl_network_check() {
    local test_url="$1"
    local timeout_connect="${2:-5}"
    local timeout_max="${3:-10}"
    
    if [ -z "$test_url" ]; then
        log_message "Error: URL test tidak boleh kosong"
        return 1
    fi
    
    curl -s -f -m "$timeout_max" --connect-timeout "$timeout_connect" -o /dev/null "$test_url"
    return $?
}

# Fungsi helper untuk operasi curl - download file
curl_download_file() {
    local source_url="$1"
    local output_file="$2"
    local timeout_connect="${3:-10}"
    local timeout_max="${4:-30}"
    
    if [ -z "$source_url" ] || [ -z "$output_file" ]; then
        log_message "Error: URL sumber dan file output tidak boleh kosong"
        return 1
    fi
    
    # Pastikan direktori output ada
    mkdir -p "$(dirname "$output_file")" 2>/dev/null || {
        log_message "Peringatan: Gagal membuat direktori: $(dirname "$output_file")"
    }
    
    # Download file dengan follow redirects
    curl -s -L --connect-timeout "$timeout_connect" --max-time "$timeout_max" "$source_url" -o "$output_file"
    local curl_exit_code=$?
    
    # Jika gagal, hapus file yang mungkin sudah dibuat (partial download)
    if [ $curl_exit_code -ne 0 ]; then
        rm -f "$output_file" 2>/dev/null
    fi
    
    return $curl_exit_code
}

# Fungsi untuk memeriksa koneksi jaringan
check_network_connection() {
    log_message "Memeriksa koneksi internet..."
    
    local attempt=1
    local connected=0
    
    while [ $attempt -le $NETWORK_MAX_ATTEMPTS ]; do
        log_message "Percobaan koneksi ke $NETWORK_TEST_URL (Percobaan $attempt dari $NETWORK_MAX_ATTEMPTS)"
        
        # Gunakan curl untuk memeriksa koneksi ke URL yang ditentukan
        if curl_network_check "$NETWORK_TEST_URL"; then
            log_message "Koneksi internet tersedia"
            connected=1
            break
        fi
        
        # Jika tidak ada koneksi, tunggu dan coba lagi
        log_message "Tidak ada koneksi internet, Tunggu $NETWORK_RETRY_WAIT detik."
        
        if [ $attempt -lt $NETWORK_MAX_ATTEMPTS ]; then
            sleep $NETWORK_RETRY_WAIT
        fi
        
        # Tambahkan jumlah percobaan
        attempt=$((attempt + 1))
    done
    
    if [ $connected -eq 0 ]; then
        log_message "Gagal terhubung ke jaringan setelah $NETWORK_MAX_ATTEMPTS percobaan"
        return 1
    fi
    
    return 0
}

# Fungsi untuk memeriksa dan mengupdate file (menggunakan helper dari auto-download.sh)
check_and_update_file() {
    local file_url="$1"
    local local_file="$2"
    local file_name=$(basename "$local_file")
    
    # Tentukan apakah file perlu executable permission (untuk .sh files)
    local set_executable=0
    if [ "${file_name##*.}" = "sh" ]; then
        set_executable=1
    fi
    
    # Gunakan helper function dari auto-download.sh
    update_file_with_backup "$file_url" "$local_file" "$file_name" "$set_executable"
}

# ===== FUNGSI UTAMA =====
# Fungsi untuk menjalankan pemeriksaan dan pembaruan
run_update_check() {
    # Periksa koneksi jaringan terlebih dahulu
    check_network_connection
    if [ $? -ne 0 ]; then
        log_message "Proses pemeriksaan file dibatalkan karena tidak ada koneksi internet"
        return 1
    fi
    
    log_message "Memulai proses pemeriksaan file"
    
    # Variabel untuk melacak apakah ada file yang diperbarui
    local files_updated=0
    
    # Periksa dan update file auto-download.sh
    check_and_update_file "$SCRIPT_UPDATE_URL" "$SCRIPT_FILE"
    local script_result=$?
    
    if [ $script_result -eq 2 ]; then
        files_updated=1
    fi
    
    # Jika ada file yang diperbarui, restart layanan jika diperlukan
    if [ $files_updated -eq 1 ]; then
        log_message "File auto-download.sh telah diperbarui, perlu me-restart layanan"
        
        # Cari script restart-auto-download.sh
        local restart_script="/data/adb/auto-download/restart-auto-download.sh"
        
        # Pastikan restart script dapat dieksekusi jika ada
        if [ -f "$restart_script" ]; then
            chmod +x "$restart_script"
        fi
        
        if [ -x "$restart_script" ]; then
            log_message "Menjalankan restart-auto-download.sh untuk me-restart dengan versi terbaru..."
            sh "$restart_script"
            log_message "Restart script telah dijalankan"
        else
            log_message "Script restart-auto-download.sh tidak ditemukan atau tidak dapat dieksekusi"
            log_message "Mencoba restart manual..."
            
            # Fallback: restart manual jika restart script tidak tersedia
            if pgrep -f "auto-download.sh" > /dev/null; then
                log_message "Mendeteksi auto-download.sh sedang berjalan, mencoba me-restart..."
                
                # Hentikan proses yang sedang berjalan
                pkill -f "auto-download.sh"
                sleep 2
                
                # Pastikan auto-download.sh dapat dieksekusi
                if [ -f "$SCRIPT_FILE" ]; then
                    chmod +x "$SCRIPT_FILE"
                fi
                
                # Jalankan kembali auto-download.sh
                if [ -x "$SCRIPT_FILE" ]; then
                    log_message "Menjalankan kembali auto-download.sh..."
                    nohup sh "$SCRIPT_FILE" > /dev/null 2>&1 &
                    log_message "auto-download.sh telah di-restart dengan PID: $!"
                else
                    log_message "PERINGATAN: auto-download.sh tidak dapat dieksekusi"
                fi
            else
                log_message "auto-download.sh tidak sedang berjalan, tidak perlu di-restart"
            fi
        fi
        
        log_message "Proses pemeriksaan selesai - auto-download.sh telah diperbarui dan di-restart"
        # Return 1 untuk memberi tahu auto-download.sh bahwa ada update dan telah di-restart
        # Auto-download.sh yang memanggil script ini harus berhenti
        exit 1
    else
        log_message "Tidak ada pembaruan pada auto-download.sh"
        log_message "Proses pemeriksaan selesai - melanjutkan proses normal"
        return 0
    fi
}

# ===== EKSEKUSI UTAMA =====
# Inisialisasi file log jika belum ada
if [ -n "$LOG_FILE" ] && [ ! -f "$LOG_FILE" ]; then
    touch "$LOG_FILE"
fi

# Jalankan pemeriksaan dan pembaruan
log_message "Memulai check-update.sh"
run_update_check
exit_code=$?
log_message "check-update.sh selesai dengan kode: $exit_code"

exit $exit_code