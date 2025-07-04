# Wakelock Monitor untuk auto-download.sh

## Deskripsi

Wakelock Monitor adalah solusi untuk mengatasi masalah timing yang tidak akurat pada `auto-download.sh` setelah perangkat bangun dari deep sleep. Saat perangkat masuk deep sleep, timer `sleep` dalam script juga ikut suspend, menyebabkan jadwal pemeriksaan menjadi tidak tepat.

## Cara Kerja

1. **Wakelock Monitor Service** berjalan di background dan memantau:
   - `/sys/power/wakeup_count` - untuk mendeteksi wake dari deep sleep
   - `/sys/power/wake_lock` - untuk mendeteksi perubahan wakelock

2. **Signal Communication**: Saat terdeteksi wake dari deep sleep, monitor mengirim signal `SIGUSR1` ke `auto-download.sh`

3. **Schedule Recalculation**: `auto-download.sh` menerima signal dan langsung menjalankan `check_schedule_and_run` untuk menghitung ulang jadwal

## File yang Dimodifikasi/Ditambahkan

### File Baru:
- `wakelock_monitor_autodownload.sh` - Monitor service utama
- `wakelock_autodownload_monitor.rc` - Init service configuration
- `install_wakelock_monitor.sh` - Script installer
- `uninstall_wakelock_monitor.sh` - Script uninstaller  
- `test_wakelock_monitor.sh` - Script testing

### File yang Dimodifikasi:
- `auto-download.sh` - Ditambahkan signal handler dan deep sleep wake processing

## Instalasi

### Persyaratan:
- Root access
- Akses ke `/system` partition
- Kernel yang mendukung `/sys/power/wakeup_count` dan `/sys/power/wake_lock`

### Langkah Instalasi:

1. **Jalankan installer sebagai root:**
   ```bash
   su -c './install_wakelock_monitor.sh'
   ```

2. **Reboot perangkat:**
   ```bash
   reboot
   ```

3. **Verifikasi instalasi:**
   ```bash
   ./test_wakelock_monitor.sh
   ```

## Testing

### Manual Testing:

1. **Cek status:**
   ```bash
   ./test_wakelock_monitor.sh
   # Pilih option 1: Show Status
   ```

2. **Test signal communication:**
   ```bash
   ./test_wakelock_monitor.sh
   # Pilih option 2: Test Signal Communication
   ```

3. **Monitor logs real-time:**
   ```bash
   ./test_wakelock_monitor.sh
   # Pilih option 3: Monitor Logs
   ```

4. **Simulate deep sleep test:**
   ```bash
   ./test_wakelock_monitor.sh
   # Pilih option 4: Simulate Deep Sleep Test
   ```

### Log Files:

- **auto-download.sh**: `/data/adb/auto-download/auto-download.log`
- **Wakelock Monitor**: `/data/adb/auto-download/wakelock_monitor.log`

## Troubleshooting

### Monitor tidak berjalan:

1. Cek apakah init service aktif:
   ```bash
   getprop init.svc.wakelock_autodownload_monitor
   ```

2. Cek log sistem:
   ```bash
   logcat | grep wakelock_autodownload_monitor
   ```

3. Cek apakah file monitoring tersedia:
   ```bash
   ls -la /sys/power/wakeup_count
   ls -la /sys/power/wake_lock
   ```

### Signal tidak diterima:

1. Cek PID file auto-download.sh:
   ```bash
   cat /data/adb/auto-download/auto-download.pid
   ps | grep auto-download
   ```

2. Test manual signal:
   ```bash
   kill -USR1 $(cat /data/adb/auto-download/auto-download.pid)
   ```

### Deep sleep tidak terdeteksi:

1. Cek apakah perangkat benar-benar masuk deep sleep:
   ```bash
   cat /sys/power/suspend_stats/success
   # Angka harus bertambah setelah deep sleep
   ```

2. Monitor wakeup count:
   ```bash
   watch -n 1 cat /sys/power/wakeup_count
   ```

## Uninstall

```bash
su -c './uninstall_wakelock_monitor.sh'
reboot
```

## Kompatibilitas

- **Android 5.0+** (API 21+)
- **Root required**
- **Custom ROM** yang mendukung init.d atau init service
- **Kernel** dengan power management support

## Catatan Penting

1. **Backup**: Selalu backup `auto-download.sh` sebelum instalasi
2. **Testing**: Test di lingkungan non-production terlebih dahulu
3. **Monitoring**: Monitor log files untuk memastikan berfungsi dengan baik
4. **Battery**: Monitor penggunaan battery, meskipun overhead minimal

## Changelog

### v1.0.0
- Initial implementation
- Basic wakelock monitoring
- Signal-based communication
- Automatic schedule recalculation
- Complete installer/uninstaller
- Testing utilities

## Support

Jika mengalami masalah:
1. Jalankan `test_wakelock_monitor.sh` untuk diagnosis
2. Periksa log files untuk error messages
3. Pastikan sistem kompatibel dengan persyaratan