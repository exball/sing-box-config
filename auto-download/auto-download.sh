#!/bin/sh

# Test 
# Script untuk mendownload file konfigurasi secara otomatis
# Dengan fitur pemeriksaan hash SHA-1 untuk menghindari download ulang
# Versi dengan CHECK_INTERVAL adaptif dan pembaruan auto-download.conf

# ===== KONFIGURASI BOOTSTRAP =====
# Parameter minimal yang diperlukan untuk memeriksa pembaruan konfigurasi
# Parameter ini TIDAK BOLEH diubah melalui file konfigurasi eksternal
CONF_UPDATE_URL="https://raw.githubusercontent.com/exball/sing-box-config/refs/heads/Master/auto-download/auto-download.conf"
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
                log_message "Peringatan: Gagal membuat direktori: $dir"
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
        log_message "Error: URL sumber tidak boleh kosong"
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
        log_message "Gagal mendownload file untuk pemeriksaan hash dari: $source_url"
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
        log_message "SHA-1 GitHub kosong untuk $file_description"
        return 2  # Indicate fallback needed
    fi
    
    log_message "SHA-1 GitHub: $github_sha1"
    
    # Dapatkan hash SHA-1 dari file lokal jika ada
    local local_sha1=""
    if [ -f "$local_file" ]; then
        local_sha1=$(get_local_sha1 "$local_file")
        log_message "SHA-1 lokal: $local_sha1"
    fi
    
    # Bandingkan hash SHA-1
    if [ -n "$local_sha1" ] && [ "$local_sha1" = "$github_sha1" ]; then
        log_message "SHA-1 sama, Skip..."
        return 0  # Same, no update needed
    else
        return 1  # Different, update needed
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
        log_message "Error: File temporary tidak ditemukan"
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
        
        log_message "Berhasil memperbarui (SHA-1 terverifikasi)"
        return 0
    else
        log_message "SHA-1 $file_description tidak cocok, gagal verifikasi"
        log_message "SHA-1 didownload: $downloaded_sha1"
        log_message "SHA-1 yang diharapkan: $expected_sha1"
        rm -f "$temp_file"
        return 1
    fi
}

