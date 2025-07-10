#!/bin/sh

# Script untuk memeriksa dan mengupdate file auto-download.sh
# Script ini akan memeriksa hash SHA-1 dari file tersebut dan mengunduhnya jika berbeda

# ===== KONFIGURASI DASAR =====
# URL untuk file yang akan diperiksa
SCRIPT_UPDATE_URL="https://raw.githubusercontent.com/exball/sing-box-config/refs/heads/test/auto-download/auto-download.sh"

# Path lokal untuk file tersebut
SCRIPT_FILE="/data/adb/auto-download/auto-download.sh"

# Direktori sementara untuk file yang didownload
TEMP_DIR="/data/adb/auto-download/download_temp"

# Pengaturan jaringan
NETWORK_TEST_URL="https://www.google.com"
NETWORK_MAX_ATTEMPTS=10
NETWORK_RETRY_WAIT=2

# File log - menggunakan file log yang sama dengan auto-download.sh
LOG_FILE="/data/adb/auto-download/auto-download.log"

# ===== PERSIAPAN =====
# Pastikan direktori yang diperlukan ada
mkdir -p /data/adb/auto-download
mkdir -p "$TEMP_DIR"

# Tidak mengosongkan log file karena melanjutkan dari auto-download.sh
# Log akan ditambahkan setelah log dari auto-download.sh

# Variabel TIMESTAMP_HEADER_WRITTEN tidak diperlukan lagi karena melanjutkan dari auto-download.sh

# ===== FUNGSI UTILITAS =====
# Fungsi untuk logging - melanjutkan dari log auto-download.sh
log_message() {
    local message="$1"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    # Echo ke konsol dengan timestamp
    echo "$timestamp: $message"
    
    # Tulis ke file log jika dikonfigurasi
    # Tidak membuat header timestamp baru karena melanjutkan dari auto-download.sh
    if [ -n "$LOG_FILE" ]; then
        # Tulis pesan tanpa timestamp langsung ke log file
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
    log_message "Checking internet connection"
    
    local attempt=1
    local connected=0
    local last_attempt_logged=0
    
    while [ $attempt -le $NETWORK_MAX_ATTEMPTS ]; do
        # Tampilkan attempt di konsol dengan carriage return untuk menimpa baris yang sama
        printf "\rAttempt %d of %d" "$attempt" "$NETWORK_MAX_ATTEMPTS"
        
        # Simpan attempt terakhir untuk log file
        last_attempt_logged=$attempt
        
        # Gunakan curl untuk memeriksa koneksi ke URL yang ditentukan
        if curl_network_check "$NETWORK_TEST_URL"; then
            # Bersihkan baris attempt di konsol dan tulis hasil sukses
            printf "\r"
            
            # Log dengan format baru: Connected in X(Y) attempt
            log_message "Connected in $last_attempt_logged($NETWORK_MAX_ATTEMPTS) attempt"
            connected=1
            break
        fi
        
        if [ $attempt -lt $NETWORK_MAX_ATTEMPTS ]; then
            sleep $NETWORK_RETRY_WAIT
        fi
        
        # Tambahkan jumlah percobaan
        attempt=$((attempt + 1))
    done
    
    if [ $connected -eq 0 ]; then
        # Bersihkan baris attempt di konsol
        printf "\r"
        
        # Log dengan format baru untuk kegagalan
        log_message "Failed to connect after $NETWORK_MAX_ATTEMPTS attempts"
        return 1
    fi
    
    return 0
}

# Fungsi helper untuk mendapatkan SHA-1 dari file lokal
get_local_sha1() {
    local file="$1"
    if [ -f "$file" ]; then
        sha1sum "$file" | awk '{print $1}'
    else
        echo ""
    fi
}

# Fungsi helper untuk download dan mendapatkan SHA-1
download_and_get_sha1() {
    local source_url="$1"
    local temp_file_prefix="${2:-temp_sha1_file}"
    
    if [ -z "$source_url" ]; then
        log_message "Error: URL sumber tidak boleh kosong"
        return 1
    fi
    
    # Pastikan temp directory ada
    if [ ! -d "$TEMP_DIR" ]; then
        mkdir -p "$TEMP_DIR" 2>/dev/null || {
            log_message "Warning: Tidak dapat membuat direktori temp, menggunakan /tmp"
            TEMP_DIR="/tmp"
        }
    fi
    
    # Buat temporary file
    local temp_hash_file="$TEMP_DIR/${temp_file_prefix}"
    
    # Download file dari URL
    if curl_download_file "$source_url" "$temp_hash_file"; then
        # Hitung hash SHA-1 dari file yang didownload
        local sha1=$(get_local_sha1 "$temp_hash_file")
        
        rm -f "$temp_hash_file"   # Hapus file sementara
        
        if [ -n "$sha1" ]; then
            echo "$sha1"
            return 0
        else
            log_message "Error: Gagal menghitung SHA-1 dari file yang didownload"
            return 1
        fi
    else
        log_message "Error: Gagal mendownload file dari $source_url"
        return 1
    fi
}

