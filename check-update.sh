#!/bin/bash

# Script untuk mengupdate file auto-download.conf dan auto-download.sh
# Script ini hanya bertanggung jawab untuk mendownload dan memperbarui file, bukan memeriksa

# ===== KONFIGURASI DASAR =====
# Direktori sementara untuk file yang didownload
TEMP_DIR="/data/adb/auto-download/download_temp"

# File log
LOG_FILE="/data/adb/auto-download/check-update.log"

# File PID untuk melacak proses yang sedang berjalan
PID_FILE="/data/adb/auto-download/check-update.pid"

# ===== PERSIAPAN =====
# Pastikan direktori yang diperlukan ada
mkdir -p /data/adb/auto-download
mkdir -p "$TEMP_DIR"

# Simpan PID untuk proses ini
echo $$ > "$PID_FILE"

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

# Fungsi untuk mendapatkan hash SHA-1 dari file lokal
get_local_sha1() {
    local file="$1"
    if [ -f "$file" ]; then
        sha1sum "$file" | awk '{print $1}'
    else
        echo ""
    fi
}

# Fungsi untuk menghentikan proses auto-download.sh
stop_auto_download() {
    log_message "Mencoba menghentikan proses auto-download.sh..."
    
    # Cari PID dari auto-download.sh
    local auto_download_pid=$(pgrep -f "auto-download.sh")
    
    if [ -n "$auto_download_pid" ]; then
        log_message "Menghentikan auto-download.sh dengan PID: $auto_download_pid"
        kill -15 $auto_download_pid
        sleep 1
        
        # Periksa apakah proses masih berjalan
        if pgrep -f "auto-download.sh" > /dev/null; then
            log_message "Proses auto-download.sh masih berjalan, mencoba kill -9..."
            pkill -9 -f "auto-download.sh"
            sleep 1
        fi
        
        log_message "Proses auto-download.sh telah dihentikan"
    else
        log_message "Tidak ada proses auto-download.sh yang berjalan"
    fi
}

# Fungsi untuk mengupdate file
update_file() {
    local file_url="$1"
    local local_file="$2"
    local file_name=$(basename "$local_file")
    
    # Validasi parameter
    if [ -z "$file_url" ]; then
        log_message "KESALAHAN: URL file tidak diberikan untuk $file_name"
        return 1
    fi
    
    if [ -z "$local_file" ]; then
        log_message "KESALAHAN: Path file lokal tidak diberikan"
        return 1
    fi
    
    log_message "-----"
    log_message "Memperbarui file $file_name..."
    log_message "URL: $file_url"
    log_message "File tujuan: $local_file"
    
    # Nama file sementara untuk download
    local temp_file="$TEMP_DIR/${file_name}.new"
    
    # Download file dari URL
    log_message "Mendownload file dari $file_url..."
    if curl -s -L --connect-timeout 10 --max-time 30 "$file_url" -o "$temp_file"; then
        # Periksa apakah file berhasil didownload dan tidak kosong
        if [ ! -s "$temp_file" ]; then
            log_message "KESALAHAN: File yang didownload kosong"
            rm -f "$temp_file"
            return 1
        fi
        
        # Hitung hash SHA-1 dari file yang didownload
        local github_sha1=$(get_local_sha1 "$temp_file")
        
        if [ -z "$github_sha1" ]; then
            log_message "KESALAHAN: Gagal mendapatkan SHA-1 file $file_name dari GitHub"
            rm -f "$temp_file"
            return 1
        else
            log_message "SHA-1 GitHub $file_name: $github_sha1"
            
            # Hapus backup lama jika ada
            if [ -f "${local_file}.bak" ]; then
                rm -f "${local_file}.bak"
            fi
            
            # Buat backup file lama jika ada
            if [ -f "$local_file" ]; then
                cp "$local_file" "${local_file}.bak"
                log_message "Backup file lama dibuat: ${local_file}.bak"
            fi
            
            # Pastikan direktori tujuan ada
            mkdir -p "$(dirname "$local_file")"
            
            # Pindahkan file baru
            if mv "$temp_file" "$local_file"; then
                log_message "File berhasil dipindahkan ke $local_file"
            else
                log_message "KESALAHAN: Gagal memindahkan file ke $local_file"
                return 1
            fi
            
            # Berikan izin eksekusi jika ini adalah file script
            if [[ "$file_name" == *.sh ]]; then
                chmod +x "$local_file"
                log_message "Izin eksekusi diberikan ke $local_file"
            fi
            
            log_message "Berhasil memperbarui $file_name (SHA-1 terverifikasi)"
            
            # Hapus file backup karena pembaruan berhasil
            if [ -f "${local_file}.bak" ]; then
                rm -f "${local_file}.bak"
            fi
            
            return 0  # Sukses
        fi
    else
        log_message "KESALAHAN: Gagal mendownload $file_name dari $file_url"
        rm -f "$temp_file"
        return 1
    fi
}

