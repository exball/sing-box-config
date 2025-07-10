#!/bin/sh

# Script untuk me-restart auto-download.sh
# Gunakan: sh restart-auto-download.sh


# Path ke script auto-download.sh
SCRIPT_PATH="/data/adb/auto-download/auto-download.sh"

# Path ke file PID
PID_FILE="/data/adb/auto-download/auto-download.pid"

# Path ke file boot.log
BOOT_LOG_FILE="/data/adb/auto-download/boot.log"

# Hapus file boot.log jika ada untuk mencegah deteksi mode boot yang salah
if [ -f "$BOOT_LOG_FILE" ]; then
    echo "Menghapus file boot.log untuk mencegah deteksi mode boot yang salah..."
    rm -f "$BOOT_LOG_FILE"
    if [ ! -f "$BOOT_LOG_FILE" ]; then
        echo "File boot.log berhasil dihapus"
    else
        echo "PERINGATAN: Gagal menghapus file boot.log"
    fi
fi

# Cek apakah ini adalah restart otomatis dari update SEBELUM meng-kill proses
AUTO_UPDATE_RESTART_FLAG="/data/adb/auto-download/auto_update_restart_flag"
IS_AUTO_UPDATE_RESTART=0

if [ -f "$AUTO_UPDATE_RESTART_FLAG" ]; then
    FLAG_TIME=$(cat "$AUTO_UPDATE_RESTART_FLAG")
    CURRENT_TIME=$(date +%s)
    TIME_DIFF=$((CURRENT_TIME - FLAG_TIME))
    
    # Jika file penanda dibuat dalam 10 detik terakhir, anggap restart otomatis
    if [ $TIME_DIFF -le 10 ]; then
        IS_AUTO_UPDATE_RESTART=1
        rm -f "$AUTO_UPDATE_RESTART_FLAG"
        echo "Detected seamless restart from auto-update"
    fi
fi

if [ $IS_AUTO_UPDATE_RESTART -eq 1 ]; then
    echo "Seamless restart mode: Proses lama akan exit dengan graceful"
    echo "Tidak perlu meng-kill proses lama secara paksa"
else
    echo "Memeriksa apakah script auto-download.sh sedang berjalan..."
fi

