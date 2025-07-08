#!/bin/sh

# Script untuk mendownload file konfigurasi secara otomatis

# ===== KONFIGURASI BOOTSTRAP =====
# Parameter minimal yang diperlukan untuk memeriksa pembaruan konfigurasi
# Parameter ini TIDAK BOLEH diubah melalui file konfigurasi eksternal
CONF_UPDATE_URL="https://raw.githubusercontent.com/exball/sing-box-config/refs/heads/test/auto-download/auto-download.conf"
CONFIG_FILE="/data/adb/auto-download/auto-download.conf"
TEMP_DIR="/data/adb/auto-download/download_temp"
NETWORK_TEST_URL="https://www.google.com"
NETWORK_MAX_ATTEMPTS=5
NETWORK_RETRY_WAIT=3
LOG_FILE="/data/adb/auto-download/auto-download.log"

# Pastikan direktori yang diperlukan ada
ensure_directories "/data/adb/auto-download" "$TEMP_DIR"

# File PID untuk melacak proses yang sedang berjalan
PID_FILE="/data/adb/auto-download/auto-download.pid"

# Variabel untuk melacak apakah header timestamp sudah ditulis
TIMESTAMP_HEADER_WRITTEN=0

# Variabel untuk menyimpan interval terakhir
LAST_INTERVAL=0

# Variabel untuk melacak jadwal terakhir yang dijalankan
LAST_EXECUTED_SCHEDULE=""
LAST_SCHEDULE_TIME=0

# Variabel untuk wake-up detection
WAKE_UP_DETECTION_ENABLED=1
LAST_SCREEN_STATE=""
LAST_SCREEN_ON_COUNT=""
WAKE_UP_DETECTED=0

# Variabel untuk wake-up debouncing
WAKE_UP_DEBOUNCE_ENABLED=1
WAKE_UP_DEBOUNCE_INTERVAL=600  # 10 menit = 600 detik
LAST_WAKE_UP_TIME=0
WAKE_UP_DEBOUNCE_FILE="/data/adb/auto-download/last_wake_up_time"