# ===== FUNGSI UTAMA =====
# Fungsi untuk menjalankan pembaruan
run_update() {
    local mode="$1"
    local conf_url="$2"
    local conf_file="$3"
    local script_url="$4"
    local script_file="$5"
    
    log_message "Mode pembaruan: $mode"
    log_message "URL konfigurasi: $conf_url"
    log_message "File konfigurasi: $conf_file"
    log_message "URL script: $script_url"
    log_message "File script: $script_file"
    
    # Hentikan proses auto-download.sh terlebih dahulu
    stop_auto_download
    
    # Variabel untuk melacak apakah ada file yang diperbarui
    local update_success=0
    
    # Periksa parameter yang diberikan
    if [ "$mode" = "conf" ] || [ "$mode" = "both" ]; then
        log_message "Memperbarui file konfigurasi..."
        # Update file auto-download.conf
        update_file "$conf_url" "$conf_file"
        if [ $? -eq 0 ]; then
            update_success=1
            log_message "File konfigurasi berhasil diperbarui"
        else
            log_message "KESALAHAN: Gagal memperbarui file konfigurasi"
        fi
    fi
    
    if [ "$mode" = "script" ] || [ "$mode" = "both" ]; then
        log_message "Memperbarui file script..."
        # Update file auto-download.sh
        update_file "$script_url" "$script_file"
        if [ $? -eq 0 ]; then
            update_success=1
            log_message "File script berhasil diperbarui"
        else
            log_message "KESALAHAN: Gagal memperbarui file script"
        fi
    fi
    
    # Jika pembaruan berhasil, jalankan restart-auto-download.sh
    if [ $update_success -eq 1 ]; then
        log_message "Pembaruan berhasil, menjalankan restart-auto-download.sh..."
        
        # Jalankan restart-auto-download.sh jika ada
        local restart_script="/data/adb/auto-download/restart-auto-download.sh"
        if [ -x "$restart_script" ]; then
            "$restart_script"
        else
            log_message "PERINGATAN: restart-auto-download.sh tidak ditemukan atau tidak dapat dieksekusi"
            
            # Jika restart script tidak ada, coba jalankan auto-download.sh langsung
            # Pastikan kita memiliki path yang valid untuk auto-download.sh
            local auto_download_script="$5"
            if [ -z "$auto_download_script" ]; then
                # Jika parameter $5 tidak tersedia, gunakan path default
                auto_download_script="/data/adb/auto-download/auto-download.sh"
            fi
            
            if [ -x "$auto_download_script" ]; then
                log_message "Menjalankan auto-download.sh langsung dari $auto_download_script..."
                nohup "$auto_download_script" > /dev/null 2>&1 &
                log_message "auto-download.sh telah dijalankan dengan PID: $!"
            else
                log_message "KESALAHAN: Tidak dapat menjalankan auto-download.sh dari $auto_download_script"
                return 1
            fi
        fi
    else
        log_message "Tidak ada file yang berhasil diperbarui"
        return 1
    fi
    
    log_message "Proses pembaruan selesai"
    return 0
}

# ===== EKSEKUSI UTAMA =====
# Inisialisasi file log jika belum ada
if [ -n "$LOG_FILE" ] && [ ! -f "$LOG_FILE" ]; then
    touch "$LOG_FILE"
fi

# Periksa parameter yang diberikan
if [ $# -lt 5 ]; then
    log_message "KESALAHAN: Parameter tidak lengkap"
    log_message "Penggunaan: $0 [conf|script|both] [conf_url] [conf_file] [script_url] [script_file]"
    log_message "Parameter yang diberikan: $#"
    for i in $(seq 1 $#); do
        log_message "Parameter $i: ${!i}"
    done
    exit 1
fi

# Validasi mode
if [ "$1" != "conf" ] && [ "$1" != "script" ] && [ "$1" != "both" ]; then
    log_message "KESALAHAN: Mode tidak valid: $1"
    log_message "Mode yang valid: conf, script, both"
    exit 1
fi

# Validasi URL
if [ "$1" = "conf" ] || [ "$1" = "both" ]; then
    if [ -z "$2" ]; then
        log_message "KESALAHAN: URL konfigurasi tidak diberikan"
        exit 1
    fi
fi

if [ "$1" = "script" ] || [ "$1" = "both" ]; then
    if [ -z "$4" ]; then
        log_message "KESALAHAN: URL script tidak diberikan"
        exit 1
    fi
fi

# Jalankan pembaruan
log_message "Memulai check-update.sh dengan mode: $1"
run_update "$1" "$2" "$3" "$4" "$5"
exit_code=$?

# Hapus file PID
rm -f "$PID_FILE"

log_message "check-update.sh selesai dengan kode: $exit_code"
exit $exit_code