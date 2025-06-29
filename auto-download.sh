#!/bin/bash

# Test 3
# Script untuk mendownload file konfigurasi secara otomatis
# Dengan fitur pemeriksaan hash SHA-1 untuk menghindari download ulang
# Versi dengan CHECK_INTERVAL adaptif dan pembaruan auto-download.conf

# ===== KONFIGURASI BOOTSTRAP =====
# Parameter minimal yang diperlukan untuk memeriksa pembaruan konfigurasi
# Parameter ini TIDAK BOLEH diubah melalui file konfigurasi eksternal
CONF_UPDATE_URL="https://raw.githubusercontent.com/exball/sing-box-config/refs/heads/Master/auto-download.conf"
CONFIG_FILE="/data/adb/auto-download/auto-download.conf"
TEMP_DIR="/data/adb/auto-download/download_temp"
NETWORK_TEST_URL="https://www.google.com"
NETWORK_MAX_ATTEMPTS=5
NETWORK_RETRY_WAIT=3
LOG_FILE="/data/adb/auto-download/auto-download.log"
DEBUG_LOG_FILE="/data/adb/auto-download/debug-auto-download.log"

# Pastikan direktori yang diperlukan ada
mkdir -p /data/adb/auto-download
mkdir -p "$TEMP_DIR"

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

# Fungsi untuk menulis log debug
debug_log() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    if [ -n "$DEBUG_LOG_FILE" ]; then
        # Pastikan direktori ada
        mkdir -p "$(dirname "$DEBUG_LOG_FILE")" 2>/dev/null
        
        # Coba tulis ke file debug log
        if echo "[$timestamp] DEBUG: $message" >> "$DEBUG_LOG_FILE" 2>/dev/null; then
            # Berhasil menulis
            :
        else
            # Jika gagal, coba di /tmp
            DEBUG_LOG_FILE="/tmp/debug-auto-download.log"
            echo "[$timestamp] DEBUG: $message" >> "$DEBUG_LOG_FILE" 2>/dev/null
        fi
    fi
    
    # Juga tampilkan di konsol jika dijalankan interaktif
    if [ -t 1 ]; then
        echo "DEBUG: $message"
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

