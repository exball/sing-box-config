# Extract Outbound

Direktori ini berisi file-file yang digunakan untuk mengekstrak konfigurasi outbound dari proxy yang tersedia.

## File-file yang ada di direktori ini:

1. `extract_outbound.py` - Script Python untuk mengekstrak konfigurasi outbound dari proxy yang tersedia.
2. `config.ini` - File konfigurasi untuk menentukan negara, protokol, dan keamanan yang akan diekstrak.
3. `config_format.ini` - File konfigurasi untuk menentukan format output JSON.
4. `upload_to_r2.py` - Script Python untuk mengunggah file JSON ke Cloudflare R2.

## Cara Penggunaan

Script ini dijalankan secara otomatis oleh GitHub Actions workflow `scan&extract-proxy.yml`. Namun, Anda juga dapat menjalankannya secara manual dengan perintah berikut:

```bash
cd extract-outbound
python extract_outbound.py -o config_format.ini -f config.ini
```

## Output

Output dari script ini adalah file JSON yang berisi konfigurasi outbound untuk sing-box. File-file ini disimpan di direktori `outbound-provider` di root project.