# Fungsi untuk memeriksa koneksi jaringan
check_network_connection() {
    log_message "Memeriksa koneksi internet..."
    
    local attempt=1
    local connected=0
    
    while [ $attempt -le $NETWORK_MAX_ATTEMPTS ]; do
        log_message "Percobaan ke $attempt dari $NETWORK_MAX_ATTEMPTS"
        
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
    log_message "Konfigurasi dimuat dari $CONFIG_FILE"
else
    log_message "KESALAHAN: File konfigurasi tidak ditemukan di $CONFIG_FILE"
    log_message "Pastikan file konfigurasi ada sebelum menjalankan script"
    exit 1
fi

# Pastikan variabel wajib ada
if [ -z "$SAVE_DIR" ] || [ -z "$CONFIG_DIR" ] || [ -z "$TEMP_DIR" ] || [ -z "$SCHEDULE_HOURS" ] || [ -z "$CHECK_INTERVAL" ]; then
    log_message "KESALAHAN: Variabel wajib tidak ditemukan di file konfigurasi"
    log_message "Pastikan file konfigurasi berisi semua variabel yang diperlukan"
    exit 1
fi
# =====================

# Fungsi untuk memeriksa dan menyimpan PID
check_and_save_pid() {
    # Periksa PID menggunakan ps
    local CURRENT_PID=$(ps -ef | grep auto-download.sh | grep -v grep | awk '{print $2}')
    
    # Jika PID ditemukan, simpan ke file
    if [ -n "$CURRENT_PID" ]; then
        echo "$CURRENT_PID" > "$PID_FILE"
        log_message "Auto-Download PID: $CURRENT_PID"
    else
        log_message "Auto-Download PID: Tidak ditemukan"
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
    
    log_message "-----"
    log_message "Memeriksa $file_description..."
    
    # Download SHA-1 dari GitHub untuk verifikasi
    local github_sha1=$(download_and_get_sha1 "$source_url" "${file_description}.sha1")
    
    # Security check: Skip jika gagal mendapat SHA-1 dari GitHub
    if [ -z "$github_sha1" ]; then
        log_message "PERINGATAN: Gagal mendapatkan SHA-1 dari GitHub untuk $file_description"
        log_message "File dilewati untuk keamanan (tidak ada verifikasi integritas)"
        return 3  # Skip file - no fallback for security
    fi
    
    # Gunakan helper untuk membandingkan SHA-1
    compare_sha1_and_decide "$github_sha1" "$target_file" "$file_description"
    local compare_result=$?
    
    case $compare_result in
        0)  # Same SHA-1, skip download
            return 0
            ;;
        2)  # Empty GitHub SHA-1 (should not happen due to check above)
            log_message "ERROR: SHA-1 kosong setelah download berhasil"
            return 3  # Skip for security
            ;;
        1)  # Different SHA-1, download needed
            log_message "SHA-1 berbeda atau file tidak ada, Update..."
            
            # Download file ke temporary directory (security: tidak langsung overwrite)
            local temp_file="$TEMP_DIR/${file_description}.new"
            if curl_download_file "$source_url" "$temp_file"; then
                # Pastikan direktori target ada
                ensure_parent_directory "$target_file"
                
                # Verifikasi SHA-1 sebelum replace (security-first)
                if verify_downloaded_sha1 "$temp_file" "$github_sha1" "$target_file" "$file_description" "$set_executable"; then
                    # Reload konfigurasi jika diperlukan
                    if [ "$reload_config" = "1" ]; then
                        if [ -f "$target_file" ]; then
                            source "$target_file"
                            log_message "Reload config. Menggunakan konfigurasi baru"
                        fi
                    fi
                    return 1  # File updated
                else
                    log_message "KEAMANAN: SHA-1 tidak cocok untuk $file_description, file ditolak"
                    return 3  # Verification failed - security
                fi
            else
                log_message "Gagal mendownload $file_description dari $source_url"
                return 3  # Download failed
            fi
            ;;
    esac
}

# Fungsi untuk memeriksa dan mengupdate file script (menggunakan unified function)
check_update_script() {
    local script_url="$1"
    local script_file="$2"
    local script_name=$(basename "$script_file")
    
    # Gunakan unified function dengan set executable = 1, tanpa reload
    unified_update_with_security "$script_url" "$script_file" "$script_name" 1 0
}