# Fungsi untuk memeriksa koneksi jaringan
check_network_connection() {
    log_message "Memeriksa koneksi internet..."
    
    local attempt=1
    local connected=0
    
    while [ $attempt -le $NETWORK_MAX_ATTEMPTS ]; do
        log_message "Percobaan koneksi ke $NETWORK_TEST_URL (Percobaan $attempt dari $NETWORK_MAX_ATTEMPTS)"
        
        # Gunakan curl untuk memeriksa koneksi ke URL yang ditentukan
        # -s: silent mode, -f: fail silently, -m: timeout dalam detik, -o: output ke /dev/null
        if curl -s -f -m 10 --connect-timeout 5 -o /dev/null "$NETWORK_TEST_URL"; then
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
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$TEMP_DIR"

# Inisialisasi file log jika belum ada
if [ -n "$LOG_FILE" ] && [ ! -f "$LOG_FILE" ]; then
    touch "$LOG_FILE"
fi

# Inisialisasi file debug log jika belum ada
if [ -n "$DEBUG_LOG_FILE" ]; then
    mkdir -p "$(dirname "$DEBUG_LOG_FILE")" 2>/dev/null
    
    # Coba buat file debug log
    if touch "$DEBUG_LOG_FILE" 2>/dev/null && [ -w "$DEBUG_LOG_FILE" ]; then
        # Test write untuk memastikan file dapat ditulis
        if echo "[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG: Inisialisasi file debug log berhasil" >> "$DEBUG_LOG_FILE" 2>/dev/null; then
            # Berhasil menulis ke file debug log
            :
        else
            # Jika tidak bisa menulis, coba di /tmp
            DEBUG_LOG_FILE="/tmp/debug-auto-download.log"
            touch "$DEBUG_LOG_FILE" 2>/dev/null
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG: Menggunakan file debug log di /tmp karena tidak bisa menulis ke file asli" >> "$DEBUG_LOG_FILE" 2>/dev/null
        fi
    else
        # Jika tidak bisa membuat file, coba di /tmp
        DEBUG_LOG_FILE="/tmp/debug-auto-download.log"
        touch "$DEBUG_LOG_FILE" 2>/dev/null
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG: Menggunakan file debug log di /tmp karena tidak bisa membuat file asli" >> "$DEBUG_LOG_FILE" 2>/dev/null
    fi
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

# Fungsi untuk memeriksa jaringan setelah pemeriksaan PID
check_network_after_pid() {
    log_message "Memeriksa koneksi internet setelah me-restart Sing-Box..."
    
    # Gunakan curl untuk memeriksa koneksi ke URL yang ditentukan
    log_message "Percobaan koneksi ke $NETWORK_TEST_URL"
    if curl -s -f -m 10 --connect-timeout 5 -o /dev/null "$NETWORK_TEST_URL"; then
        log_message "Koneksi internet tersedia"
        return 0
    else
        log_message "Koneksi internet tidak berfungsi, mencoba memulai ulang layanan sing-box..."
        
        # Jalankan perintah untuk memulai ulang layanan dan mengaktifkan iptables
        /data/adb/box/scripts/box.service start && /data/adb/box/scripts/box.iptables enable
        
        # Tunggu beberapa detik
        sleep 5
        
        # Periksa lagi koneksi
        log_message "Memeriksa koneksi internet setelah memulai ulang layanan..."
        if curl -s -f -m 10 --connect-timeout 5 -o /dev/null "$NETWORK_TEST_URL"; then
            log_message "Koneksi internet berhasil dipulihkan setelah memulai ulang layanan"
            return 0
        else
            log_message "Koneksi internet masih bermasalah setelah memulai ulang layanan"
            return 1
        fi
    fi
}

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

# Pastikan direktori auto-download ada
mkdir -p "/data/adb/auto-download"

# Pastikan direktori log ada jika LOG_FILE dikonfigurasi
if [ -n "$LOG_FILE" ]; then
    mkdir -p "$(dirname "$LOG_FILE")"
fi

# Pastikan direktori penyimpanan dan temp ada
mkdir -p "$SAVE_DIR"
mkdir -p "$CONFIG_DIR"
mkdir -p "$TEMP_DIR"

# Fungsi untuk mendapatkan hash SHA-1 dari file lokal
get_local_sha1() {
    local file="$1"
    if [ -f "$file" ]; then
        sha1sum "$file" | awk '{print $1}'
    else
        echo ""
    fi
}

# Fungsi untuk mendapatkan hash SHA-1 dari URL raw GitHub
get_github_sha1() {
    local raw_url="$1"
    
    # Buat direktori temp jika belum ada
    mkdir -p "$TEMP_DIR"
    
    # Nama file sementara untuk download
    local temp_hash_file="$TEMP_DIR/temp_hash_file"
    
    # Download file dari URL raw GitHub
    if curl -s -L --connect-timeout 10 --max-time 30 "$raw_url" -o "$temp_hash_file"; then
        # Hitung hash SHA-1 dari file yang didownload
        local sha1=$(get_local_sha1 "$temp_hash_file")
        
        # Hapus file sementara
        rm -f "$temp_hash_file"
        
        # Kembalikan hash SHA-1
        echo "$sha1"
    else
        log_message "Gagal mendownload file untuk pemeriksaan hash dari: $raw_url"
        echo ""
    fi
}

# Fungsi untuk memeriksa koneksi jaringan
check_network_connection() {
    log_message "Memeriksa koneksi internet..."
    
    local attempt=1
    local connected=0
    
    while [ $attempt -le $NETWORK_MAX_ATTEMPTS ]; do
        log_message "Percobaan koneksi ke $NETWORK_TEST_URL (Percobaan $attempt dari $NETWORK_MAX_ATTEMPTS)"
        
        # Gunakan curl untuk memeriksa koneksi ke URL yang ditentukan
        # -s: silent mode, -f: fail silently, -m: timeout dalam detik, -o: output ke /dev/null
        if curl -s -f -m 10 --connect-timeout 5 -o /dev/null "$NETWORK_TEST_URL"; then
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

# Fungsi untuk memeriksa dan mengupdate file check-update.sh
check_update_script() {
    local script_url="$1"
    local script_file="$2"
    local script_name=$(basename "$script_file")
    
    log_message "-----"
    log_message "Memeriksa pembaruan file $script_name..."
    
    # Nama file sementara untuk download
    local temp_script_file="$TEMP_DIR/${script_name}.new"
    
    # Download file dari URL untuk mendapatkan hash
    if curl -s -L --connect-timeout 10 --max-time 30 "$script_url" -o "$temp_script_file"; then
        # Hitung hash SHA-1 dari file yang didownload
        local github_sha1=$(get_local_sha1 "$temp_script_file")
        
        if [ -z "$github_sha1" ]; then
            log_message "Gagal mendapatkan SHA-1 file $script_name dari GitHub"
            rm -f "$temp_script_file"
            return 1
        else
            log_message "SHA-1 GitHub $script_name: $github_sha1"
            
            # Dapatkan hash SHA-1 dari file lokal jika ada
            local local_sha1=""
            if [ -f "$script_file" ]; then
                local_sha1=$(get_local_sha1 "$script_file")
                log_message "SHA-1 lokal $script_name: $local_sha1"
            fi
            
            # Bandingkan hash SHA-1
            if [ -n "$local_sha1" ] && [ "$local_sha1" = "$github_sha1" ]; then
                log_message "SHA-1 $script_name sama, tidak perlu diperbarui"
                rm -f "$temp_script_file"
                return 0
            else
                log_message "SHA-1 $script_name berbeda atau file tidak ada, memperbarui..."
                
                # Hapus backup lama jika ada
                if [ -f "${script_file}.bak" ]; then
                    rm -f "${script_file}.bak"
                fi
                
                # Buat backup file lama jika ada
                if [ -f "$script_file" ]; then
                    cp "$script_file" "${script_file}.bak"
                fi
                
                # Pastikan direktori tujuan ada
                mkdir -p "$(dirname "$script_file")"
                
                # Pindahkan file baru
                mv "$temp_script_file" "$script_file"
                
                # Berikan izin eksekusi
                chmod +x "$script_file"
                
                log_message "Berhasil memperbarui $script_name (SHA-1 terverifikasi)"
                
                # Hapus file backup karena pembaruan berhasil
                if [ -f "${script_file}.bak" ]; then
                    rm -f "${script_file}.bak"
                fi
                
                return 2  # Kode 2 menandakan file diperbarui
            fi
        fi
    else
        log_message "Gagal mendownload $script_name dari $script_url"
        rm -f "$temp_script_file"
        return 1
    fi
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
    
    # Periksa dan update file auto-download.conf terlebih dahulu
    log_message "-----"
    log_message "Memeriksa pembaruan file auto-download.conf..."
    
    # Gunakan hasil pemeriksaan koneksi internet sebelumnya
    if [ $? -eq 0 ]; then
        # Nama file sementara untuk download
        local temp_conf_file="$TEMP_DIR/auto-download.conf.new"
        
        # Download file dari URL raw GitHub untuk mendapatkan hash
        if curl -s -L --connect-timeout 10 --max-time 30 "$CONF_UPDATE_URL" -o "$temp_conf_file"; then
            # Hitung hash SHA-1 dari file yang didownload
            local github_sha1=$(get_local_sha1 "$temp_conf_file")
            
            if [ -z "$github_sha1" ]; then
                log_message "Gagal mendapatkan SHA-1 file konfigurasi dari GitHub"
                rm -f "$temp_conf_file"
            else
                log_message "SHA-1 GitHub auto-download.conf: $github_sha1"
                
                # Dapatkan hash SHA-1 dari file lokal jika ada
                local local_sha1=""
                if [ -f "$CONFIG_FILE" ]; then
                    local_sha1=$(get_local_sha1 "$CONFIG_FILE")
                    log_message "SHA-1 lokal auto-download.conf: $local_sha1"
                fi
                
                # Bandingkan hash SHA-1
                if [ -n "$local_sha1" ] && [ "$local_sha1" = "$github_sha1" ]; then
                    log_message "SHA-1 auto-download.conf sama, menggunakan konfigurasi lokal"
                    rm -f "$temp_conf_file"
                else
                    log_message "SHA-1 auto-download.conf berbeda atau file tidak ada, memperbarui..."
                    
                    # Hapus backup lama jika ada
                    if [ -f "$CONFIG_FILE.bak" ]; then
                        rm -f "$CONFIG_FILE.bak"
                    fi
                    
                    # Buat backup konfigurasi lama jika ada
                    if [ -f "$CONFIG_FILE" ]; then
                        cp "$CONFIG_FILE" "$CONFIG_FILE.bak"
                    fi
                    
                    # Pindahkan file konfigurasi baru
                    mv "$temp_conf_file" "$CONFIG_FILE"
                    log_message "Berhasil memperbarui auto-download.conf (SHA-1 terverifikasi)"
                    
                    # Muat ulang konfigurasi
                    source "$CONFIG_FILE"
                    log_message "Konfigurasi baru dimuat dari $CONFIG_FILE"
                    
                    # Hapus file backup karena pembaruan berhasil
                    if [ -f "$CONFIG_FILE.bak" ]; then
                        rm -f "$CONFIG_FILE.bak"
                    fi
                    
                    files_updated=1
                fi
            fi
        else
            log_message "Gagal mendownload auto-download.conf dari $CONF_UPDATE_URL"
            rm -f "$temp_conf_file"
        fi
    else
        log_message "Pemeriksaan pembaruan konfigurasi dibatalkan karena tidak ada koneksi internet"
    fi
    
    # Periksa dan update file check-update.sh
    if [ -n "$CHECK_UPDATE_SCRIPT_URL" ] && [ -n "$CHECK_UPDATE_SCRIPT_FILE" ]; then
        check_update_script "$CHECK_UPDATE_SCRIPT_URL" "$CHECK_UPDATE_SCRIPT_FILE"
        local check_update_result=$?
        
        if [ $check_update_result -eq 2 ]; then
            log_message "File check-update.sh telah diperbarui"
            
            # Jalankan check-update.sh jika diperbarui
            # Pastikan file check-update.sh memiliki izin eksekusi
            debug_log "Memeriksa izin eksekusi check-update.sh"
            if [ -f "$CHECK_UPDATE_SCRIPT_FILE" ]; then
                debug_log "File check-update.sh ada: $CHECK_UPDATE_SCRIPT_FILE"
                
                # Berikan izin eksekusi
                chmod +x "$CHECK_UPDATE_SCRIPT_FILE"
                debug_log "Izin eksekusi diberikan ke check-update.sh"
                
                # Periksa kembali apakah file dapat dieksekusi
                if [ -x "$CHECK_UPDATE_SCRIPT_FILE" ]; then
                    debug_log "File check-update.sh dapat dieksekusi"
                    log_message "Menjalankan check-update.sh yang baru diperbarui..."
                    
                    debug_log "Menjalankan: $CHECK_UPDATE_SCRIPT_FILE"
                    debug_log "Perintah lengkap: bash $CHECK_UPDATE_SCRIPT_FILE"
                    debug_log "Izin file: $(ls -la $CHECK_UPDATE_SCRIPT_FILE)"
                    debug_log "Isi direktori: $(ls -la $(dirname "$CHECK_UPDATE_SCRIPT_FILE"))"
                    
                    # Coba jalankan dengan bash eksplisit untuk menghindari masalah izin
                    debug_log "Menjalankan check-update.sh dengan bash eksplisit"
                    bash "$CHECK_UPDATE_SCRIPT_FILE"
                    check_update_exit_code=$?
                    debug_log "check-update.sh selesai dengan kode: $check_update_exit_code"
                    
                    # Jika ada error, coba jalankan dengan sh
                    if [ $check_update_exit_code -ne 0 ] && [ $check_update_exit_code -ne 99 ]; then
                        debug_log "Mencoba menjalankan dengan sh karena ada error"
                        sh "$CHECK_UPDATE_SCRIPT_FILE"
                        check_update_exit_code=$?
                        debug_log "check-update.sh (dengan sh) selesai dengan kode: $check_update_exit_code"
                    fi
                    
                    # Jika check-update.sh mengembalikan kode 0, lanjutkan
                    # Jika mengembalikan kode 99, berarti ada pembaruan auto-download.sh
                    # Jika mengembalikan kode lain, anggap sebagai error
                    if [ $check_update_exit_code -eq 99 ]; then
                        log_message "check-update.sh mendeteksi pembaruan auto-download.sh, menghentikan proses"
                        debug_log "Proses dihentikan karena ada pembaruan auto-download.sh"
                        return 1
                    elif [ $check_update_exit_code -ne 0 ]; then
                        log_message "check-update.sh mengembalikan kode error: $check_update_exit_code, menghentikan proses"
                        debug_log "Proses dihentikan karena error pada check-update.sh"
                        return 1
                    fi
                    debug_log "check-update.sh berhasil dijalankan tanpa error"
                else
                    log_message "PERINGATAN: check-update.sh tidak dapat dieksekusi setelah chmod"
                    debug_log "ERROR: File check-update.sh tidak dapat dieksekusi meskipun sudah diberikan chmod +x"
                fi
            else
                log_message "PERINGATAN: File check-update.sh tidak ditemukan"
                debug_log "ERROR: File check-update.sh tidak ditemukan di: $CHECK_UPDATE_SCRIPT_FILE"
            fi
        fi
        
        # Jalankan check-update.sh untuk memeriksa pembaruan auto-download.sh
        debug_log "Memeriksa apakah check-update.sh dapat dieksekusi untuk pemeriksaan auto-download.sh"
        if [ -x "$CHECK_UPDATE_SCRIPT_FILE" ]; then
            debug_log "check-update.sh dapat dieksekusi, memulai pemeriksaan auto-download.sh"
            log_message "Menjalankan check-update.sh untuk memeriksa pembaruan auto-download.sh..."
            
            # Buat file sementara untuk komunikasi
            FEEDBACK_FILE="/data/adb/auto-download/feedback.tmp"
            debug_log "Membuat file feedback: $FEEDBACK_FILE"
            if [ -e "$FEEDBACK_FILE" ]; then
                rm -f "$FEEDBACK_FILE"
                debug_log "File feedback lama dihapus"
            fi
            touch "$FEEDBACK_FILE"
            debug_log "File feedback baru dibuat"
            
            # Jalankan check-update.sh dengan parameter tambahan untuk menandakan pemeriksaan dari auto-download.sh
            debug_log "Menjalankan: $CHECK_UPDATE_SCRIPT_FILE --from-auto-download --feedback-file=$FEEDBACK_FILE"
            debug_log "Perintah lengkap: bash $CHECK_UPDATE_SCRIPT_FILE --from-auto-download --feedback-file=$FEEDBACK_FILE"
            debug_log "Izin file: $(ls -la $CHECK_UPDATE_SCRIPT_FILE)"
            debug_log "Isi direktori: $(ls -la $(dirname "$CHECK_UPDATE_SCRIPT_FILE"))"
            
            # Pastikan file feedback dapat ditulis
            debug_log "Memastikan file feedback dapat ditulis"
            touch "$FEEDBACK_FILE" 2>/dev/null
            debug_log "Status touch: $?"
            
            # Coba jalankan dengan bash eksplisit untuk menghindari masalah izin
            debug_log "Menjalankan check-update.sh dengan bash eksplisit"
            debug_log "Parameter 1: --from-auto-download"
            debug_log "Parameter 2: --feedback-file=$FEEDBACK_FILE"
            debug_log "Perintah yang akan dijalankan: bash \"$CHECK_UPDATE_SCRIPT_FILE\" --from-auto-download --feedback-file=\"$FEEDBACK_FILE\""
            
            # Jalankan dengan logging yang lebih detail
            bash "$CHECK_UPDATE_SCRIPT_FILE" --from-auto-download --feedback-file="$FEEDBACK_FILE"
            check_update_exit_code=$?
            debug_log "check-update.sh selesai dengan kode: $check_update_exit_code"
            
            # Periksa apakah file feedback ada dan dapat dibaca
            if [ -f "$FEEDBACK_FILE" ]; then
                debug_log "File feedback ada: $(ls -la "$FEEDBACK_FILE")"
                debug_log "Isi file feedback: $(cat "$FEEDBACK_FILE" 2>/dev/null || echo "tidak dapat dibaca")"
            else
                debug_log "File feedback tidak ada setelah eksekusi check-update.sh"
            fi
            
            log_message "check-update.sh selesai dengan kode: $check_update_exit_code"
            
            # Jika check-update.sh mengembalikan kode 99, berarti ada pembaruan auto-download.sh
            if [ $check_update_exit_code -eq 99 ]; then
                log_message "Pembaruan auto-download.sh terdeteksi, menghentikan proses saat ini..."
                debug_log "Menghentikan proses karena ada pembaruan auto-download.sh"
                rm -f "$FEEDBACK_FILE"
                return 1
            elif [ $check_update_exit_code -ne 0 ]; then
                log_message "check-update.sh mengembalikan kode error: $check_update_exit_code, tetapi melanjutkan proses..."
                debug_log "Ada error pada check-update.sh tetapi melanjutkan proses"
            fi
            
            # Baca feedback dari file
            debug_log "Memeriksa file feedback"
            if [ -f "$FEEDBACK_FILE" ]; then
                feedback=$(cat "$FEEDBACK_FILE")
                debug_log "Feedback diterima: $feedback"
                rm -f "$FEEDBACK_FILE"
                
                # Proses feedback
                if [ "$feedback" = "NO_UPDATE" ]; then
                    log_message "Tidak ada pembaruan auto-download.sh, melanjutkan proses..."
                    debug_log "Tidak ada pembaruan, melanjutkan proses"
                else
                    log_message "Feedback tidak dikenali: $feedback, melanjutkan proses..."
                    debug_log "Feedback tidak dikenali: $feedback"
                fi
            else
                log_message "File feedback tidak ditemukan, melanjutkan proses..."
                debug_log "File feedback tidak ditemukan"
            fi
        else
            debug_log "check-update.sh tidak dapat dieksekusi, melewati pemeriksaan auto-download.sh"
        fi
    else
        log_message "URL atau path file check-update.sh tidak dikonfigurasi, melewati pemeriksaan"
    fi
    
    # Loop melalui setiap URL dan download
    for url in "${PROVIDER_URLS[@]}"; do
        # Ekstrak nama file dari URL
        filename=$(basename "$url" | sed 's/%20/ /g')
        temp_file="$TEMP_DIR/$filename"
        target_file="$SAVE_DIR/$filename"
        use_content_check=0
        
        log_message "-----"
        log_message "Memeriksa Hash SHA-1 $filename..."
        
        if [ "$USE_SHA1_CHECK" -eq 1 ] && [ "$use_content_check" -eq 0 ]; then
            # Dapatkan hash SHA-1 dari GitHub
            github_sha1=$(get_github_sha1 "$url")
            
            if [ -z "$github_sha1" ]; then
                log_message "Gagal mendapatkan SHA-1 dari GitHub, menggunakan metode pemeriksaan konten"
                # Jika gagal mendapatkan hash SHA-1, gunakan metode pemeriksaan konten untuk file ini saja
                use_content_check=1
            else
                log_message "SHA-1 GitHub: $github_sha1"
                
                # Dapatkan hash SHA-1 dari file lokal jika ada
                local_sha1=""
                if [ -f "$target_file" ]; then
                    local_sha1=$(get_local_sha1 "$target_file")
                    log_message "SHA-1 lokal: $local_sha1"
                fi
                
                # Bandingkan hash SHA-1
                if [ -n "$local_sha1" ] && [ "$local_sha1" = "$github_sha1" ]; then
                    log_message "SHA-1 sama, melewati download"
                    continue
                else
                    log_message "SHA-1 berbeda atau file tidak ada, mendownload..."
                    # Download file dari URL raw GitHub
                    log_message "Mendownload dari URL: $url"
                    if curl -s -L --connect-timeout 10 --max-time 30 "$url" -o "$temp_file"; then
                        # Verifikasi hash SHA-1 file yang didownload
                        downloaded_sha1=$(get_local_sha1 "$temp_file")
                        log_message "SHA-1 didownload: $downloaded_sha1"
                        log_message "SHA-1 GitHub: $github_sha1"
                        
                        if [ "$downloaded_sha1" = "$github_sha1" ]; then
                            # Pindahkan file dari temp ke direktori tujuan
                            mv "$temp_file" "$target_file"
                            log_message "Berhasil mendownload (SHA-1 terverifikasi)"
                            files_updated=1
                        else
                            log_message "SHA-1 tidak cocok, melewati update"
                            log_message "SHA-1 didownload: $downloaded_sha1"
                            log_message "SHA-1 GitHub: $github_sha1"
                            rm -f "$temp_file"
                        fi
                    else
                        log_message "Gagal mendownload file"
                        rm -f "$temp_file"
                    fi
                fi
                
                # Lanjutkan ke file berikutnya
                continue
            fi
        fi
        
        # Metode pemeriksaan konten (digunakan jika pemeriksaan SHA-1 dinonaktifkan atau gagal untuk file ini)
        # Reset variabel use_content_check untuk file berikutnya
        use_content_check=0
        log_message "Mendownload dari URL: $url"
        # Download file ke direktori sementara
        if curl -s -L --connect-timeout 10 --max-time 30 "$url" -o "$temp_file"; then
            # Hitung hash SHA-1 file yang didownload untuk logging
            downloaded_sha1=$(get_local_sha1 "$temp_file")
            log_message "SHA-1 didownload: $downloaded_sha1"
            
            # Periksa apakah file sudah ada
            if [ -f "$target_file" ]; then
                # Hitung hash SHA-1 file lokal untuk logging
                local_sha1=$(get_local_sha1 "$target_file")
                log_message "SHA-1 lokal: $local_sha1"
                
                # Bandingkan konten file
                if cmp -s "$temp_file" "$target_file"; then
                    log_message "File tidak berubah, melewati download"
                    log_message "SHA-1 sama: $downloaded_sha1"
                    rm "$temp_file"
                    continue
                else
                    log_message "File berubah, memperbarui..."
                    mv "$temp_file" "$target_file"
                    log_message "Berhasil memperbarui file"
                    files_updated=1
                fi
            else
                # File belum ada, simpan file yang didownload
                mv "$temp_file" "$target_file"
                log_message "Berhasil mendownload file baru"
                files_updated=1
            fi
        else
            log_message "Gagal mendownload file"
            rm -f "$temp_file"
        fi
    done
    
    # Periksa koneksi jaringan sebelum memproses config.json
    log_message "-----"
    check_network_connection
    if [ $? -ne 0 ]; then
        log_message "Proses pemeriksaan config.json dibatalkan karena tidak ada koneksi internet"
        return 1
    fi
    
    # Proses config.json
    log_message "Memeriksa Hash SHA-1 config.json..."
    
    # Dapatkan hash SHA-1 dari GitHub untuk config.json
    github_sha1_config=$(get_github_sha1 "$CONFIG_URL")
    
    if [ -z "$github_sha1_config" ]; then
        log_message "Gagal mendapatkan SHA-1 config.json dari GitHub"
    else
        log_message "SHA-1 GitHub config.json: $github_sha1_config"
        
        # Dapatkan hash SHA-1 dari file lokal config.json jika ada
        local_sha1_config=""
        if [ -f "$CONFIG_DIR/config.json" ]; then
            local_sha1_config=$(get_local_sha1 "$CONFIG_DIR/config.json")
            log_message "SHA-1 lokal config.json: $local_sha1_config"
        fi
        
        # Bandingkan hash SHA-1 untuk config.json
        if [ -n "$local_sha1_config" ] && [ "$local_sha1_config" = "$github_sha1_config" ]; then
            log_message "SHA-1 config.json sama, melewati download"
        else
            log_message "SHA-1 config.json berbeda atau file tidak ada, mendownload..."
            # Download config.json dari URL raw GitHub
            log_message "Mendownload config.json dari URL: $CONFIG_URL"
            if curl -s -L --connect-timeout 10 --max-time 30 "$CONFIG_URL" -o "$TEMP_DIR/config.json"; then
                # Verifikasi hash SHA-1 file config.json yang didownload
                downloaded_sha1_config=$(get_local_sha1 "$TEMP_DIR/config.json")
                log_message "SHA-1 config.json didownload: $downloaded_sha1_config"
                log_message "SHA-1 config.json GitHub: $github_sha1_config"
                
                if [ "$downloaded_sha1_config" = "$github_sha1_config" ]; then
                    # Pindahkan file config.json dari temp ke direktori tujuan
                    mv "$TEMP_DIR/config.json" "$CONFIG_DIR/config.json"
                    log_message "Berhasil mendownload config.json (SHA-1 terverifikasi)"
                    files_updated=1
                else
                    log_message "SHA-1 config.json tidak cocok, melewati update"
                    log_message "SHA-1 config.json didownload: $downloaded_sha1_config"
                    log_message "SHA-1 config.json GitHub: $github_sha1_config"
                    rm -f "$TEMP_DIR/config.json"
                fi
            else
                log_message "Gagal mendownload config.json"
                rm -f "$TEMP_DIR/config.json"
            fi
        fi
    fi
    
    # Jika ada file yang diperbarui, restart layanan box
    if [ $files_updated -eq 1 ]; then
        log_message "-----"
        
        # Dapatkan PID layanan box sebelum restart
        local BOX_PID=""
        if [ -f "/data/adb/box/run/box.pid" ]; then
            BOX_PID=$(cat "/data/adb/box/run/box.pid")
            log_message "Ada file yang diperbarui, restart Sing-Box (PID: $BOX_PID)"
        else
            log_message "Ada file yang diperbarui, restart Sing-Box (PID: tidak ditemukan)"
        fi
        
        # Restart layanan
        /data/adb/box/scripts/box.service restart
        
        # Tunggu sebentar untuk memastikan layanan memiliki waktu untuk memulai ulang
        sleep $SERVICE_RESTART_WAIT
        
        # Baca log runs.log untuk melihat status restart
        if [ -f "/data/adb/box/run/runs.log" ]; then
            RUNS_LOG=$(tail -n 10 "/data/adb/box/run/runs.log")
            log_message "$RUNS_LOG"
        else
            log_message "File runs.log tidak ditemukan setelah restart"
        fi
        
        # Periksa apakah layanan box berhasil di-restart
        if [ -f "/data/adb/box/run/box.pid" ]; then
            NEW_PID=$(cat "/data/adb/box/run/box.pid")
            
            # Periksa apakah PID berubah
            if [ -n "$BOX_PID" ] && [ "$NEW_PID" != "$BOX_PID" ]; then
                log_message "Sing-Box berhasil di-restart (PID berubah dari $BOX_PID ke $NEW_PID)"
            else
                log_message "PID layanan box setelah restart: $NEW_PID"
            fi
            
            # Periksa apakah proses dengan PID tersebut benar-benar berjalan
            if kill -0 "$NEW_PID" 2>/dev/null; then
                # PID berjalan, tidak perlu log tambahan
                :
            else
                log_message "PERINGATAN: PID $NEW_PID ada di file, tetapi proses tidak berjalan"
                log_message "Mencoba memulai layanan box secara manual..."
                /data/adb/box/scripts/box.service start && /data/adb/box/scripts/box.iptables enable
                
                # Periksa lagi setelah mencoba memulai secara manual
                sleep $SERVICE_RESTART_WAIT
                if [ -f "/data/adb/box/run/box.pid" ]; then
                    MANUAL_PID=$(cat "/data/adb/box/run/box.pid")
                    if kill -0 "$MANUAL_PID" 2>/dev/null; then
                        log_message "Layanan box berhasil dimulai secara manual dengan PID: $MANUAL_PID"
                    else
                        log_message "PERINGATAN: Layanan box masih tidak berjalan setelah percobaan manual"
                    fi
                else
                    log_message "PERINGATAN: File PID tidak ditemukan setelah percobaan manual"
                fi
            fi
        else
            log_message "PERINGATAN: File PID tidak ditemukan setelah restart"
            log_message "Mencoba memulai layanan box secara manual..."
            /data/adb/box/scripts/box.service start && /data/adb/box/scripts/box.iptables enable
            
            # Periksa setelah mencoba memulai secara manual
            sleep $SERVICE_RESTART_WAIT
            if [ -f "/data/adb/box/run/box.pid" ]; then
                MANUAL_PID=$(cat "/data/adb/box/run/box.pid")
                if kill -0 "$MANUAL_PID" 2>/dev/null; then
                    log_message "Layanan box berhasil dimulai secara manual dengan PID: $MANUAL_PID"
                else
                    log_message "PERINGATAN: Layanan box masih tidak berjalan setelah percobaan manual"
                fi
            else
                log_message "PERINGATAN: File PID tidak ditemukan setelah percobaan manual"
            fi
        fi
    fi
    
    log_message "Proses pemeriksaan file selesai"
    
    # Periksa dan simpan PID
    check_and_save_pid
    
    # Periksa koneksi jaringan setelah restart layanan (jika ada)
    if [ $files_updated -eq 1 ]; then
        check_network_after_pid
    fi
}

# Fungsi untuk memeriksa apakah sudah waktunya menjalankan download
check_schedule_and_run() {
    # Dapatkan waktu saat ini dalam format hh:mm dan timestamp Unix
    current_time=$(date +%H:%M)
    current_hour=$(date +%H)
    current_minute=$(date +%M)
    current_timestamp=$(date +%s)
    
    # Log pemeriksaan jadwal sudah ditangani di loop utama
    
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
        log_message "Bukan waktu yang dijadwalkan"
    fi
}

# Fungsi untuk mendapatkan informasi jadwal berikutnya
get_next_schedule_info() {
    # Dapatkan waktu saat ini dalam detik sejak tengah malam
    current_seconds=$(($(date +%H) * 3600 + $(date +%M) * 60 + $(date +%S)))
    
    # Inisialisasi waktu ke jadwal berikutnya
    next_schedule_seconds=86400  # Default ke 24 jam (tidak ada jadwal dalam 24 jam)
    next_schedule_time=""
    
    # Periksa semua jadwal untuk menemukan yang terdekat
    for schedule_time in $SCHEDULE_HOURS; do
        # Konversi jadwal ke detik sejak tengah malam
        hour=$(echo $schedule_time | cut -d: -f1)
        minute=$(echo $schedule_time | cut -d: -f2)
        schedule_seconds=$((hour * 3600 + minute * 60))
        
        # Hitung selisih waktu (dalam detik)
        if [ $schedule_seconds -gt $current_seconds ]; then
            # Jadwal hari ini yang belum lewat
            diff_seconds=$((schedule_seconds - current_seconds))
            if [ $diff_seconds -lt $next_schedule_seconds ]; then
                next_schedule_seconds=$diff_seconds
                next_schedule_time=$schedule_time
            fi
        fi
    done
    
    # Jika tidak ada jadwal yang ditemukan untuk hari ini, cari jadwal pertama untuk besok
    if [ $next_schedule_seconds -eq 86400 ]; then
        for schedule_time in $SCHEDULE_HOURS; do
            hour=$(echo $schedule_time | cut -d: -f1)
            minute=$(echo $schedule_time | cut -d: -f2)
            schedule_seconds=$((hour * 3600 + minute * 60))
            
            # Jadwal untuk besok = jadwal + (24 jam - waktu saat ini)
            diff_seconds=$((schedule_seconds + 86400 - current_seconds))
            if [ $diff_seconds -lt $next_schedule_seconds ]; then
                next_schedule_seconds=$diff_seconds
                next_schedule_time=$schedule_time
            fi
        done
    fi
    
    # Konversi detik ke format jam dan menit untuk tampilan yang lebih mudah dibaca
    next_hours=$((next_schedule_seconds / 3600))
    next_minutes=$(((next_schedule_seconds % 3600) / 60))
    
    # Kembalikan informasi jadwal berikutnya
    echo "Jadwal berikutnya: $next_schedule_time (dalam $next_hours jam $next_minutes menit)"
}

# Fungsi untuk menghitung interval adaptif berdasarkan waktu ke jadwal berikutnya
calculate_adaptive_interval() {
    # Dapatkan waktu saat ini dalam detik sejak tengah malam
    current_seconds=$(($(date +%H) * 3600 + $(date +%M) * 60 + $(date +%S)))
    
    # Inisialisasi waktu ke jadwal berikutnya
    next_schedule_seconds=86400  # Default ke 24 jam (tidak ada jadwal dalam 24 jam)
    
    # Periksa semua jadwal untuk menemukan yang terdekat
    for schedule_time in $SCHEDULE_HOURS; do
        # Konversi jadwal ke detik sejak tengah malam
        hour=$(echo $schedule_time | cut -d: -f1)
        minute=$(echo $schedule_time | cut -d: -f2)
        schedule_seconds=$((hour * 3600 + minute * 60))
        
        # Hitung selisih waktu (dalam detik)
        if [ $schedule_seconds -gt $current_seconds ]; then
            # Jadwal hari ini yang belum lewat
            diff_seconds=$((schedule_seconds - current_seconds))
            if [ $diff_seconds -lt $next_schedule_seconds ]; then
                next_schedule_seconds=$diff_seconds
            fi
        fi
    done
    
    # Jika tidak ada jadwal yang ditemukan untuk hari ini, cari jadwal pertama untuk besok
    if [ $next_schedule_seconds -eq 86400 ]; then
        for schedule_time in $SCHEDULE_HOURS; do
            hour=$(echo $schedule_time | cut -d: -f1)
            minute=$(echo $schedule_time | cut -d: -f2)
            schedule_seconds=$((hour * 3600 + minute * 60))
            
            # Jadwal untuk besok = jadwal + (24 jam - waktu saat ini)
            diff_seconds=$((schedule_seconds + 86400 - current_seconds))
            if [ $diff_seconds -lt $next_schedule_seconds ]; then
                next_schedule_seconds=$diff_seconds
            fi
        done
    fi
    
    # Tentukan interval adaptif berdasarkan waktu ke jadwal berikutnya
    # Daftar interval yang tersedia (dalam detik)
    intervals=(7200 3600 3300 3000 2700 2400 2100 1800 1500 1200 900 600 300 60)
    
    # Pilih interval yang paling sesuai
    adaptive_interval=$CHECK_INTERVAL  # Default ke interval yang dikonfigurasi
    
    # Jika waktu ke jadwal berikutnya kurang dari interval default
    if [ $next_schedule_seconds -lt $CHECK_INTERVAL ]; then
        # Jika waktu ke jadwal berikutnya sangat dekat (kurang dari 2 menit), gunakan 60 detik
        if [ $next_schedule_seconds -le 120 ]; then
            adaptive_interval=60
        else
            # Kurangi waktu ke jadwal berikutnya dengan margin keamanan tetap (60 detik)
            safe_schedule_seconds=$((next_schedule_seconds - 60))
            
            # Jika waktu yang tersisa masih positif, gunakan untuk menentukan interval
            if [ $safe_schedule_seconds -gt 0 ]; then
                # Cari interval terbesar yang tidak melebihi waktu yang sudah dikurangi margin keamanan
                for interval in "${intervals[@]}"; do
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
    # Rotasi file log jika dikonfigurasi
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
    fi
    
    # Jalankan download pertama kali saat boot
    log_message "Rotasi log selesai, script dijalankan sebagai daemon"
    
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
    log_message "Memulai loop pemeriksaan jadwal dengan interval $adaptive_interval detik..."
    current_hour=$(date +"%H:%M")
    next_schedule_time=$(echo "$next_schedule_info" | grep -o "[0-9][0-9]:[0-9][0-9]")
    next_schedule_diff=$(echo "$next_schedule_info" | grep -o "dalam [0-9]* jam [0-9]* menit" | sed 's/dalam //')
    
    # Log interval yang dipilih untuk loop pertama
    log_message "Menunggu $adaptive_interval detik sampai pemeriksaan berikutnya..."
    log_message "Waktu saat ini: $current_hour, Jadwal berikutnya: $next_schedule_time ($next_schedule_diff)"
    
    # Loop utama
    while true; do
        
        # Tunggu sesuai interval adaptif
        sleep $adaptive_interval
        
        # Log pemeriksaan jadwal
        log_message "-------------------------------------"
        
        # Hitung interval adaptif untuk siklus berikutnya
        next_adaptive_interval=$(calculate_adaptive_interval)
        
        # Log informasi pemeriksaan jadwal dengan interval yang benar
        log_message "Pemeriksaan jadwal dengan Interval ($next_adaptive_interval detik)"
        
        # Dapatkan waktu ke jadwal berikutnya untuk log
        next_schedule_info=$(get_next_schedule_info)
        
        # Ekstrak informasi jadwal untuk format log yang lebih ringkas
        current_hour=$(date +"%H:%M")
        next_schedule_time=$(echo "$next_schedule_info" | grep -o "[0-9][0-9]:[0-9][0-9]")
        next_schedule_diff=$(echo "$next_schedule_info" | grep -o "dalam [0-9]* jam [0-9]* menit" | sed 's/dalam //')
        
        # Log waktu tunggu untuk siklus berikutnya
        log_message "Menunggu $next_adaptive_interval detik sampai pemeriksaan berikutnya..."
        log_message "Waktu saat ini: $current_hour, Jadwal berikutnya: $next_schedule_time ($next_schedule_diff)"
        
        # Jalankan pemeriksaan jadwal
        check_schedule_and_run
        
        # Simpan interval saat ini untuk perbandingan berikutnya
        LAST_INTERVAL=$next_adaptive_interval
        
        # Gunakan interval yang baru dihitung untuk siklus berikutnya
        adaptive_interval=$next_adaptive_interval
    done
}

# Deteksi apakah script dijalankan oleh restart-auto-download.sh atau saat boot
PARENT_PROCESS=$(ps -o comm= -p $PPID)
RESTART_MODE=0
BOOT_MODE=0

# Periksa apakah parent process adalah restart-auto-download.sh atau nohup
if [[ "$PARENT_PROCESS" == *"restart-auto-download"* ]] || [[ "$PARENT_PROCESS" == "nohup" ]]; then
    RESTART_MODE=1
fi

# Periksa apakah dijalankan saat boot
if [ "$(dirname "$0")" = "/data/adb/service.d" ] || [ -f "/data/adb/auto-download/boot.log" ]; then
    BOOT_MODE=1
fi

# Rotasi log jika diperlukan
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
    
    log_message "Rotasi log selesai"
fi

# Jika dijalankan saat boot, tunggu beberapa saat
if [ $BOOT_MODE -eq 1 ]; then
    log_message "Script dijalankan saat boot, menunggu $BOOT_WAIT_TIME detik"
    sleep $BOOT_WAIT_TIME
elif [ $RESTART_MODE -eq 1 ]; then
    log_message "Script dijalankan oleh restart-auto-download.sh"
else
    log_message "Script dijalankan secara manual"
fi

# Selalu jalankan sebagai daemon
log_message "Menjalankan dalam mode daemon"
run_as_daemon > /dev/null 2>&1 &

# Catatan penggunaan:
# 1. Untuk dijalankan otomatis saat boot, letakkan di /data/adb/service.d/
#    dan pastikan file memiliki permission eksekusi (chmod +x)
# 2. Untuk dijalankan manual: sh /path/to/auto-download.sh
# 3. Untuk melihat log saat ini: cat /data/adb/auto-download/auto-download.log
# 4. Untuk melihat log sebelumnya: cat /data/adb/auto-download/auto-download_old.log