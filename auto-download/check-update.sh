#!/bin/sh

# Script untuk memeriksa dan mengupdate file auto-download.sh
# Script ini akan memeriksa hash SHA-1 dari file tersebut dan mengunduhnya jika berbeda

# ===== KONFIGURASI DASAR =====
# URL untuk file yang akan diperiksa
SCRIPT_UPDATE_URL="https://raw.githubusercontent.com/exball/sing-box-config/Master/auto-download/auto-download.sh"

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

# ===== FUNGSI UTILITAS =====
# Fungsi untuk membuat direktori yang diperlukan
ensure_directories() {
    local dirs_to_create="$@"
    
    for dir in "$@"; do
        if [ -n "$dir" ]; then
            mkdir -p "$dir" 2>/dev/null || {
                log_message "⚠️ Failed to create directory: $dir"
            }
        fi
    done
}

# Fungsi untuk membuat direktori dari path file
ensure_parent_directory() {
    local file_path="$1"
    if [ -n "$file_path" ]; then
        local parent_dir=$(dirname "$file_path")
        ensure_directories "$parent_dir"
    fi
}

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

# ===== CURL RESOLUTION =====
# Pilih binary curl: prefer PATH/system, fallback ke Termux
CURL_BIN="${CURL_BIN:-}"
if [ -z "$CURL_BIN" ]; then
    for candidate in \
        "$(command -v curl 2>/dev/null)" \
        /system/bin/curl \
        /system/xbin/curl \
        /vendor/bin/curl \
        /data/data/com.termux/files/usr/bin/curl; do
        if [ -n "$candidate" ] && [ -x "$candidate" ]; then
            CURL_BIN="$candidate"
            break
        fi
    done
fi

if [ -z "$CURL_BIN" ] || [ ! -x "$CURL_BIN" ]; then
    log_message "ERROR: curl binary not found. Please install curl (system or Termux)."
    exit 1
fi

log_message "Using curl: $CURL_BIN"

# Fungsi get_local_sha1 sudah didefinisikan di auto-download.sh
# (dipanggil melalui source auto-download.sh)

# Fungsi helper untuk operasi curl - pemeriksaan koneksi network
curl_network_check() {
    local test_url="$1"
    local timeout_connect="${2:-5}"
    local timeout_max="${3:-10}"
    
    if [ -z "$test_url" ]; then
        log_message "Error: Test URL cannot be empty"
        return 1
    fi
    
    "$CURL_BIN" -s -f -m "$timeout_max" --connect-timeout "$timeout_connect" -o /dev/null "$test_url"
    return $?
}

# Fungsi helper untuk operasi curl - download file
curl_download_file() {
    local source_url="$1"
    local output_file="$2"
    local timeout_connect="${3:-10}"
    local timeout_max="${4:-30}"
    
    if [ -z "$source_url" ] || [ -z "$output_file" ]; then
        log_message "Error: Source URL and output file cannot be empty"
        return 1
    fi
    
    # Pastikan direktori output ada
    ensure_parent_directory "$output_file"
    
    # Tentukan apakah repo private atau public
    local send_auth=0
    if echo "$source_url" | grep -q "api.github.com"; then
        send_auth=1
    elif [ -n "$GITHUB_HEADER" ]; then
        # Cek apakah repo private dengan mencoba akses tanpa header
        local test_file="$TEMP_DIR/test_public_access.$$"
        "$CURL_BIN" -s -L --connect-timeout "$timeout_connect" --max-time "$timeout_max" \
            "$source_url" -o "$test_file"
        local curl_test_code=$?
        local test_content=""
        if [ -f "$test_file" ]; then
            test_content=$(head -c 20 "$test_file")
            rm -f "$test_file"
        fi
        if [ $curl_test_code -ne 0 ] || echo "$test_content" | grep -qi "not found"; then
            send_auth=1
        fi
    fi
    
    # Download file dengan atau tanpa header Authorization
    if [ $send_auth -eq 1 ] && [ -n "$GITHUB_HEADER" ]; then
        "$CURL_BIN" -s -L --connect-timeout "$timeout_connect" --max-time "$timeout_max" \
            -H "$GITHUB_HEADER" "$source_url" -o "$output_file"
    else
        "$CURL_BIN" -s -L --connect-timeout "$timeout_connect" --max-time "$timeout_max" \
            "$source_url" -o "$output_file"
    fi
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
        log_message "Error: Source URL cannot be empty"
        return 1
    fi
    
    # Buat direktori temp jika belum ada
    ensure_directories "$TEMP_DIR"
    
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
            log_message "Error: Failed to calculate SHA-1 from downloaded file"
            return 1
        fi
    else
        log_message "Failed to download file for hash verification"
        return 1
    fi
}