# Fungsi untuk logging
log_message() {
    local message="$1"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    # Echo ke konsol dengan timestamp (hanya jika dijalankan manual)
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

# Fungsi untuk mendapatkan hash SHA-1 dari file lokal
get_local_sha1() {
    local file="$1"
    if [ -f "$file" ]; then
        sha1sum "$file" | awk '{print $1}'
    else
        echo ""
    fi
}

# Fungsi untuk membuat direktori yang diperlukan
ensure_directories() {
    local dirs_to_create="$@"
    
    for dir in "$@"; do
        if [ -n "$dir" ]; then
            mkdir -p "$dir" 2>/dev/null || {
                log_message "Warning: Failed to create directory: $dir"
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

# Fungsi helper untuk operasi curl - pemeriksaan koneksi network
curl_network_check() {
    local test_url="$1"
    local timeout_connect="${2:-5}"
    local timeout_max="${3:-10}"
    
    if [ -z "$test_url" ]; then
        log_message "Error: Test URL cannot be empty"
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
        log_message "Error: Source URL and output file cannot be empty"
        return 1
    fi
    
    # Pastikan direktori output ada
    ensure_parent_directory "$output_file"
    
    # Download file dengan follow redirects
    curl -s -L --connect-timeout "$timeout_connect" --max-time "$timeout_max" "$source_url" -o "$output_file"
    local curl_exit_code=$?
    
    # Jika gagal, hapus file yang mungkin sudah dibuat (partial download)
    if [ $curl_exit_code -ne 0 ]; then
        rm -f "$output_file" 2>/dev/null
    fi
    
    return $curl_exit_code
}

# Fungsi helper untuk download file dan mendapatkan SHA-1 dari GitHub
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
        
        echo "$sha1"   # Kembalikan hash SHA-1
        return 0
    else
        log_message "Failed to download file for hash verification"
        rm -f "$temp_hash_file" 2>/dev/null
        echo ""
        return 1
    fi
}

# Fungsi helper untuk membandingkan SHA-1 GitHub vs lokal
compare_sha1_and_decide() {
    local github_sha1="$1"
    local local_file="$2"
    local file_description="${3:-file}"
    
    if [ -z "$github_sha1" ]; then
        log_message "GitHub SHA-1 is empty for $file_description"
        return 2  # Indicate fallback needed
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
            return 1  # Different, update needed
        fi
    else
        log_message "Local file doesn't exist, Download"
        return 1  # File doesn't exist, download needed
    fi
}

# Fungsi helper untuk verifikasi file yang didownload
verify_downloaded_sha1() {
    local temp_file="$1"
    local expected_sha1="$2"
    local target_file="$3"
    local file_description="${4:-file}"
    local set_executable="${5:-0}"
    
    if [ ! -f "$temp_file" ]; then
        log_message "Error: Temporary file not found"
        return 1
    fi
    
    # Verifikasi hash SHA-1 file yang didownload
    local downloaded_sha1=$(get_local_sha1 "$temp_file")
    
    if [ "$downloaded_sha1" = "$expected_sha1" ]; then
        # Pastikan direktori target ada
        ensure_parent_directory "$target_file"
        
        # Pindahkan file dari temp ke target
        mv "$temp_file" "$target_file"
        
        # Set executable jika diminta
        if [ "$set_executable" -eq 1 ]; then
            chmod +x "$target_file"
        fi
        
        # Tentukan pesan berdasarkan apakah file sudah ada sebelumnya
        if [ -f "$target_file.bak" ] 2>/dev/null || [ -f "$target_file" ]; then
            log_message "Successfully updated (SHA1 verified)"
        else
            log_message "Successfully downloaded (SHA1 verified)"
        fi
        return 0
    else
        log_message "SHA-1 $file_description mismatch, verification failed"
        log_message "Downloaded SHA-1: $downloaded_sha1"
        log_message "Expected SHA-1: $expected_sha1"
        rm -f "$temp_file"
        return 1
    fi
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

# Pastikan direktori yang diperlukan ada
ensure_parent_directory "$LOG_FILE"
ensure_directories "$TEMP_DIR"

# Inisialisasi file log jika belum ada
if [ -n "$LOG_FILE" ] && [ ! -f "$LOG_FILE" ]; then
    touch "$LOG_FILE"
fi

# ===== LOAD KONFIGURASI =====
# Muat konfigurasi dari file
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    log_message "ERROR: Configuration file not found at $CONFIG_FILE"
    log_message "Make sure the configuration file exists before running the script"
    exit 1
fi

# Pastikan variabel wajib ada
if [ -z "$SAVE_DIR" ] || [ -z "$CONFIG_DIR" ] || [ -z "$TEMP_DIR" ] || [ -z "$SCHEDULE_HOURS" ] || [ -z "$CHECK_INTERVAL" ]; then
    log_message "ERROR: Required variables not found in configuration file"
    log_message "Make sure the configuration file contains all required variables"
    exit 1
fi
# =====================

# Fungsi untuk memeriksa dan menyimpan PID
check_and_save_pid() {
    # Periksa PID menggunakan ps dengan lebih akurat
    local CURRENT_PID=$(ps -ef | grep "[a]uto-download.sh" | grep -v auto-download-boot | head -1 | awk '{print $2}')
    
    # Jika PID ditemukan, simpan ke file
    if [ -n "$CURRENT_PID" ] && [ "$CURRENT_PID" -eq "$CURRENT_PID" ] 2>/dev/null; then
        echo "$CURRENT_PID" > "$PID_FILE"
        log_message "Auto-Download PID: $CURRENT_PID"
    else
        log_message "Auto-Download PID: Not found"
    fi
}

# Pastikan semua direktori yang diperlukan ada
ensure_directories "/data/adb/auto-download" "$SAVE_DIR" "$CONFIG_DIR" "$TEMP_DIR"

# Pastikan direktori log ada jika LOG_FILE dikonfigurasi
if [ -n "$LOG_FILE" ]; then
    ensure_parent_directory "$LOG_FILE"
fi

# Fungsi untuk mendapatkan hash SHA-1 dari URL raw GitHub (menggunakan helper baru)
get_github_sha1() {
    local raw_url="$1"
    
    # Gunakan fungsi helper yang sudah distandarisasi
    download_and_get_sha1 "$raw_url" "temp_hash_file"
}

# Fungsi unified untuk update file dengan security-first approach
unified_update_with_security() {
    local source_url="$1"
    local target_file="$2"
    local file_description="${3:-file}"
    local set_executable="${4:-0}"
    local reload_config="${5:-0}"
    
    log_message ""
    log_message "= $file_description ="
    
    # Download SHA-1 dari GitHub untuk verifikasi
    local github_sha1=$(download_and_get_sha1 "$source_url" "${file_description}.sha1")
    
    # Security check: Skip jika gagal mendapat SHA-1 dari GitHub
    if [ -z "$github_sha1" ]; then
        log_message "WARNING: Failed to get SHA-1 from source"
        log_message "File skipped for security (no integrity verification)"
        return 3
    fi
    
    # Gunakan helper untuk membandingkan SHA-1
    compare_sha1_and_decide "$github_sha1" "$target_file" "$file_description"
    local compare_result=$?
    
    case $compare_result in
        0)  return 0
            ;;
        2)  log_message "ERROR: SHA-1 is empty after successful download"
            return 3
            ;;
        1)  # Download file ke temporary directory (security: tidak langsung overwrite)
            local temp_file="$TEMP_DIR/${file_description}.new"
            if curl_download_file "$source_url" "$temp_file"; then

                ensure_parent_directory "$target_file"
                
                # Verifikasi SHA-1 sebelum replace (security-first)
                if verify_downloaded_sha1 "$temp_file" "$github_sha1" "$target_file" "$file_description" "$set_executable"; then

                    if [ "$reload_config" = "1" ]; then
                        if [ -f "$target_file" ]; then
                            source "$target_file"
                            log_message "Config reloaded. Using new configuration"
                        fi
                    fi
                    return 1  
                else
                    log_message "SECURITY: SHA-1 mismatch, file rejected"
                    return 3  
                fi
            else
                log_message "Failed to download from source"
                return 3  
            fi
            ;;
    esac
}

