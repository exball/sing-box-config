#!/bin/bash

# Script untuk mendownload file konfigurasi secara otomatis
# Dengan fitur pemeriksaan hash SHA-1 untuk menghindari download ulang
# Versi dengan CHECK_INTERVAL adaptif dan pembaruan auto-download.conf

# ===== KONFIGURASI BOOTSTRAP =====
# Parameter minimal yang diperlukan untuk memeriksa pembaruan konfigurasi
# Parameter ini TIDAK BOLEH diubah melalui file konfigurasi eksternal
CONF_UPDATE_URL="https://raw.githubusercontent.com/exball/sing-box-config/refs/heads/Master/auto-download.conf"
SCRIPT_UPDATE_URL="https://raw.githubusercontent.com/exball/sing-box-config/refs/heads/Master/auto-download.sh"
CHECK_UPDATE_SCRIPT_URL="https://raw.githubusercontent.com/exball/sing-box-config/refs/heads/Master/check-update.sh"
CONFIG_FILE="/data/adb/auto-download/auto-download.conf"
SCRIPT_FILE="/data/adb/auto-download/auto-download.sh"
CHECK_UPDATE_SCRIPT="/data/adb/auto-download/check-update.sh"
TEMP_DIR="/data/adb/auto-download/download_temp"
NETWORK_TEST_URL="https://www.google.com"
NETWORK_MAX_ATTEMPTS=15
NETWORK_RETRY_WAIT=3
LOG_FILE="/data/adb/auto-download/auto-download.log"
OLD_LOG_FILE="/data/adb/auto-download/auto-download_old.log"

# File PID untuk melacak proses yang sedang berjalan
PID_FILE="/data/adb/auto-download/auto-download.pid"

# Variabel untuk melacak apakah header timestamp sudah ditulis
TIMESTAMP_HEADER_WRITTEN=0

# Variabel untuk menyimpan interval terakhir
LAST_INTERVAL=0

# Variabel untuk melacak jadwal terakhir yang dijalankan
LAST_EXECUTED_SCHEDULE=""
LAST_SCHEDULE_TIME=0

# Variabel untuk melacak apakah ada file yang diperbarui
files_updated=0

# ===== FUNGSI UTILITAS =====

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
        # Coba gunakan sha1sum jika tersedia
        if command -v sha1sum > /dev/null 2>&1; then
            sha1sum "$file" | awk '{print $1}'
        # Jika tidak, coba gunakan busybox sha1sum
        elif command -v busybox > /dev/null 2>&1; then
            busybox sha1sum "$file" | awk '{print $1}'
        # Jika tidak ada yang tersedia, gunakan metode alternatif
        else
            log_message "PERINGATAN: sha1sum tidak tersedia, menggunakan md5sum sebagai alternatif"
            if command -v md5sum > /dev/null 2>&1; then
                md5sum "$file" | awk '{print $1}'
            elif command -v busybox > /dev/null 2>&1; then
                busybox md5sum "$file" | awk '{print $1}'
            else
                log_message "KESALAHAN: Tidak ada metode hash yang tersedia"
                echo ""
            fi
        fi
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

# Fungsi untuk rotasi log
rotate_log() {
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
        
        log_message "Rotasi log selesai"
    fi
}

# Pastikan direktori yang diperlukan ada
mkdir -p /data/adb/auto-download
mkdir -p "$TEMP_DIR"
mkdir -p "$(dirname "$LOG_FILE")"

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

# Pastikan direktori penyimpanan dan temp ada setelah memuat konfigurasi
if [ -n "$SAVE_DIR" ]; then
    mkdir -p "$SAVE_DIR"
fi

if [ -n "$CONFIG_DIR" ]; then
    mkdir -p "$CONFIG_DIR"
fi

