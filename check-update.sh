#!/bin/bash

# Script untuk memeriksa dan mengupdate file auto-download.sh
# Script ini akan memeriksa hash SHA-1 dari file tersebut dan mengunduhnya jika berbeda

# ===== KONFIGURASI DASAR =====
# URL untuk file yang akan diperiksa
SCRIPT_UPDATE_URL="https://raw.githubusercontent.com/exball/sing-box-config/refs/heads/Master/auto-download.sh"

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
DEBUG_LOG_FILE="/data/adb/auto-download/debug-check-update.log"

# Path ke script restart
RESTART_SCRIPT="/data/adb/auto-download/restart-auto-download.sh"

# Path untuk file feedback untuk komunikasi dengan auto-download.sh
FEEDBACK_FILE=""

# Flag untuk menandakan apakah script dipanggil dari auto-download.sh
FROM_AUTO_DOWNLOAD=0

# ===== PERSIAPAN =====
# Pastikan direktori yang diperlukan ada
mkdir -p /data/adb/auto-download
mkdir -p "$TEMP_DIR"

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

# Fungsi untuk menulis log debug
debug_log() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    if [ -n "$DEBUG_LOG_FILE" ]; then
        echo "[$timestamp] DEBUG: $message" >> "$DEBUG_LOG_FILE"
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

# Fungsi untuk memeriksa dan mengupdate file
check_and_update_file() {
    local file_url="$1"
    local local_file="$2"
    local file_name=$(basename "$local_file")
    
    log_message "-----"
    log_message "Memeriksa pembaruan file $file_name..."
    
    # Nama file sementara untuk download
    local temp_file="$TEMP_DIR/${file_name}.new"
    
    # Download file dari URL untuk mendapatkan hash
    if curl -s -L --connect-timeout 10 --max-time 30 "$file_url" -o "$temp_file"; then
        # Hitung hash SHA-1 dari file yang didownload
        local github_sha1=$(get_local_sha1 "$temp_file")
        
        if [ -z "$github_sha1" ]; then
            log_message "Gagal mendapatkan SHA-1 file $file_name dari GitHub"
            rm -f "$temp_file"
            return 1
        else
            log_message "SHA-1 GitHub $file_name: $github_sha1"
            
            # Dapatkan hash SHA-1 dari file lokal jika ada
            local local_sha1=""
            if [ -f "$local_file" ]; then
                local_sha1=$(get_local_sha1 "$local_file")
                log_message "SHA-1 lokal $file_name: $local_sha1"
            fi
            
            # Bandingkan hash SHA-1
            if [ -n "$local_sha1" ] && [ "$local_sha1" = "$github_sha1" ]; then
                log_message "SHA-1 $file_name sama, tidak perlu diperbarui"
                rm -f "$temp_file"
                return 0
            else
                log_message "SHA-1 $file_name berbeda atau file tidak ada, memperbarui..."
                
                # Hapus backup lama jika ada
                if [ -f "${local_file}.bak" ]; then
                    rm -f "${local_file}.bak"
                fi
                
                # Buat backup file lama jika ada
                if [ -f "$local_file" ]; then
                    cp "$local_file" "${local_file}.bak"
                fi
                
                # Pastikan direktori tujuan ada
                mkdir -p "$(dirname "$local_file")"
                
                # Pindahkan file baru
                mv "$temp_file" "$local_file"
                
                # Berikan izin eksekusi jika ini adalah file script
                if [[ "$file_name" == *.sh ]]; then
                    chmod +x "$local_file"
                fi
                
                log_message "Berhasil memperbarui $file_name (SHA-1 terverifikasi)"
                
                # Hapus file backup karena pembaruan berhasil
                if [ -f "${local_file}.bak" ]; then
                    rm -f "${local_file}.bak"
                fi
                
                return 2  # Kode 2 menandakan file diperbarui
            fi
        fi
    else
        log_message "Gagal mendownload $file_name dari $file_url"
        rm -f "$temp_file"
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
        
        # Jika dipanggil dari auto-download.sh, kirim feedback bahwa tidak ada pembaruan
        if [ $FROM_AUTO_DOWNLOAD -eq 1 ] && [ -n "$FEEDBACK_FILE" ]; then
            debug_log "Mengirim feedback NO_UPDATE karena tidak ada koneksi internet"
            echo "NO_UPDATE" > "$FEEDBACK_FILE"
            debug_log "Feedback NO_UPDATE telah ditulis ke $FEEDBACK_FILE"
        fi
        
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
    
    # Jika dipanggil dari auto-download.sh, kirim feedback
    debug_log "Memeriksa apakah perlu mengirim feedback (FROM_AUTO_DOWNLOAD=$FROM_AUTO_DOWNLOAD, FEEDBACK_FILE=$FEEDBACK_FILE)"
    if [ $FROM_AUTO_DOWNLOAD -eq 1 ] && [ -n "$FEEDBACK_FILE" ]; then
        debug_log "Kondisi feedback terpenuhi, files_updated=$files_updated"
        if [ $files_updated -eq 0 ]; then
            # Tidak ada pembaruan, kirim feedback untuk melanjutkan
            log_message "Mengirim feedback: Tidak ada pembaruan auto-download.sh"
            debug_log "Mengirim feedback NO_UPDATE ke $FEEDBACK_FILE"
            echo "NO_UPDATE" > "$FEEDBACK_FILE"
            debug_log "Feedback NO_UPDATE berhasil ditulis"
        else
            # Ada pembaruan, tidak perlu kirim feedback karena auto-download.sh akan di-restart
            log_message "Tidak mengirim feedback karena auto-download.sh akan di-restart"
            debug_log "Tidak mengirim feedback karena ada pembaruan (files_updated=$files_updated)"
        fi
    else
        debug_log "Kondisi feedback tidak terpenuhi, tidak mengirim feedback"
    fi
    
    # Jika ada file yang diperbarui, restart layanan jika diperlukan
    if [ $files_updated -eq 1 ]; then
        log_message "File-file telah diperbarui, mungkin perlu me-restart layanan"
        
        # Jika dipanggil dari auto-download.sh
        debug_log "Memeriksa apakah dipanggil dari auto-download.sh: FROM_AUTO_DOWNLOAD=$FROM_AUTO_DOWNLOAD"
        if [ $FROM_AUTO_DOWNLOAD -eq 1 ]; then
            debug_log "Dipanggil dari auto-download.sh, memeriksa restart script: $RESTART_SCRIPT"
            # Jika restart script tersedia
            if [ -x "$RESTART_SCRIPT" ]; then
                debug_log "Restart script dapat dieksekusi, menjalankan restart"
                log_message "Menjalankan restart-auto-download.sh untuk me-restart auto-download.sh..."
                nohup "$RESTART_SCRIPT" > /dev/null 2>&1 &
                log_message "restart-auto-download.sh telah dijalankan"
                debug_log "restart-auto-download.sh berhasil dijalankan, mengembalikan kode 99"
                
                # Keluar dengan kode 99 untuk memberi tahu auto-download.sh bahwa ada pembaruan
                return 99
            else
                debug_log "Restart script tidak dapat dieksekusi atau tidak ditemukan"
                log_message "PERINGATAN: restart-auto-download.sh tidak ditemukan atau tidak dapat dieksekusi"
                return 1
            fi
        else
            # Jika tidak dipanggil dari auto-download.sh, gunakan metode restart langsung
            if pgrep -f "auto-download.sh" > /dev/null; then
                log_message "Mendeteksi auto-download.sh sedang berjalan, mencoba me-restart..."
                
                # Hentikan proses yang sedang berjalan
                pkill -f "auto-download.sh"
                sleep 2
                
                # Jalankan kembali auto-download.sh
                if [ -x "$SCRIPT_FILE" ]; then
                    log_message "Menjalankan kembali auto-download.sh..."
                    nohup "$SCRIPT_FILE" > /dev/null 2>&1 &
                    log_message "auto-download.sh telah di-restart dengan PID: $!"
                else
                    log_message "PERINGATAN: auto-download.sh tidak dapat dieksekusi"
                fi
            else
                log_message "auto-download.sh tidak sedang berjalan, tidak perlu di-restart"
            fi
        fi
    else
        log_message "Tidak ada file yang diperbarui"
    fi
    
    log_message "Proses pemeriksaan selesai"
    return 0
}