# Konfigurasi file yang perlu diupdate
# Format: URL|FILE_PATH|DESCRIPTION|SET_EXECUTABLE|RELOAD_CONFIG|SKIP_CONFIG_CHECK|EXECUTE_AFTER
FILES_CONFIG="
$CONF_UPDATE_URL|$CONFIG_FILE|auto-download.conf|0|1|0|0
$RESTART_SCRIPT_URL|$RESTART_SCRIPT_FILE|restart-auto-download.sh|1|0|0|0
$BOOT_SCRIPT_URL|$BOOT_SCRIPT_FILE|auto-download-boot.sh|1|0|0|0
$CHECK_UPDATE_SCRIPT_URL|$CHECK_UPDATE_SCRIPT_FILE|check-update.sh|1|0|0|1
"

# Fungsi untuk memproses satu file update
process_file_update() {
    local url="$1"
    local file_path="$2"
    local description="$3"
    local set_executable="$4"
    local reload_config="$5"
    local skip_config_check="$6"
    local execute_after="$7"
    
    # Skip jika baris kosong
    [ -z "$url" ] && return 0
    
    # Cek konfigurasi jika diperlukan
    if [ "$skip_config_check" -eq 0 ]; then
        if [ -z "$url" ] || [ -z "$file_path" ]; then
            log_message "$description URL or file path not configured, skipping check"
            return 2
        fi
    fi
    
    # Update file menggunakan unified function
    unified_update_with_security "$url" "$file_path" "$description" "$set_executable" "$reload_config"
    local update_result=$?
    
    # Handle update result
    case $update_result in
        1) return 1 ;;  # File updated
        3) return 3 ;;  # SHA-1 verification failed
        *) return 0 ;;  # No update needed
    esac
}

# Fungsi untuk mengeksekusi check-update.sh setelah update
execute_check_update_script() {
    local script_file="$1"
    
    if [ -x "$script_file" ]; then
        log_message ""
        log_message "!! Run check-update.sh !!"
        sh "$script_file"
        local exec_result=$?
        
        case $exec_result in
            0) # No additional message needed, check-update.sh already logged the result
               ;;
            1) log_message "check-update.sh detected an update and has restarted"
               return 1 ;;
            *) log_message "check-update.sh returned error code $exec_result"
               return $exec_result ;;
        esac
    else
        log_message "WARNING: check-update.sh is not executable"
    fi
    
    return 0
}

# Fungsi untuk memproses semua file menggunakan array konfigurasi
process_all_files() {
    local files_updated=0
    local temp_file="/data/adb/auto-download/files_config.$$"
    
    # Setup trap untuk cleanup otomatis jika script dihentikan
    trap "rm -f '$temp_file'" EXIT INT TERM
    
    # Write config to temp file untuk avoid subshell issues
    printf "%s\n" "$FILES_CONFIG" > "$temp_file"
    
    # Process each line
    while IFS='|' read -r url file_path description set_exec reload_conf skip_check execute_after; do
        # Skip empty lines dan comments
        case "$url" in
            ''|'#'*) continue ;;
        esac
        
        # Call processing function
        process_file_update "$url" "$file_path" "$description" "$set_exec" "$reload_conf" "$skip_check" "$execute_after"
        local result=$?
        
        # Handle results
        case $result in
            1) files_updated=1 ;;
            2) log_message "WARNING: $description skipped due to configuration"
               continue ;;
            3) log_message "WARNING: $description skipped due to SHA-1 verification failure" ;;
        esac
        
        # Special handling untuk check-update.sh
        if [ "$execute_after" -eq 1 ] && [ $result -ne 3 ]; then
            execute_check_update_script "$file_path"
            local exec_result=$?
            if [ $exec_result -eq 1 ]; then
                rm -f "$temp_file"
                return 1  # Restart detected
            elif [ $exec_result -gt 1 ]; then
                rm -f "$temp_file"
                return $exec_result  # Error
            fi
        fi
        
    done < "$temp_file"
    
    # Cleanup
    rm -f "$temp_file"
    
    # Reset trap
    trap - EXIT INT TERM
    
    # Return files_updated status (0 = no updates, 1 = files updated)
    if [ $files_updated -eq 1 ]; then
        return 1
    else
        return 0
    fi
}

# Fungsi untuk membersihkan file temporary yang tertinggal
cleanup_temp_files() {
    local temp_dir="/data/adb/auto-download"
    if [ -d "$temp_dir" ]; then
        # Hapus file files_config.* yang mungkin tertinggal
        find "$temp_dir" -name "files_config.*" -type f -mmin +10 -delete 2>/dev/null
        log_message "Cleanup completed: removed old temporary files"
    fi
}