# Fungsi untuk mendownload file
download_files() {
    # Periksa koneksi jaringan terlebih dahulu
    check_network_connection
    if [ $? -ne 0 ]; then
        log_message "Proses pemeriksaan file dibatalkan karena tidak ada koneksi internet"
        return 1
    fi
    
    log_message "Memulai proses pemeriksaan file"
    
    # Variabel untuk melacak apakah ada file yang diperbarui
    local files_updated=0
    
    # Periksa dan update file auto-download.conf terlebih dahulu menggunakan unified function
    unified_update_with_security "$CONF_UPDATE_URL" "$CONFIG_FILE" "auto-download.conf" 0 1
    local config_result=$?
    case $config_result in
        1)  # File updated
            files_updated=1
            ;;
        3)  # Download/verification failed
            log_message "PERINGATAN: auto-download.conf dilewati karena gagal verifikasi SHA-1"
            ;;
        # 0 = no update needed, tidak perlu action
    esac
    
    # Periksa dan update file restart-auto-download.sh setelah auto-download.conf
    if [ -n "$RESTART_SCRIPT_URL" ] && [ -n "$RESTART_SCRIPT_FILE" ]; then
        check_update_script "$RESTART_SCRIPT_URL" "$RESTART_SCRIPT_FILE"
        local restart_script_result=$?
        case $restart_script_result in
            1)  # File updated
                files_updated=1
                ;;
            3)  # Download/verification failed
                log_message "PERINGATAN: restart-auto-download.sh dilewati karena gagal verifikasi SHA-1"
                ;;
            # 0 = no update needed, tidak perlu action
        esac
    else
        log_message "URL atau path file restart-auto-download.sh tidak dikonfigurasi, melewati pemeriksaan"
    fi
    
    # Periksa dan update file check-update.sh setelah restart-auto-download.sh
    if [ -n "$CHECK_UPDATE_SCRIPT_URL" ] && [ -n "$CHECK_UPDATE_SCRIPT_FILE" ]; then
        check_update_script "$CHECK_UPDATE_SCRIPT_URL" "$CHECK_UPDATE_SCRIPT_FILE"
        local check_update_result=$?
        case $check_update_result in
            1)  # File updated
                files_updated=1
                ;;
            3)  # Download/verification failed
                log_message "PERINGATAN: check-update.sh dilewati karena gagal verifikasi SHA-1"
                ;;
            # 0 = no update needed, tidak perlu action
        esac
        
        # Setelah memeriksa check-update.sh, jalankan untuk memeriksa auto-download.sh
        log_message "Run check-update.sh untuk memeriksa auto-download.sh..."
        if [ -x "$CHECK_UPDATE_SCRIPT_FILE" ]; then
            # Jalankan check-update.sh dan tunggu hingga selesai
            sh "$CHECK_UPDATE_SCRIPT_FILE"
            local update_check_result=$?
            
            if [ $update_check_result -eq 0 ]; then
                log_message "Tidak ada pembaruan, melanjutkan proses"

            elif [ $update_check_result -eq 1 ]; then
                log_message "check-update.sh mendeteksi ada update dan telah melakukan restart"
                # Return 1 menandakan auto-download.sh perlu berhenti karena telah di-restart
                return 1
            else
                log_message "check-update.sh mengembalikan kode error $update_check_result"
                # Return error code
                return $update_check_result
            fi
        else
            log_message "PERINGATAN: check-update.sh tidak dapat dieksekusi"
            # Lanjutkan proses meskipun tidak bisa memeriksa update
        fi
    else
        log_message "URL atau path file check-update.sh tidak dikonfigurasi, melewati pemeriksaan"
    fi
    
    # Loop melalui setiap URL dalam daftar dan download
    if [ -n "${PROVIDER_URLS}" ]; then
        for url in $PROVIDER_URLS; do
            # Ekstrak nama file dari URL
            filename=$(basename "$url" | sed 's/%20/ /g')
            temp_file="$TEMP_DIR/$filename"
            target_file="$SAVE_DIR/$filename"
            # Auto-detect executable untuk .sh files
            local set_executable=0
            if [ "${filename##*.}" = "sh" ]; then
                set_executable=1
            fi
            unified_update_with_security "$url" "$target_file" "$filename" "$set_executable" 0
            local download_result=$?
            
            case $download_result in
                0)  # File sama, skip
                    continue
                    ;;
                1)  # File updated
                    files_updated=1
                    continue
                    ;;
                3)  # Download/verification failed, skip
                    log_message "File $filename dilewati karena gagal verifikasi SHA-1"
                    continue
                    ;;
            esac
        done
    else
        log_message "PROVIDER_URLS tidak dikonfigurasi atau kosong"
    fi
    
    # Periksa koneksi jaringan sebelum memproses config.json
    log_message "-----"
    check_network_connection
    if [ $? -ne 0 ]; then
        log_message "Proses pemeriksaan config.json dibatalkan karena tidak ada koneksi internet"
        return 1
    fi
    
    # Gunakan unified function untuk download config.json dengan SHA-1 check (selalu aktif)
    unified_update_with_security "$CONFIG_URL" "$CONFIG_DIR/config.json" "config.json" 0 0
    local config_result=$?
    
    case $config_result in
        1)  # File updated
            files_updated=1
            ;;
        3)  # Download/verification failed
            log_message "PERINGATAN: config.json dilewati karena gagal verifikasi SHA-1"
            ;;
        # 0 = no update needed, tidak perlu action
    esac
    
    # Jika ada file yang diperbarui, restart layanan box
    if [ $files_updated -eq 1 ]; then
        log_message "-----"
        
        # Deteksi PID lama dari /data/adb/box/run/box.pid
        local BOX_PID=""
        if [ -f "/data/adb/box/run/box.pid" ]; then
            BOX_PID=$(cat "/data/adb/box/run/box.pid")
            log_message "Ada file yang diperbarui"
            log_message "Restart Sing-Box (PID lama: $BOX_PID)"
        else
            log_message "Ada file yang diperbarui"
            log_message "Restart Sing-Box (PID lama: tidak ditemukan)"
        fi
        
        # Stop layanan sing-box dengan disable iptables dan stop service
        /data/adb/box/scripts/box.iptables disable && /data/adb/box/scripts/box.service stop
        
        # Kill PID jika masih ada
        if [ -n "$BOX_PID" ] && kill -0 "$BOX_PID" 2>/dev/null; then
            log_message "Menghentikan proses dengan PID: $BOX_PID"
            kill "$BOX_PID" 2>/dev/null
        fi
        
        sleep 2
        
        # Mulai kembali layanan sing-box dengan start service dan enable iptables
        /data/adb/box/scripts/box.service start && /data/adb/box/scripts/box.iptables enable
        
        # Deteksi PID baru dari /data/adb/box/run/box.pid
        if [ -f "/data/adb/box/run/box.pid" ]; then
            NEW_PID=$(cat "/data/adb/box/run/box.pid")
            log_message "Sing-Box berhasil di-restart (PID baru: $NEW_PID)"
        else
            log_message "PERINGATAN: File PID tidak ditemukan setelah restart"
        fi
    fi
    
    log_message "Proses pemeriksaan file selesai"
    
    check_and_save_pid   # Check and save PID
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
            log_message "Waktu saat ini ($current_time) dalam rentang $SCHEDULE_TOLERANCE menit dari jadwal ($schedule_time)"
            break
        fi
    done
    
    if [ $is_scheduled -eq 1 ]; then
        # Rotasi file log hanya jika ini adalah waktu yang dijadwalkan
        if [ -n "$LOG_FILE" ]; then
            # Jika file log lama sudah ada, hapus terlebih dahulu
            if [ -f "$OLD_LOG_FILE" ]; then
                rm -f "$OLD_LOG_FILE"
                log_message "File log lama dihapus"
            fi
            
            # Jika file log saat ini ada, pindahkan ke file log lama
            if [ -f "$LOG_FILE" ]; then
                mv "$LOG_FILE" "$OLD_LOG_FILE"
            fi
            
            # Buat file log baru (kosong)
            touch "$LOG_FILE"
            
            # Reset variabel timestamp header
            TIMESTAMP_HEADER_WRITTEN=0
            
            log_message "Rotasi log selesai pada waktu terjadwal: $current_time"
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
    echo "Jadwal berikutnya: $next_schedule_time (dalam $next_hours jam $next_minutes menit)"
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
            log_message "Rotasi log selesai (mode restart)"
        else
            log_message "Rotasi log selesai"
        fi
    fi
    
    # Periksa dan simpan PID
    check_and_save_pid
    download_files
    
    # Reset variabel untuk melacak interval dan jadwal terakhir
    LAST_INTERVAL=0
    LAST_EXECUTED_SCHEDULE=""
    LAST_SCHEDULE_TIME=0
    
    # Inisialisasi untuk loop pertama
    adaptive_interval=$(calculate_adaptive_interval)
    next_schedule_info=$(get_next_schedule_info)
    
    # Kemudian jalankan loop untuk memeriksa jadwal sesuai interval yang dikonfigurasi
    log_message "-------------------------------------"
    log_message "Starts a schedule check loop"
    current_hour=$(date +"%H:%M")
    next_schedule_time=$(echo "$next_schedule_info" | grep -o "[0-9][0-9]:[0-9][0-9]")
    next_schedule_diff=$(echo "$next_schedule_info" | grep -o "dalam [0-9]* jam [0-9]* menit" | sed 's/dalam //')
    
    # Log interval yang dipilih untuk loop pertama
    log_message "Next update check: $next_schedule_time"
    log_message "Current time: $current_hour"
    
    # Hitung waktu pemeriksaan pertama (current_hour + adaptive_interval)
    first_check_info=$(calculate_next_check_time $adaptive_interval)
    log_message "First schedule check: $first_check_info (Interval: $adaptive_interval)"
    
    # Loop utama
    while true; do
        
        # Tunggu sesuai interval adaptif
        sleep $adaptive_interval
        
        log_message "-------------------------------------"
        
        # Hitung interval adaptif untuk siklus berikutnya
        next_adaptive_interval=$(calculate_adaptive_interval)
        
        # Log informasi pemeriksaan jadwal dengan interval yang benar
        log_message "Schedule check"

        # Jalankan pemeriksaan jadwal
        check_schedule_and_run
        
        # Dapatkan waktu ke jadwal berikutnya untuk log
        next_schedule_info=$(get_next_schedule_info)
        
        # Ekstrak informasi jadwal untuk format log yang lebih ringkas
        current_hour=$(date +"%H:%M")
        next_schedule_time=$(echo "$next_schedule_info" | grep -o "[0-9][0-9]:[0-9][0-9]")
        next_schedule_diff=$(echo "$next_schedule_info" | grep -o "dalam [0-9]* jam [0-9]* menit" | sed 's/dalam //')
        
        # Log waktu tunggu untuk siklus berikutnya
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

