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
NETWORK_MAX_ATTEMPTS=15
NETWORK_RETRY_WAIT=3

# File log
LOG_FILE="/data/adb/auto-download/check-update.log"

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
    
    # Jika file diperbarui, kembalikan kode 10 terlebih dahulu, kemudian jalankan restart-auto-download.sh
    if [ $files_updated -eq 1 ]; then
        log_message "File auto-download.sh telah diperbarui, perlu me-restart layanan"
        
        # Path ke script restart-auto-download.sh dari auto-download.sh
        # Jika tidak ada, gunakan path default
        RESTART_SCRIPT="${RESTART_SCRIPT_FILE:-/data/adb/auto-download/restart-auto-download.sh}"
        
        # Periksa apakah script restart ada
        if [ -f "$RESTART_SCRIPT" ]; then
            # Pastikan file memiliki izin eksekusi
            chmod +x "$RESTART_SCRIPT"
            
            # Buat script sementara untuk menjalankan restart-auto-download.sh setelah beberapa detik
            TEMP_SCRIPT="/data/adb/auto-download/temp_restart.sh"
            
            # Buat script sementara
            cat > "$TEMP_SCRIPT" << EOF
#!/bin/bash
# Script sementara untuk menjalankan restart-auto-download.sh setelah beberapa detik
# Ini memastikan auto-download.sh memiliki waktu untuk keluar dengan bersih

# Tunggu beberapa detik untuk memastikan auto-download.sh telah keluar
sleep 3

# Jalankan restart-auto-download.sh
if [ -x "$RESTART_SCRIPT" ]; then
    "$RESTART_SCRIPT"
else
    sh "$RESTART_SCRIPT"
fi

# Hapus script sementara ini
rm -f "$TEMP_SCRIPT"
EOF
            
            # Berikan izin eksekusi ke script sementara
            chmod +x "$TEMP_SCRIPT"
            
            # Jalankan script sementara di background
            log_message "Menjadwalkan restart-auto-download.sh untuk dijalankan setelah auto-download.sh keluar..."
            nohup "$TEMP_SCRIPT" > /dev/null 2>&1 &
            
            log_message "Proses pemeriksaan selesai dengan pembaruan"
            
            # Kembalikan kode 10 untuk menandakan auto-download.sh telah diperbarui
            # restart-auto-download.sh akan dijalankan setelah auto-download.sh keluar
            return 10
        else
            # Jika script restart tidak ada, lakukan restart manual
            log_message "Script restart-auto-download.sh tidak ditemukan, mencoba restart manual..."
            
            # Buat script sementara untuk restart manual
            TEMP_SCRIPT="/data/adb/auto-download/temp_manual_restart.sh"
            
            # Buat script sementara
            cat > "$TEMP_SCRIPT" << EOF
#!/bin/bash
# Script sementara untuk restart manual setelah beberapa detik
# Ini memastikan auto-download.sh memiliki waktu untuk keluar dengan bersih

# Tunggu beberapa detik untuk memastikan auto-download.sh telah keluar
sleep 3

# Hentikan proses auto-download.sh yang mungkin masih berjalan
pkill -f "auto-download.sh"
sleep 2

# Jalankan kembali auto-download.sh
if [ -x "$SCRIPT_FILE" ]; then
    nohup "$SCRIPT_FILE" > /dev/null 2>&1 &
fi

# Hapus script sementara ini
rm -f "$TEMP_SCRIPT"
EOF
            
            # Berikan izin eksekusi ke script sementara
            chmod +x "$TEMP_SCRIPT"
            
            # Jalankan script sementara di background
            log_message "Menjadwalkan restart manual untuk dijalankan setelah auto-download.sh keluar..."
            nohup "$TEMP_SCRIPT" > /dev/null 2>&1 &
            
            log_message "Proses pemeriksaan selesai dengan pembaruan"
            return 10
        fi
    else
        log_message "Tidak ada file yang diperbarui"
        log_message "Proses pemeriksaan selesai tanpa pembaruan"
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

# Kode keluar:
# 0 = Tidak ada pembaruan atau pembaruan berhasil tanpa perlu restart
# 10 = auto-download.sh telah diperbarui dan restart-auto-download.sh telah dijalankan
# Kode lain = Error

exit $exit_code