# Fungsi untuk mendownload file
download_files() {

    check_network_connection
    if [ $? -ne 0 ]; then
        log_message "File checking process cancelled due to no internet connection"
        return 1
    fi
    
    log_message "------------------------------"
    log_message ""
    log_message "## Checking main script ##"
    
    # Variabel untuk melacak apakah ada file yang diperbarui
    local files_updated=0
    
    # Proses semua file menggunakan array konfigurasi
    process_all_files
    local process_result=$?
    
    case $process_result in
        0)  # No files updated
            ;;
        1)  # Files updated (normal case)
            files_updated=1
            ;;
        *)  # Error occurred or restart detected
            return $process_result
            ;;
    esac
    
    # Loop melalui setiap URL dalam daftar dan download
    if [ -n "${PROVIDER_URLS}" ]; then
        log_message "------------------------------"
        log_message ""
        log_message "## Checking file provider ##"
        
        for url in $PROVIDER_URLS; do

            filename=$(basename "$url" | sed 's/%20/ /g')
            temp_file="$TEMP_DIR/$filename"
            target_file="$SAVE_DIR/$filename"

            local set_executable=0
            if [ "${filename##*.}" = "sh" ]; then
                set_executable=1
            fi
            unified_update_with_security "$url" "$target_file" "$filename" "$set_executable" 0
            local download_result=$?
            
            case $download_result in
                0)  continue
                    ;;
                1)  files_updated=1
                    continue
                    ;;
                3)  log_message "File $filename skipped due to SHA-1 verification failure"
                    continue
                    ;;
            esac
        done
    else
        log_message "PROVIDER_URLS not configured or empty"
    fi
    
    # Periksa koneksi jaringan sebelum memproses config.json
    log_message "------------------------------"
    log_message ""
    check_network_connection
    if [ $? -ne 0 ]; then
        log_message "config.json checking process cancelled due to no internet connection"
        return 1
    fi
    
    # Gunakan unified function untuk download config.json dengan SHA-1 check (selalu aktif)
    unified_update_with_security "$CONFIG_URL" "$CONFIG_DIR/config.json" "config.json" 0 0
    local config_result=$?
    
    case $config_result in
        1)  files_updated=1
            ;;
        3)  log_message "WARNING: config.json skipped due to SHA-1 verification failure"
            ;;
    esac
    
    # Jika ada file yang diperbarui, restart layanan box
    if [ $files_updated -eq 1 ]; then
        log_message "------------------------------"
        log_message ""
        
        # Deteksi PID lama dari /data/adb/box/run/box.pid
        local BOX_PID=""
        if [ -f "/data/adb/box/run/box.pid" ]; then
            BOX_PID=$(cat "/data/adb/box/run/box.pid")
            log_message "There is an updated file"
            log_message "Restart Sing-Box (old PID: $BOX_PID)"
        else
            log_message "There is an updated file"
            log_message "Restart Sing-Box (old PID: not found)"
        fi
        
        # Stop layanan sing-box dengan disable iptables dan stop service
        /data/adb/box/scripts/box.iptables disable && /data/adb/box/scripts/box.service stop
        
        # Kill PID jika masih ada
        if [ -n "$BOX_PID" ] && kill -0 "$BOX_PID" 2>/dev/null; then
            log_message "Stopping process with PID: $BOX_PID"
            kill "$BOX_PID" 2>/dev/null
        fi
        
        sleep 2
        
        # Mulai kembali layanan sing-box dengan start service dan enable iptables
        /data/adb/box/scripts/box.service start && /data/adb/box/scripts/box.iptables enable
        
        # Deteksi PID baru dari /data/adb/box/run/box.pid
        if [ -f "/data/adb/box/run/box.pid" ]; then
            NEW_PID=$(cat "/data/adb/box/run/box.pid")
            log_message "Sing-Box successfully restarted (new PID: $NEW_PID)"
        else
            log_message "WARNING: PID file not found after restart"
        fi
    fi
    
    log_message "Update check process complete"
    
    check_and_save_pid
}

# Fungsi untuk menyimpan timestamp wake-up terakhir
save_wake_up_time() {
    local current_time=$(date +%s)
    echo "$current_time" > "$WAKE_UP_DEBOUNCE_FILE" 2>/dev/null
    LAST_WAKE_UP_TIME=$current_time
}

# Fungsi untuk membaca timestamp wake-up terakhir
load_wake_up_time() {
    if [ -f "$WAKE_UP_DEBOUNCE_FILE" ]; then
        LAST_WAKE_UP_TIME=$(cat "$WAKE_UP_DEBOUNCE_FILE" 2>/dev/null || echo "0")
    else
        LAST_WAKE_UP_TIME=0
    fi
}

# Fungsi untuk memeriksa apakah wake-up diizinkan (debouncing)
is_wake_up_allowed() {
    if [ $WAKE_UP_DEBOUNCE_ENABLED -eq 0 ]; then
        return 0  # Debouncing disabled, allow wake-up
    fi
    
    local current_time=$(date +%s)
    local time_diff=$((current_time - LAST_WAKE_UP_TIME))
    
    if [ $time_diff -ge $WAKE_UP_DEBOUNCE_INTERVAL ]; then
        return 0  # Enough time has passed, allow wake-up
    else
        local remaining_time=$((WAKE_UP_DEBOUNCE_INTERVAL - time_diff))
        local remaining_minutes=$((remaining_time / 60))
        local remaining_seconds=$((remaining_time % 60))
        
        return 1  # Too soon, deny wake-up
    fi
}