# Fungsi untuk mendapatkan hash SHA-1 dari URL raw GitHub
get_github_sha1() {
    local raw_url="$1"
    
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

# Fungsi untuk memeriksa file
check_file_hash() {
    local file_url="$1"
    local local_file="$2"
    local file_name=$(basename "$local_file")
    
    # Validasi parameter
    if [ -z "$file_url" ]; then
        log_message "KESALAHAN: URL file tidak diberikan untuk pemeriksaan hash"
        return 1
    fi
    
    if [ -z "$local_file" ]; then
        log_message "KESALAHAN: Path file lokal tidak diberikan untuk pemeriksaan hash"
        return 1
    fi
    
    log_message "-----"
    log_message "Memeriksa hash SHA-1 $file_name..."
    log_message "URL: $file_url"
    log_message "File lokal: $local_file"
    
    # Nama file sementara untuk download
    local temp_file="$TEMP_DIR/${file_name}.hash"
    
    # Download file dari URL raw GitHub untuk mendapatkan hash
    log_message "Mendownload file untuk pemeriksaan hash..."
    if curl -s -L --connect-timeout 10 --max-time 30 "$file_url" -o "$temp_file"; then
        # Periksa apakah file berhasil didownload dan tidak kosong
        if [ ! -s "$temp_file" ]; then
            log_message "KESALAHAN: File yang didownload kosong"
            rm -f "$temp_file"
            return 1
        fi
        
        # Periksa apakah file yang didownload adalah file teks yang valid
        if grep -q "<!DOCTYPE html>" "$temp_file" || grep -q "<html>" "$temp_file"; then
            log_message "KESALAHAN: File yang didownload tampaknya berisi HTML, bukan konten yang diharapkan"
            head -n 10 "$temp_file" | while read line; do
                log_message "  $line"
            done
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
            
            # Dapatkan hash SHA-1 dari file lokal jika ada
            local local_sha1=""
            if [ -f "$local_file" ]; then
                local_sha1=$(get_local_sha1 "$local_file")
                log_message "SHA-1 lokal $file_name: $local_sha1"
            else
                log_message "File lokal $file_name tidak ditemukan"
            fi
            
            # Bandingkan hash SHA-1
            if [ -n "$local_sha1" ] && [ "$local_sha1" = "$github_sha1" ]; then
                log_message "SHA-1 $file_name sama, tidak perlu diperbarui"
                rm -f "$temp_file"
                return 0  # Sama
            else
                log_message "SHA-1 $file_name berbeda atau file tidak ada, perlu diperbarui"
                rm -f "$temp_file"
                return 2  # Berbeda
            fi
        fi
    else
        log_message "KESALAHAN: Gagal mendownload $file_name dari $file_url untuk pemeriksaan hash"
        rm -f "$temp_file"
        return 1  # Error
    fi
}

# Fungsi untuk menjalankan check-update.sh
run_check_update() {
    local mode="$1"
    
    # Periksa apakah check-update.sh ada
    if [ ! -f "$CHECK_UPDATE_SCRIPT" ]; then
        log_message "KESALAHAN: $CHECK_UPDATE_SCRIPT tidak ditemukan"
        return 1
    fi
    
    # Pastikan check-update.sh memiliki izin eksekusi
    chmod 755 "$CHECK_UPDATE_SCRIPT"
    log_message "Izin eksekusi diberikan ke $CHECK_UPDATE_SCRIPT (chmod 755)"
    
    # Periksa apakah file benar-benar dapat dieksekusi
    if [ ! -x "$CHECK_UPDATE_SCRIPT" ]; then
        log_message "PERINGATAN: $CHECK_UPDATE_SCRIPT masih tidak dapat dieksekusi setelah chmod 755"
        # Coba cara lain
        busybox chmod +x "$CHECK_UPDATE_SCRIPT"
        log_message "Mencoba dengan busybox chmod +x"
    fi
    
    log_message "Menjalankan $CHECK_UPDATE_SCRIPT dengan mode: $mode"
    
    # Jalankan check-update.sh dengan parameter yang sesuai
    # Parameter: [mode] [conf_url] [conf_file] [script_url] [script_file]
    log_message "Menjalankan: sh $CHECK_UPDATE_SCRIPT $mode $CONF_UPDATE_URL $CONFIG_FILE $SCRIPT_UPDATE_URL $SCRIPT_FILE"
    sh "$CHECK_UPDATE_SCRIPT" "$mode" "$CONF_UPDATE_URL" "$CONFIG_FILE" "$SCRIPT_UPDATE_URL" "$SCRIPT_FILE"
    local result=$?
    
    if [ $result -ne 0 ]; then
        # Script ini akan mencapai baris berikutnya jika check-update.sh gagal
        log_message "PERINGATAN: check-update.sh gagal menjalankan pembaruan (kode: $result)"
        return 1
    else
        log_message "check-update.sh berhasil menjalankan pembaruan"
        return 0
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
    
    # Periksa file check-update.sh paling awal
    log_message "-----"
    log_message "Memeriksa file check-update.sh..."
    
    # Periksa apakah check-update.sh ada dan dapat dieksekusi
    local check_update_needs_update=0
    
    if [ ! -f "$CHECK_UPDATE_SCRIPT" ]; then
        log_message "File check-update.sh tidak ditemukan, akan didownload"
        check_update_needs_update=1
    else
        # Pastikan check-update.sh memiliki izin eksekusi
        chmod +x "$CHECK_UPDATE_SCRIPT"
        
        # Periksa hash check-update.sh
        check_file_hash "$CHECK_UPDATE_SCRIPT_URL" "$CHECK_UPDATE_SCRIPT"
        local check_update_result=$?
        
        if [ $check_update_result -eq 2 ]; then
            check_update_needs_update=1
            log_message "File check-update.sh perlu diperbarui"
        elif [ $check_update_result -eq 0 ]; then
            log_message "File check-update.sh tidak perlu diperbarui"
        else
            log_message "Gagal memeriksa file check-update.sh"
            # Jika gagal memeriksa, coba download ulang
            check_update_needs_update=1
        fi
    fi
    
    # Jika check-update.sh perlu diperbarui, download langsung
    if [ $check_update_needs_update -eq 1 ]; then
        log_message "Mendownload file check-update.sh yang baru..."
        
        # Nama file sementara untuk download
        local temp_check_update_file="$TEMP_DIR/check-update.sh.new"
        
        # Download file dari URL dengan lebih banyak informasi
        log_message "Mendownload dari URL: $CHECK_UPDATE_SCRIPT_URL"
        if curl -v -L --connect-timeout 10 --max-time 30 "$CHECK_UPDATE_SCRIPT_URL" -o "$temp_check_update_file" 2>&1 | grep -q "200 OK"; then
            # Periksa apakah file berhasil didownload dan tidak kosong
            if [ -s "$temp_check_update_file" ]; then
                log_message "File berhasil didownload (ukuran: $(du -h "$temp_check_update_file" | cut -f1))"
                
                # Periksa apakah file yang didownload adalah file teks yang valid
                if grep -q "<!DOCTYPE html>" "$temp_check_update_file" || grep -q "<html>" "$temp_check_update_file"; then
                    log_message "KESALAHAN: File yang didownload tampaknya berisi HTML, bukan konten yang diharapkan"
                    head -n 10 "$temp_check_update_file" | while read line; do
                        log_message "  $line"
                    done
                    rm -f "$temp_check_update_file"
                    return 1
                fi
                
                # Hapus backup lama jika ada
                if [ -f "${CHECK_UPDATE_SCRIPT}.bak" ]; then
                    rm -f "${CHECK_UPDATE_SCRIPT}.bak"
                fi
                
                # Buat backup file lama jika ada
                if [ -f "$CHECK_UPDATE_SCRIPT" ]; then
                    cp "$CHECK_UPDATE_SCRIPT" "${CHECK_UPDATE_SCRIPT}.bak"
                    log_message "Backup file lama dibuat: ${CHECK_UPDATE_SCRIPT}.bak"
                fi
                
                # Pastikan direktori tujuan ada
                mkdir -p "$(dirname "$CHECK_UPDATE_SCRIPT")"
                
                # Pindahkan file baru
                if mv "$temp_check_update_file" "$CHECK_UPDATE_SCRIPT"; then
                    log_message "File berhasil dipindahkan ke $CHECK_UPDATE_SCRIPT"
                else
                    log_message "KESALAHAN: Gagal memindahkan file ke $CHECK_UPDATE_SCRIPT"
                    return 1
                fi
                
                # Berikan izin eksekusi
                chmod 755 "$CHECK_UPDATE_SCRIPT"
                log_message "Izin eksekusi diberikan ke $CHECK_UPDATE_SCRIPT (chmod 755)"
                
                # Periksa apakah file benar-benar dapat dieksekusi
                if [ ! -x "$CHECK_UPDATE_SCRIPT" ]; then
                    log_message "PERINGATAN: $CHECK_UPDATE_SCRIPT masih tidak dapat dieksekusi setelah chmod 755"
                    # Coba cara lain
                    busybox chmod +x "$CHECK_UPDATE_SCRIPT"
                    log_message "Mencoba dengan busybox chmod +x"
                fi
                
                log_message "Berhasil memperbarui check-update.sh"
                
                # Hapus file backup karena pembaruan berhasil
                if [ -f "${CHECK_UPDATE_SCRIPT}.bak" ]; then
                    rm -f "${CHECK_UPDATE_SCRIPT}.bak"
                fi
            else
                log_message "KESALAHAN: File yang didownload kosong"
                rm -f "$temp_check_update_file"
                return 1
            fi
        else
            log_message "KESALAHAN: Gagal mendownload check-update.sh dari $CHECK_UPDATE_SCRIPT_URL"
            rm -f "$temp_check_update_file"
        fi
    fi
    
    # Variabel untuk melacak status pemeriksaan
    local conf_needs_update=0
    local script_needs_update=0
    
    # Periksa file auto-download.conf
    log_message "-----"
    log_message "Memeriksa file auto-download.conf..."
    
    # Validasi URL konfigurasi
    if [ -z "$CONF_UPDATE_URL" ]; then
        log_message "KESALAHAN: URL konfigurasi tidak dikonfigurasi"
    else
        check_file_hash "$CONF_UPDATE_URL" "$CONFIG_FILE"
        local conf_result=$?
        
        if [ $conf_result -eq 2 ]; then
            conf_needs_update=1
            log_message "File auto-download.conf perlu diperbarui"
        elif [ $conf_result -eq 0 ]; then
            log_message "File auto-download.conf tidak perlu diperbarui"
        else
            log_message "Gagal memeriksa file auto-download.conf"
        fi
    fi
    
    # Periksa file auto-download.sh
    log_message "-----"
    log_message "Memeriksa file auto-download.sh..."
    
    # Validasi URL script
    if [ -z "$SCRIPT_UPDATE_URL" ]; then
        log_message "KESALAHAN: URL script tidak dikonfigurasi"
    else
        check_file_hash "$SCRIPT_UPDATE_URL" "$SCRIPT_FILE"
        local script_result=$?
        
        if [ $script_result -eq 2 ]; then
            script_needs_update=1
            log_message "File auto-download.sh perlu diperbarui"
        elif [ $script_result -eq 0 ]; then
            log_message "File auto-download.sh tidak perlu diperbarui"
        else
            log_message "Gagal memeriksa file auto-download.sh"
        fi
    fi
    
    # Jika salah satu file perlu diperbarui, jalankan check-update.sh
    if [ $conf_needs_update -eq 1 ] && [ $script_needs_update -eq 1 ]; then
        log_message "Kedua file perlu diperbarui, menjalankan check-update.sh..."
        
        # Validasi URL
        if [ -z "$CONF_UPDATE_URL" ] || [ -z "$SCRIPT_UPDATE_URL" ]; then
            log_message "KESALAHAN: URL konfigurasi atau script tidak dikonfigurasi"
            return 1
        fi
        
        run_check_update "both"
        return $?
    elif [ $conf_needs_update -eq 1 ]; then
        log_message "File auto-download.conf perlu diperbarui, menjalankan check-update.sh..."
        
        # Validasi URL
        if [ -z "$CONF_UPDATE_URL" ]; then
            log_message "KESALAHAN: URL konfigurasi tidak dikonfigurasi"
            return 1
        fi
        
        run_check_update "conf"
        return $?
    elif [ $script_needs_update -eq 1 ]; then
        log_message "File auto-download.sh perlu diperbarui, menjalankan check-update.sh..."
        
        # Validasi URL
        if [ -z "$SCRIPT_UPDATE_URL" ]; then
            log_message "KESALAHAN: URL script tidak dikonfigurasi"
            return 1
        fi
        
        run_check_update "script"
        return $?
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
        rotate_log
        log_message "Rotasi log selesai pada waktu terjadwal: $current_time"
        
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

# Fungsi untuk menghitung detik ke jadwal berikutnya
calculate_next_schedule_seconds() {
    local return_schedule_time=$1  # 1 jika perlu mengembalikan waktu jadwal, 0 jika tidak
    
    # Dapatkan waktu saat ini dalam detik sejak tengah malam
    local current_seconds=$(($(date +%H) * 3600 + $(date +%M) * 60 + $(date +%S)))
    
    # Inisialisasi waktu ke jadwal berikutnya
    local next_seconds=86400  # Default ke 24 jam (tidak ada jadwal dalam 24 jam)
    local next_time=""
    
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
            if [ $diff_seconds -lt $next_seconds ]; then
                next_seconds=$diff_seconds
                next_time=$schedule_time
            fi
        fi
    done
    
    # Jika tidak ada jadwal yang ditemukan untuk hari ini, cari jadwal pertama untuk besok
    if [ $next_seconds -eq 86400 ]; then
        for schedule_time in $SCHEDULE_HOURS; do
            local hour=$(echo $schedule_time | cut -d: -f1)
            local minute=$(echo $schedule_time | cut -d: -f2)
            local schedule_seconds=$((hour * 3600 + minute * 60))
            
            # Jadwal untuk besok = jadwal + (24 jam - waktu saat ini)
            local diff_seconds=$((schedule_seconds + 86400 - current_seconds))
            if [ $diff_seconds -lt $next_seconds ]; then
                next_seconds=$diff_seconds
                next_time=$schedule_time
            fi
        done
    fi
    
    # Kembalikan hasil sesuai parameter
    if [ $return_schedule_time -eq 1 ]; then
        echo "$next_seconds $next_time"
    else
        echo "$next_seconds"
    fi
}

# Fungsi untuk mendapatkan informasi jadwal berikutnya
get_next_schedule_info() {
    # Dapatkan detik dan waktu jadwal berikutnya
    local result=$(calculate_next_schedule_seconds 1)
    local next_schedule_seconds=$(echo $result | cut -d' ' -f1)
    local next_schedule_time=$(echo $result | cut -d' ' -f2)
    
    # Konversi detik ke format jam dan menit untuk tampilan yang lebih mudah dibaca
    local next_hours=$((next_schedule_seconds / 3600))
    local next_minutes=$(((next_schedule_seconds % 3600) / 60))
    
    # Kembalikan informasi jadwal berikutnya
    echo "Jadwal berikutnya: $next_schedule_time (dalam $next_hours jam $next_minutes menit)"
}

# Fungsi untuk menghitung interval adaptif berdasarkan waktu ke jadwal berikutnya
calculate_adaptive_interval() {
    # Dapatkan detik ke jadwal berikutnya
    local next_schedule_seconds=$(calculate_next_schedule_seconds 0)
    
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
    # Rotasi file log
    rotate_log
    
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
rotate_log

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