# Fungsi untuk memeriksa dan mengupdate file
check_and_update_file() {
    local file_url="$1"
    local local_file="$2"
    local file_name=$(basename "$local_file")
    
    # Download file dan dapatkan SHA-1 dari GitHub
    local github_sha1=$(download_and_get_sha1 "$file_url" "${file_name}.check")
    
    if [ -z "$github_sha1" ]; then
        log_message "🔎 $file_name"
        log_message "- Failed to get SHA-1 for $file_name from GitHub"
        return 1
    fi
    
    # Dapatkan hash SHA-1 dari file lokal jika ada
    local local_sha1=""
    local file_existed=0
    if [ -f "$local_file" ]; then
        file_existed=1
        local_sha1=$(get_local_sha1 "$local_file")
        
        # Bandingkan hash SHA-1
        if [ -n "$local_sha1" ] && [ "$local_sha1" = "$github_sha1" ]; then
            log_message "☑️ $file_name = No updates"
            return 0  # Same, no update needed
        fi
    fi
    
    # Jika sampai di sini, berarti perlu update atau download
    log_message "🔎 $file_name"
    
    # Pastikan direktori parent ada
    ensure_parent_directory "$local_file"
    
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
            if [ $file_existed -eq 1 ]; then
                log_message "🔁 Local files exist, Updates available"
                log_message "╰➤ Successfully updated (SHA1 verified)"
            else
                log_message "📥 Local file doesn't exist, Download"
                log_message "╰➤ Successfully download (SHA1 verified)"
            fi
            
            # Hapus file backup karena pembaruan berhasil
            if [ -f "${local_file}.bak" ]; then
                rm -f "${local_file}.bak"
            fi
            
            return 2  # File updated
        else
            log_message "⚠️ SHA-1 mismatch, file rejected"
            log_message "    File $file_name skipped"
            log_message "    Failed to verify SHA-1"
            rm -f "$temp_file"
            return 1
        fi
    else
        log_message "╰➤ Failed to download from source"
        return 1
    fi
}

# ===== PERSIAPAN =====
# Pastikan direktori yang diperlukan ada
ensure_directories "/data/adb/auto-download" "$TEMP_DIR"

# Muat konfigurasi dari file jika ada
CONFIG_FILE="/data/adb/auto-download/auto-download.conf"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    # Gabungkan token dari 6 bagian jika semua variabel ada
    if [ -n "$GI" ] && [ -n "$UB" ] && [ -n "$EN" ] && [ -n "$_T" ] && [ -n "$TH" ] && [ -n "$OK" ]; then
        GITHUB_TOKEN=$(echo -n "$GI$UB$EN$_T$TH$OK" | base64 -d)
    fi
    # Set header Authorization jika token tersedia
    if [ -n "$GITHUB_TOKEN" ]; then
        GITHUB_HEADER="Authorization: token $GITHUB_TOKEN"
    else
        GITHUB_HEADER=""
    fi
fi

# Tidak mengosongkan log file karena melanjutkan dari auto-download.sh
# Log akan ditambahkan setelah log dari auto-download.sh

# Variabel TIMESTAMP_HEADER_WRITTEN tidak diperlukan lagi karena melanjutkan dari auto-download.sh

# ===== FUNGSI UTAMA =====
# Fungsi untuk menjalankan pemeriksaan dan pembaruan
run_update_check() {
    # Periksa koneksi jaringan terlebih dahulu
    check_network_connection
    if [ $? -ne 0 ]; then
        log_message "File check process cancelled due to no internet connection"
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
            log_message "Script restart-auto-download.sh not found or not executable"
            log_message "Trying manual restart..."
            
            # Fallback: restart manual jika restart script tidak tersedia
            if pgrep -f "auto-download.sh" > /dev/null; then
                log_message "Detected auto-download.sh is running, trying to restart..."
                
                # Hentikan proses yang sedang berjalan
                pkill -f "auto-download.sh"
                sleep 2
                
                # Pastikan auto-download.sh dapat dieksekusi
                if [ -f "$SCRIPT_FILE" ]; then
                    chmod +x "$SCRIPT_FILE"
                fi
                
                # Jalankan kembali auto-download.sh
                if [ -x "$SCRIPT_FILE" ]; then
                    log_message "Running auto-download.sh again..."
                    nohup sh "$SCRIPT_FILE" > /dev/null 2>&1 &
                    log_message "auto-download.sh has been restarted with PID: $!"
                else
                    log_message "⚠️: auto-download.sh is not executable"
                fi
            else
                log_message "auto-download.sh is not running, no need to restart"
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