# Fungsi untuk format waktu yang mudah dibaca
format_time_diff() {
    local seconds="$1"
    local minutes=$((seconds / 60))
    local hours=$((minutes / 60))
    local days=$((hours / 24))
    
    # Correct calculation for display
    minutes=$((minutes % 60))
    hours=$((hours % 24))
    seconds=$((seconds % 60))
    
    if [ $days -gt 0 ]; then
        echo "${days}d ${hours}h ${minutes}m ${seconds}s"
    elif [ $hours -gt 0 ]; then
        echo "${hours}h ${minutes}m ${seconds}s"
    elif [ $minutes -gt 0 ]; then
        echo "${minutes}m ${seconds}s"
    else
        echo "${seconds}s"
    fi
}

# Fungsi untuk mendeteksi wake-up dari deep sleep
detect_wake_up_event() {
    if [ $WAKE_UP_DETECTION_ENABLED -eq 0 ]; then
        return 0
    fi
    
    local wake_up_detected=0
    
    # Primary detection: Monitor broadcast intents SCREEN_ON
    local current_screen_on_count=$(dumpsys activity broadcasts 2>/dev/null | grep -c "android.intent.action.SCREEN_ON" 2>/dev/null || echo "0")
    
    # Secondary detection: Monitor system properties debug.tracing.screen_state
    local current_screen_state=$(getprop debug.tracing.screen_state 2>/dev/null)
    
    # Jika ini adalah pemeriksaan pertama, simpan state awal
    if [ -z "$LAST_SCREEN_STATE" ]; then
        LAST_SCREEN_STATE="$current_screen_state"
        LAST_SCREEN_ON_COUNT="$current_screen_on_count"
        return 0
    fi
    
    # Primary detection: Periksa apakah ada SCREEN_ON broadcast baru
    if [ -n "$LAST_SCREEN_ON_COUNT" ] && [ "$current_screen_on_count" -gt "$LAST_SCREEN_ON_COUNT" ]; then
        wake_up_detected=1
    fi
    
    # Secondary detection: Deteksi perubahan screen state
    # Berdasarkan testing pada device: 1=OFF, 2=ON
    local screen_was_off=0
    local screen_is_on=0
    
    # Deteksi screen off state (pada device ini = 1)
    if [ "$LAST_SCREEN_STATE" = "1" ]; then
        screen_was_off=1
    fi
    
    # Deteksi screen on state (pada device ini = 2)
    if [ "$current_screen_state" = "2" ]; then
        screen_is_on=1
    fi
    
    # Jika screen berubah dari off (1) ke on (2)
    if [ $screen_was_off -eq 1 ] && [ $screen_is_on -eq 1 ]; then
        wake_up_detected=1
    fi
    
    # Update last states
    LAST_SCREEN_STATE="$current_screen_state"
    LAST_SCREEN_ON_COUNT="$current_screen_on_count"
    
    # Jika wake-up terdeteksi, periksa debouncing
    if [ $wake_up_detected -eq 1 ]; then
        # Periksa apakah wake-up diizinkan (debouncing check)
        if is_wake_up_allowed; then
            WAKE_UP_DETECTED=1
            return 1
        else
            return 0
        fi
    fi
    
    return 0
}

# Fungsi untuk menangani wake-up event
handle_wake_up_event() {
    if [ $WAKE_UP_DETECTED -eq 1 ]; then
        log_message ""
        log_message "= Schedule check wake-up event ="
        
        # Simpan timestamp wake-up untuk debouncing
        save_wake_up_time
        
        # Reset flag wake-up
        WAKE_UP_DETECTED=0
        
        # Jalankan check_schedule_and_run untuk menghitung ulang waktu
        check_schedule_and_run
        
        return 1  # Indicate that wake-up was handled
    fi
    
    return 0
}