# Deteksi apakah script dijalankan oleh restart-auto-download.sh atau saat boot
RESTART_FLAG_FILE="/data/adb/auto-download/restart_flag"
RESTART_MODE=0
BOOT_MODE=0

# Periksa apakah file penanda restart ada dan baru dibuat (dalam 10 detik terakhir)
if [ -f "$RESTART_FLAG_FILE" ]; then
    FLAG_TIME=$(cat "$RESTART_FLAG_FILE")
    CURRENT_TIME=$(date +%s)
    TIME_DIFF=$((CURRENT_TIME - FLAG_TIME))
    
    # Jika file penanda dibuat dalam 10 detik terakhir, anggap dijalankan oleh restart-auto-download.sh
    if [ $TIME_DIFF -le 10 ]; then
        RESTART_MODE=1
        # Hapus file penanda setelah digunakan
        rm -f "$RESTART_FLAG_FILE"
    fi
fi

# Periksa apakah dijalankan saat boot
if [ "$(dirname "$0")" = "/data/adb/service.d" ] || [ -f "/data/adb/auto-download/boot.log" ]; then
    BOOT_MODE=1
fi

# Jika dijalankan dalam mode restart, langsung jalankan daemon
if [ $RESTART_MODE -eq 1 ]; then
    run_as_daemon > /dev/null 2>&1 &
    exit 0
fi

# Jika dijalankan saat boot, tunggu beberapa saat
if [ $BOOT_MODE -eq 1 ]; then
    log_message "Script dijalankan saat boot, menunggu $BOOT_WAIT_TIME detik"
    sleep $BOOT_WAIT_TIME
else
    log_message "Script dijalankan secara manual"
fi

# Selalu jalankan sebagai daemon untuk mode boot dan manual
log_message "Menjalankan dalam mode daemon"
run_as_daemon > /dev/null 2>&1 &