# Cek apakah file PID ada (hanya untuk restart manual)
if [ $IS_AUTO_UPDATE_RESTART -eq 0 ] && [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    echo "PID lama ditemukan: $OLD_PID"
    
    # Cek apakah proses dengan PID tersebut masih berjalan
    if kill -0 "$OLD_PID" 2>/dev/null; then
        echo "Menghentikan proses auto-download.sh dengan PID $OLD_PID..."
        kill "$OLD_PID"
        
        # Tunggu beberapa detik untuk memastikan proses benar-benar berhenti
        sleep 3
        
        # Periksa lagi apakah proses masih berjalan
        if kill -0 "$OLD_PID" 2>/dev/null; then
            echo "Proses masih berjalan, mencoba menghentikan paksa..."
            kill -9 "$OLD_PID"
            sleep 2
        fi
    else
        echo "Tidak ada proses yang berjalan dengan PID $OLD_PID"
    fi
elif [ $IS_AUTO_UPDATE_RESTART -eq 0 ]; then
    echo "File PID tidak ditemukan"
    
    # Cari PID menggunakan ps
    OLD_PID=$(ps -ef | grep "[a]uto-download.sh" | grep -v restart | head -1 | awk '{print $2}')
    
    if [ -n "$OLD_PID" ] && [ "$OLD_PID" -eq "$OLD_PID" ] 2>/dev/null; then
        echo "Menemukan proses auto-download.sh dengan PID $OLD_PID"
        echo "Menghentikan proses..."
        kill "$OLD_PID"
        sleep 3
        
        # Periksa lagi apakah proses masih berjalan
        if kill -0 "$OLD_PID" 2>/dev/null; then
            echo "Proses masih berjalan, mencoba menghentikan paksa..."
            kill -9 "$OLD_PID"
            sleep 2
        fi
    fi
fi

# Periksa sekali lagi apakah ada proses yang masih berjalan (hanya untuk restart manual)
if [ $IS_AUTO_UPDATE_RESTART -eq 0 ]; then
    RUNNING_PID=$(ps -ef | grep "[a]uto-download.sh" | grep -v restart | head -1 | awk '{print $2}')
    if [ -n "$RUNNING_PID" ] && [ "$RUNNING_PID" -eq "$RUNNING_PID" ] 2>/dev/null; then
        echo "PERINGATAN: Proses auto-download.sh masih berjalan dengan PID $RUNNING_PID"
        echo "Mencoba menghentikan paksa..."
        kill -9 $RUNNING_PID
        sleep 2
    fi
fi

# Buat file penanda untuk menandakan script dijalankan oleh restart-auto-download.sh
RESTART_FLAG_FILE="/data/adb/auto-download/restart_flag"
echo "$(date +%s)" > "$RESTART_FLAG_FILE"

# Jalankan script baru
echo "Memulai script auto-download.sh yang baru..."

# Cek apakah dijalankan dari terminal (interactive mode)
if [ -t 0 ] && [ -t 1 ]; then
    # Mode interaktif
    if [ $IS_AUTO_UPDATE_RESTART -eq 1 ]; then
        # Restart otomatis dari update - tidak perlu kill proses lama karena sudah exit gracefully
        echo "Seamless restart karena ada pembaruan script..."
        echo "Proses lama sudah exit dengan graceful, memulai proses baru..."
        
        nohup sh "$SCRIPT_PATH" > /dev/null 2>&1 &
        
        # Tunggu sebentar untuk memastikan script berjalan
        sleep 3
        
        # Periksa apakah script berjalan
        NEW_PID=$(ps -ef | grep "[a]uto-download.sh" | grep -v restart | head -1 | awk '{print $2}')
        if [ -n "$NEW_PID" ] && [ "$NEW_PID" -eq "$NEW_PID" ] 2>/dev/null; then
            echo "Script auto-download.sh berhasil di-restart dengan PID $NEW_PID"
            echo "Melanjutkan monitoring log..."
            echo ""
            
            # Tunggu sebentar agar auto-download.sh mulai menulis log
            sleep 3
            
            # Lanjutkan monitoring log tanpa menghentikan proses yang ada
            LOG_FILE="/data/adb/auto-download/auto-download.log"
            if [ -f "$LOG_FILE" ]; then
                # Gunakan exec untuk mengganti proses saat ini dengan tail -f
                # Ini memastikan monitoring tidak terputus
                exec tail -f "$LOG_FILE"
            else
                echo "Log file tidak ditemukan: $LOG_FILE"
                echo "Menunggu log file dibuat..."
                # Tunggu hingga log file dibuat (maksimal 30 detik)
                local wait_count=0
                while [ ! -f "$LOG_FILE" ] && [ $wait_count -lt 30 ]; do
                    sleep 1
                    wait_count=$((wait_count + 1))
                done
                
                if [ -f "$LOG_FILE" ]; then
                    exec tail -f "$LOG_FILE"
                else
                    echo "Log file tidak dibuat dalam 30 detik"
                fi
            fi
        else
            echo "PERINGATAN: Script auto-download.sh gagal dijalankan"
            echo "Proses restart selesai"
        fi
    else
        # Restart manual dari terminal - tampilkan output seperti biasa
        nohup sh "$SCRIPT_PATH" > /dev/null 2>&1 &
        
        # Tunggu sebentar untuk memastikan script berjalan
        sleep 2
        
        # Periksa apakah script berjalan
        NEW_PID=$(ps -ef | grep "[a]uto-download.sh" | grep -v restart | head -1 | awk '{print $2}')
        if [ -n "$NEW_PID" ] && [ "$NEW_PID" -eq "$NEW_PID" ] 2>/dev/null; then
            echo "Script auto-download.sh berhasil dijalankan dengan PID $NEW_PID"
            echo "Proses restart selesai"
            echo ""
            echo "=== Output dari auto-download.sh ==="
            
            # Tunggu sebentar agar auto-download.sh mulai menulis log
            sleep 3
            
            # Tampilkan output dari log file secara real-time
            LOG_FILE="/data/adb/auto-download/auto-download.log"
            if [ -f "$LOG_FILE" ]; then
                tail -f "$LOG_FILE"
            else
                echo "Log file tidak ditemukan: $LOG_FILE"
                echo "Menunggu log file dibuat..."
                # Tunggu hingga log file dibuat (maksimal 30 detik)
                local wait_count=0
                while [ ! -f "$LOG_FILE" ] && [ $wait_count -lt 30 ]; do
                    sleep 1
                    wait_count=$((wait_count + 1))
                done
                
                if [ -f "$LOG_FILE" ]; then
                    tail -f "$LOG_FILE"
                else
                    echo "Log file tidak dibuat dalam 30 detik"
                fi
            fi
        else
            echo "PERINGATAN: Script auto-download.sh gagal dijalankan"
            echo "Proses restart selesai"
        fi
    fi
else
    # Mode non-interaktif - jalankan seperti biasa tanpa menampilkan output
    nohup sh "$SCRIPT_PATH" > /dev/null 2>&1 &
    
    # Tunggu sebentar untuk memastikan script berjalan
    sleep 2
    
    # Periksa apakah script berjalan
    NEW_PID=$(ps -ef | grep "[a]uto-download.sh" | grep -v restart | head -1 | awk '{print $2}')
    if [ -n "$NEW_PID" ] && [ "$NEW_PID" -eq "$NEW_PID" ] 2>/dev/null; then
        echo "Script auto-download.sh berhasil dijalankan dengan PID $NEW_PID"
    else
        echo "PERINGATAN: Script auto-download.sh gagal dijalankan"
    fi
    
    echo "Proses restart selesai"
fi