# Fungsi untuk memeriksa SCHEDULE_HOURS
check_schedule_and_run() {
    # Dapatkan waktu saat ini dalam format hh:mm dan timestamp Unix
    current_time=$(date +%H:%M)
    current_hour=$(date +%H)
    current_minute=$(date +%M)
    current_timestamp=$(date +%s)
    
    # Periksa apakah waktu saat ini ada dalam jadwal dengan toleransi
    is_scheduled=0
    matched_schedule=""
    
    for schedule_time in $SCHEDULE_HOURS; do
        # Ekstrak jam dan menit dari jadwal
        schedule_hour=$(echo $schedule_time | cut -d: -f1)
        schedule_minute=$(echo $schedule_time | cut -d: -f2)
        
        # Konversi ke menit sejak tengah malam untuk perbandingan
        current_minutes=$((current_hour * 60 + current_minute))
        schedule_minutes=$((schedule_hour * 60 + schedule_minute))
        
        # Hitung selisih waktu dalam menit (nilai absolut)
        diff_minutes=$((current_minutes - schedule_minutes))
        if [ $diff_minutes -lt 0 ]; then
            diff_minutes=$((diff_minutes * -1))
        fi
        
        # Jika selisih kurang dari toleransi, anggap sebagai waktu yang dijadwalkan
        if [ $diff_minutes -le $SCHEDULE_TOLERANCE ]; then
            # Periksa apakah jadwal ini sudah dijalankan dalam waktu dekat
            if [ "$schedule_time" = "$LAST_EXECUTED_SCHEDULE" ]; then
                # Hitung selisih waktu sejak eksekusi terakhir (dalam detik)
                time_since_last_execution=$((current_timestamp - LAST_SCHEDULE_TIME))
                
                # Jika jadwal ini sudah dijalankan dalam 2 * SCHEDULE_TOLERANCE menit terakhir, lewati
                if [ $time_since_last_execution -lt $((2 * SCHEDULE_TOLERANCE * 60)) ]; then
                    continue
                fi
            fi
            
            is_scheduled=1
            matched_schedule=$schedule_time
            log_message "Current time ($current_time) is within $SCHEDULE_TOLERANCE minutes of schedule ($schedule_time)"
            break
        fi
    done
    
    if [ $is_scheduled -eq 1 ]; then
        # Rotasi file log hanya jika ini adalah waktu yang dijadwalkan
        if [ -n "$LOG_FILE" ]; then
            # Jika file log lama sudah ada, hapus terlebih dahulu
            if [ -f "$OLD_LOG_FILE" ]; then
                rm -f "$OLD_LOG_FILE"
                log_message "Old log file deleted"
            fi
            
            # Jika file log saat ini ada, pindahkan ke file log lama
            if [ -f "$LOG_FILE" ]; then
                mv "$LOG_FILE" "$OLD_LOG_FILE"
            fi
            
            # Buat file log baru (kosong)
            touch "$LOG_FILE"
            
            # Reset variabel timestamp header
            TIMESTAMP_HEADER_WRITTEN=0
            
            log_message "Log rotation complete..."
        fi
        # Jalankan download
        download_files
        
        # Perbarui variabel jadwal terakhir yang dijalankan
        LAST_EXECUTED_SCHEDULE=$matched_schedule
        LAST_SCHEDULE_TIME=$current_timestamp
    else
        # Pesan "Bukan waktu yang dijadwalkan" ditampilkan setelah informasi jadwal berikutnya
        log_message "Not an update check schedule"
    fi
}

# Fungsi helper untuk mencari jadwal berikutnya (logika core yang digabung)
find_next_schedule() {
    # Dapatkan waktu saat ini dalam detik sejak tengah malam
    local current_seconds=$(($(date +%H) * 3600 + $(date +%M) * 60 + $(date +%S)))
    
    # Inisialisasi waktu ke jadwal berikutnya
    local next_schedule_seconds=86400  # Default ke 24 jam (tidak ada jadwal dalam 24 jam)
    local next_schedule_time=""
    
    # Periksa semua jadwal untuk menemukan yang terdekat
    for schedule_time in $SCHEDULE_HOURS; do
        # Konversi jadwal ke detik sejak tengah malam
        local hour=$(echo $schedule_time | cut -d: -f1)
        local minute=$(echo $schedule_time | cut -d: -f2)
        local schedule_seconds=$((hour * 3600 + minute * 60))
        
        # Hitung selisih waktu (dalam detik)
        if [ $schedule_seconds -gt $current_seconds ]; then
            # Jadwal hari ini yang belum lewat
            local diff_seconds=$((schedule_seconds - current_seconds))
            if [ $diff_seconds -lt $next_schedule_seconds ]; then
                next_schedule_seconds=$diff_seconds
                next_schedule_time=$schedule_time
            fi
        fi
    done
    
    # Jika tidak ada jadwal yang ditemukan untuk hari ini, cari jadwal pertama untuk besok
    if [ $next_schedule_seconds -eq 86400 ]; then
        for schedule_time in $SCHEDULE_HOURS; do
            local hour=$(echo $schedule_time | cut -d: -f1)
            local minute=$(echo $schedule_time | cut -d: -f2)
            local schedule_seconds=$((hour * 3600 + minute * 60))
            
            # Jadwal untuk besok = jadwal + (24 jam - waktu saat ini)
            local diff_seconds=$((schedule_seconds + 86400 - current_seconds))
            if [ $diff_seconds -lt $next_schedule_seconds ]; then
                next_schedule_seconds=$diff_seconds
                next_schedule_time=$schedule_time
            fi
        done
    fi
    # Return dalam format "seconds:time"
    echo "$next_schedule_seconds:$next_schedule_time"
}

