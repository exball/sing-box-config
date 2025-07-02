#!/bin/sh
# Debug script untuk menganalisis masalah SHA-1 comparison

# ===== KONFIGURASI =====
SCRIPT_UPDATE_URL="https://raw.githubusercontent.com/exball/sing-box-config/refs/heads/Master/auto-download/auto-download.sh"
SCRIPT_FILE="/home/exball/Tunnel/sing-box-config/auto-download/auto-download.sh"
TEMP_DIR="/home/exball/Tunnel/sing-box-config/auto-download/temp"

# ===== FUNGSI HELPER =====
log_message() {
    message="$1"
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "$timestamp: $message"
}

get_local_sha1() {
    file="$1"
    if [ -f "$file" ]; then
        sha1sum "$file" | awk '{print $1}'
    else
        echo ""
    fi
}

curl_download_file() {
    source_url="$1"
    output_file="$2"
    timeout_connect="${3:-10}"
    timeout_max="${4:-30}"
    
    if [ -z "$source_url" ] || [ -z "$output_file" ]; then
        log_message "Error: URL sumber dan file output tidak boleh kosong"
        return 1
    fi
    
    # Pastikan direktori parent ada
    parent_dir=$(dirname "$output_file")
    if [ ! -d "$parent_dir" ]; then
        mkdir -p "$parent_dir"
    fi
    
    # Download file dengan follow redirects
    curl -s -L --connect-timeout "$timeout_connect" --max-time "$timeout_max" "$source_url" -o "$output_file"
    curl_exit_code=$?
    
    # Jika gagal, hapus file yang mungkin sudah dibuat (partial download)
    if [ $curl_exit_code -ne 0 ]; then
        rm -f "$output_file"
    fi
    
    return $curl_exit_code
}

download_and_get_sha1() {
    source_url="$1"
    temp_file_prefix="${2:-temp_sha1_file}"
    
    if [ -z "$source_url" ]; then
        log_message "Error: URL sumber tidak boleh kosong"
        return 1
    fi
    
    # Pastikan temp directory ada
    if [ ! -d "$TEMP_DIR" ]; then
        mkdir -p "$TEMP_DIR"
    fi
    
    # Buat temporary file
    temp_hash_file="$TEMP_DIR/${temp_file_prefix}"
    
    # Download file dari URL
    if curl_download_file "$source_url" "$temp_hash_file"; then
        # Hitung hash SHA-1 dari file yang didownload
        sha1=$(get_local_sha1 "$temp_hash_file")
        
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

# ===== FUNGSI DEBUG UTAMA =====
debug_sha1_comparison() {
    log_message "===== DEBUG SHA-1 COMPARISON ====="
    log_message "URL: $SCRIPT_UPDATE_URL"
    log_message "Local File: $SCRIPT_FILE"
    log_message ""
    
    # 1. Periksa apakah file lokal ada
    if [ -f "$SCRIPT_FILE" ]; then
        log_message "✓ File lokal ditemukan: $SCRIPT_FILE"
        
        # Dapatkan SHA-1 file lokal
        local_sha1=$(get_local_sha1 "$SCRIPT_FILE")
        log_message "SHA-1 lokal: $local_sha1"
        
        # Dapatkan ukuran file lokal
        local_size=$(wc -c < "$SCRIPT_FILE" 2>/dev/null || echo "unknown")
        log_message "Ukuran file lokal: $local_size bytes"
        
        # Dapatkan timestamp file lokal
        local_timestamp=$(ls -l "$SCRIPT_FILE" | awk '{print $6, $7, $8}')
        log_message "Timestamp file lokal: $local_timestamp"
    else
        log_message "✗ File lokal tidak ditemukan: $SCRIPT_FILE"
        local_sha1=""
    fi
    
    log_message ""
    
    # 2. Download file dari GitHub dan hitung SHA-1
    log_message "Mendownload file dari GitHub untuk perbandingan..."
    github_sha1=$(download_and_get_sha1 "$SCRIPT_UPDATE_URL" "debug_github_file")
    
    if [ -n "$github_sha1" ]; then
        log_message "✓ Berhasil mendownload dari GitHub"
        log_message "SHA-1 GitHub: $github_sha1"
        
        # Download sekali lagi untuk mendapatkan ukuran file
        temp_github_file="$TEMP_DIR/debug_github_full"
        if curl_download_file "$SCRIPT_UPDATE_URL" "$temp_github_file"; then
            github_size=$(wc -c < "$temp_github_file" 2>/dev/null || echo "unknown")
            log_message "Ukuran file GitHub: $github_size bytes"
            rm -f "$temp_github_file"
        fi
    else
        log_message "✗ Gagal mendownload dari GitHub"
        return 1
    fi
    
    log_message ""
    
    # 3. Bandingkan SHA-1
    log_message "===== HASIL PERBANDINGAN ====="
    if [ -n "$local_sha1" ] && [ -n "$github_sha1" ]; then
        if [ "$local_sha1" = "$github_sha1" ]; then
            log_message "✓ SHA-1 SAMA - Tidak perlu update"
            log_message "  Local:  $local_sha1"
            log_message "  GitHub: $github_sha1"
        else
            log_message "✗ SHA-1 BERBEDA - Perlu update"
            log_message "  Local:  $local_sha1"
            log_message "  GitHub: $github_sha1"
        fi
    elif [ -z "$local_sha1" ]; then
        log_message "✗ File lokal tidak ada - Perlu download"
        log_message "  GitHub: $github_sha1"
    elif [ -z "$github_sha1" ]; then
        log_message "✗ Gagal mendapatkan SHA-1 dari GitHub"
        log_message "  Local:  $local_sha1"
    fi
    
    log_message ""
    
    # 4. Test koneksi ke URL
    log_message "===== TEST KONEKSI ====="
    log_message "Testing koneksi ke: $SCRIPT_UPDATE_URL"
    
    if curl -s -I --connect-timeout 10 --max-time 15 "$SCRIPT_UPDATE_URL" >/dev/null 2>&1; then
        log_message "✓ Koneksi ke GitHub berhasil"
        
        # Dapatkan HTTP response code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 --max-time 15 "$SCRIPT_UPDATE_URL")
        log_message "HTTP Response Code: $http_code"
        
        # Dapatkan content-length jika ada
        content_length=$(curl -s -I --connect-timeout 10 --max-time 15 "$SCRIPT_UPDATE_URL" | grep -i content-length | awk '{print $2}' | tr -d '\r')
        if [ -n "$content_length" ]; then
            log_message "Content-Length: $content_length bytes"
        fi
    else
        log_message "✗ Koneksi ke GitHub gagal"
    fi
    
    log_message ""
    log_message "===== DEBUG SELESAI ====="
}

# ===== JALANKAN DEBUG =====
debug_sha1_comparison