# Fungsi untuk memeriksa dan mengupdate file
check_and_update_file() {
    local file_url="$1"
    local local_file="$2"
    local file_name=$(basename "$local_file")
    
    log_message ""
    log_message "{ $file_name }"
    
    # Download file dan dapatkan SHA-1 dari GitHub
    local github_sha1=$(download_and_get_sha1 "$file_url" "${file_name}.check")
    
    if [ -z "$github_sha1" ]; then
        log_message "Gagal mendapatkan SHA-1 file $file_name dari GitHub"
        return 1
    fi
    
    # Dapatkan hash SHA-1 dari file lokal jika ada
    local local_sha1=""
    if [ -f "$local_file" ]; then
        local_sha1=$(get_local_sha1 "$local_file")
        
        # Bandingkan hash SHA-1
        if [ -n "$local_sha1" ] && [ "$local_sha1" = "$github_sha1" ]; then
            log_message "Local files exist, No updates"
            return 0  # Same, no update needed
        else
            log_message "Local files exist, Update available"
        fi
    else
        log_message "Local file doesn't exist, Download"
    fi
    
    # Pastikan direktori parent ada
    local parent_dir=$(dirname "$local_file")
    if [ ! -d "$parent_dir" ]; then
        mkdir -p "$parent_dir" 2>/dev/null || {
            log_message "Error: Tidak dapat membuat direktori $parent_dir"
            return 1
        }
    fi
    
    # Download file untuk update
    local temp_file="$TEMP_DIR/${file_name}.new"
    if curl_download_file "$file_url" "$temp_file"; then
        # Verifikasi hash SHA-1 file yang didownload
        local downloaded_sha1=$(get_local_sha1 "$temp_file")
        
        if [ "$downloaded_sha1" = "$github_sha1" ]; then
            # Hapus backup lama jika ada
            if [ -f "${local_file}.bak" ]; then
                rm -f "${local_file}.bak"
            fi
            
            # Buat backup file lama jika ada
            if [ -f "$local_file" ]; then
                cp "$local_file" "${local_file}.bak"
            fi
            
            # Pindahkan file baru ke lokasi target
            mv "$temp_file" "$local_file"
            
            # Set executable permission untuk file .sh
            if [ "${file_name##*.}" = "sh" ]; then
                chmod +x "$local_file"
            fi
            
            # Tentukan pesan berdasarkan apakah file sudah ada sebelumnya
            if [ -f "${local_file}.bak" ]; then
                log_message "Successfully updated (SHA1 verified)"
            else
                log_message "Successfully downloaded (SHA1 verified)"
            fi
            
            # Hapus file backup karena pembaruan berhasil
            if [ -f "${local_file}.bak" ]; then
                rm -f "${local_file}.bak"
            fi
            
            return 2  # File updated
        else
            log_message "Error: SHA-1 file yang didownload tidak cocok"
            rm -f "$temp_file"
            return 1
        fi
    else
        log_message "Gagal mendownload $file_name dari $file_url"
        return 1
    fi
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
        log_message "Restart auto-download service"
        
        # Cari script restart-auto-download.sh
        local restart_script="/data/adb/auto-download/restart-auto-download.sh"
        
        # Pastikan restart script dapat dieksekusi jika ada
        if [ -f "$restart_script" ]; then
            chmod +x "$restart_script"
        fi
        
        if [ -x "$restart_script" ]; then
            sh "$restart_script"
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
        # Return 1 untuk memberi tahu auto-download.sh bahwa ada update dan telah di-restart
        # Auto-download.sh yang memanggil script ini harus berhenti
        exit 1
    else
        return 0
    fi
}

# ===== EKSEKUSI UTAMA =====
# File log sudah diinisialisasi oleh auto-download.sh

# Jalankan pemeriksaan dan pembaruan
run_update_check
exit_code=$?

exit $exit_code