# Fungsi untuk mendapatkan informasi jadwal berikutnya
get_next_schedule_info() {
    # Gunakan fungsi helper untuk mendapatkan data jadwal berikutnya
    local schedule_result=$(find_next_schedule)
    local next_schedule_seconds=$(echo "$schedule_result" | cut -d: -f1)
    local next_schedule_time=$(echo "$schedule_result" | cut -d: -f2-)
    
    # Konversi detik ke format jam dan menit untuk tampilan yang lebih mudah dibaca
    local next_hours=$((next_schedule_seconds / 3600))
    local next_minutes=$(((next_schedule_seconds % 3600) / 60))
    
    # Kembalikan informasi jadwal berikutnya
    echo "Next schedule: $next_schedule_time (in $next_hours hours $next_minutes minutes)"
}

# Fungsi helper untuk menghitung waktu pemeriksaan berikutnya
calculate_next_check_time() {
    local interval_seconds=$1
    local current_timestamp=$(date +%s)
    local next_timestamp=$((current_timestamp + interval_seconds))
    local next_time=$(date -d "@$next_timestamp" +"%H:%M")
    
    echo "$next_time"
}

# Fungsi untuk menghitung interval adaptif berdasarkan waktu ke jadwal berikutnya
calculate_adaptive_interval() {
    # Gunakan fungsi helper untuk mendapatkan data jadwal berikutnya
    local schedule_result=$(find_next_schedule)
    local next_schedule_seconds=$(echo "$schedule_result" | cut -d: -f1)
    
    # Daftar interval adaptif yang tersedia (dalam detik)
    local intervals_list="7200 3600 3300 3000 2700 2400 2100 1800 1500 1200 900 600 300 60"
    
    local adaptive_interval=$CHECK_INTERVAL  # Default ke interval yang dikonfigurasi
    
    # Jika waktu ke jadwal berikutnya kurang dari interval default
    if [ $next_schedule_seconds -lt $CHECK_INTERVAL ]; then
        # Jika waktu ke jadwal berikutnya sangat dekat (kurang dari 2 menit), gunakan 60 detik
        if [ $next_schedule_seconds -le 120 ]; then
            adaptive_interval=60
        else
            # Kurangi waktu ke jadwal berikutnya dengan margin keamanan tetap (60 detik)
            local safe_schedule_seconds=$((next_schedule_seconds - 60))
            
            # Jika waktu yang tersisa masih positif, gunakan untuk menentukan interval
            if [ $safe_schedule_seconds -gt 0 ]; then
                # Cari interval terbesar yang tidak melebihi waktu yang sudah dikurangi margin keamanan
                for interval in $intervals_list; do
                    if [ $interval -le $safe_schedule_seconds ]; then
                        adaptive_interval=$interval
                        break
                    fi
                done
            else
                # Jika waktu yang tersisa negatif atau nol, gunakan interval terkecil (60 detik)
                adaptive_interval=60
            fi
            
            # Jika tidak ada interval yang cocok, gunakan 60 detik
            if [ $adaptive_interval -eq $CHECK_INTERVAL ] && [ $safe_schedule_seconds -lt 60 ]; then
                adaptive_interval=60
            fi
        fi
    fi
    # Kembalikan interval adaptif
    echo $adaptive_interval
}