# ===== EKSEKUSI UTAMA =====
# Inisialisasi file log jika belum ada
if [ -n "$LOG_FILE" ] && [ ! -f "$LOG_FILE" ]; then
    touch "$LOG_FILE"
fi

# Inisialisasi file debug log jika belum ada
if [ -n "$DEBUG_LOG_FILE" ] && [ ! -f "$DEBUG_LOG_FILE" ]; then
    touch "$DEBUG_LOG_FILE"
fi

# Debug log awal
debug_log "=== Memulai check-update.sh ==="
debug_log "Parameter yang diterima: $*"

# Periksa parameter command line
for arg in "$@"; do
    debug_log "Memproses parameter: $arg"
    case "$arg" in
        --from-auto-download)
            FROM_AUTO_DOWNLOAD=1
            log_message "Dijalankan dari auto-download.sh"
            debug_log "Flag FROM_AUTO_DOWNLOAD diset ke 1"
            ;;
        --feedback-file=*)
            FEEDBACK_FILE="${arg#*=}"
            log_message "File feedback: $FEEDBACK_FILE"
            debug_log "File feedback diset ke: $FEEDBACK_FILE"
            ;;
        *)
            debug_log "Parameter tidak dikenali: $arg"
            ;;
    esac
done

# Jalankan pemeriksaan dan pembaruan
log_message "Memulai check-update.sh"
debug_log "Memulai run_update_check"
run_update_check
exit_code=$?
log_message "check-update.sh selesai dengan kode: $exit_code"
debug_log "check-update.sh selesai dengan kode: $exit_code"
debug_log "=== Selesai check-update.sh ==="

exit $exit_code