# Fungsi untuk menjalankan script sebagai daemon (background)
run_as_daemon() {
    # Rotasi file log jika dikonfigurasi (untuk semua mode termasuk restart)
    if [ -n "$LOG_FILE" ]; then
        # Jika file log lama sudah ada, hapus terlebih dahulu
        if [ -f "$OLD_LOG_FILE" ]; then
            rm -f "$OLD_LOG_FILE"
        fi
        
        # Jika file log saat ini ada, pindahkan ke file log lama
        if [ -f "$LOG_FILE" ]; then
            mv "$LOG_FILE" "$OLD_LOG_FILE"
        fi
        
        # Buat file log baru (kosong)
        touch "$LOG_FILE"
        
        # Reset variabel timestamp header
        TIMESTAMP_HEADER_WRITTEN=0
        
        if [ $RESTART_MODE -eq 1 ]; then
            log_message "Log rotation complete (restart mode)"
        else
            log_message "Log rotation complete"
        fi
    fi
    
    # Periksa dan simpan PID
    check_and_save_pid
    
    # Bersihkan file temporary yang mungkin tertinggal
    cleanup_temp_files
    
    download_files
    
    # Reset variabel untuk melacak interval dan jadwal terakhir
    LAST_INTERVAL=0
    LAST_EXECUTED_SCHEDULE=""
    LAST_SCHEDULE_TIME=0
    
    # Inisialisasi wake-up detection
    if [ $WAKE_UP_DETECTION_ENABLED -eq 1 ]; then
        LAST_SCREEN_STATE=$(getprop debug.tracing.screen_state 2>/dev/null)
        LAST_SCREEN_ON_COUNT=$(dumpsys activity broadcasts 2>/dev/null | grep -c "android.intent.action.SCREEN_ON" 2>/dev/null || echo "0")
        WAKE_UP_DETECTED=0
    fi
    
    # Inisialisasi wake-up debouncing
    if [ $WAKE_UP_DEBOUNCE_ENABLED -eq 1 ]; then
        load_wake_up_time
    fi
    
    # Inisialisasi untuk loop pertama
    adaptive_interval=$(calculate_adaptive_interval)
    next_schedule_info=$(get_next_schedule_info)
    
    # Kemudian jalankan loop untuk memeriksa jadwal sesuai interval yang dikonfigurasi
    log_message "-------------------------------------"
    log_message ""
    log_message "Starts a schedule check loop"
    current_hour=$(date +"%H:%M")
    next_schedule_time=$(echo "$next_schedule_info" | grep -o "[0-9][0-9]:[0-9][0-9]")
    next_schedule_diff=$(echo "$next_schedule_info" | grep -o "in [0-9]* hours [0-9]* minutes" | sed 's/in //')
    
    # Log interval yang dipilih untuk loop pertama
    log_message "Next update check: $next_schedule_time"
    log_message "Current time: $current_hour"
    
    # Hitung waktu pemeriksaan pertama (current_hour + adaptive_interval)
    first_check_info=$(calculate_next_check_time $adaptive_interval)
    log_message "First schedule check: $first_check_info (Interval: $adaptive_interval)"
    
    # Loop utama
    while true; do
        
        # Tunggu sesuai interval adaptif dengan wake-up detection
        local sleep_interval=$adaptive_interval
        local sleep_counter=0
        local check_interval=10  # Check wake-up every 10 seconds
        
        # Sleep dengan pemeriksaan wake-up berkala
        while [ $sleep_counter -lt $sleep_interval ]; do
            local remaining_sleep=$((sleep_interval - sleep_counter))
            local current_sleep=$check_interval
            
            if [ $remaining_sleep -lt $check_interval ]; then
                current_sleep=$remaining_sleep
            fi
            
            sleep $current_sleep
            sleep_counter=$((sleep_counter + current_sleep))
            
            # Periksa wake-up event selama sleep
            detect_wake_up_event
            if [ $? -eq 1 ]; then
                # Wake-up detected, break from sleep loop
                break
            fi
        done
        
        # Handle wake-up event jika terdeteksi
        handle_wake_up_event
        local wake_up_handled=$?
        
        # Jika wake-up tidak ditangani, lakukan schedule check normal
        if [ $wake_up_handled -eq 0 ]; then
            log_message ""
            log_message "= Schedule check ="
            
            # Jalankan pemeriksaan jadwal
            check_schedule_and_run
        fi
        
        # Hitung interval adaptif untuk siklus berikutnya
        next_adaptive_interval=$(calculate_adaptive_interval)
        
        # Dapatkan waktu ke jadwal berikutnya untuk log
        next_schedule_info=$(get_next_schedule_info)
        
        # Ekstrak informasi jadwal untuk format log yang lebih ringkas
        current_hour=$(date +"%H:%M")
        next_schedule_time=$(echo "$next_schedule_info" | grep -o "[0-9][0-9]:[0-9][0-9]")
        next_schedule_diff=$(echo "$next_schedule_info" | grep -o "in [0-9]* hours [0-9]* minutes" | sed 's/in //')
        
        log_message "Current time: $current_hour" 
        
        # Hitung waktu pemeriksaan berikutnya (current_hour + next_adaptive_interval)
        next_check_info=$(calculate_next_check_time $next_adaptive_interval)
        log_message "Next schedule check: $next_check_info (Interval: $next_adaptive_interval)"
        
        # Simpan interval saat ini untuk perbandingan berikutnya
        LAST_INTERVAL=$next_adaptive_interval
        
        # Gunakan interval yang baru dihitung untuk siklus berikutnya
        adaptive_interval=$next_adaptive_interval
    done
}

# Deteksi dijalankan oleh restart atau saat boot
RESTART_FLAG_FILE="/data/adb/auto-download/restart_flag"
RESTART_MODE=0
BOOT_MODE=0

# Periksa apakah file penanda restart ada dan baru dibuat
if [ -f "$RESTART_FLAG_FILE" ]; then
    FLAG_TIME=$(cat "$RESTART_FLAG_FILE")
    CURRENT_TIME=$(date +%s)
    TIME_DIFF=$((CURRENT_TIME - FLAG_TIME))
    
    # Jika file penanda dibuat dalam 10 detik terakhir, anggap dijalankan oleh restart
    if [ $TIME_DIFF -le 10 ]; then
        RESTART_MODE=1

        rm -f "$RESTART_FLAG_FILE"
    fi
fi

# Periksa apakah dijalankan saat boot
if [ "$(dirname "$0")" = "/data/adb/service.d" ] || [ -f "/data/adb/auto-download/boot.log" ]; then
    BOOT_MODE=1
fi

if [ $RESTART_MODE -eq 1 ]; then
    run_as_daemon > /dev/null 2>&1 &
    exit 0
fi

# Jika dijalankan saat boot
if [ $BOOT_MODE -eq 1 ]; then
    log_message "Script running at boot, waiting $BOOT_WAIT_TIME seconds"
    sleep $BOOT_WAIT_TIME
else
    log_message "Script running manually"
fi

# Selalu jalankan sebagai daemon untuk mode boot dan manual
log_message "Running in daemon mode"
run_as_daemon > /dev/null 2>&1 &

