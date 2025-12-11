#!/usr/bin/env python3
"""
Script untuk sinkronisasi otomatis konfigurasi berdasarkan config.ini
Membaca Output_Name dari config.ini dan mengupdate:
1. config.json (outbound_providers, outbounds, server, best latency cf)
2. auto-download.conf (PROVIDER_URLS)

Author: Auto-generated sync script
"""

import json
import configparser
import os
import sys
from datetime import datetime

def read_format_from_config():
    """
    Membaca nilai Format dari config.ini
    Returns: string format (bfr, clash, raw, sfa, v2ray)
    """
    config_path = 'config.ini'
    
    if not os.path.exists(config_path):
        print(f"Error: {config_path} tidak ditemukan!")
        return "bfr"  # default
    
    # Baca file baris per baris
    with open(config_path, 'r', encoding='utf-8') as f:
        lines = f.readlines()
    
    for line_num, line in enumerate(lines, 1):
        line = line.strip()
        
        # Cari baris yang mengandung Format
        if line.startswith('Format='):
            # Extract value setelah =
            format_value = line.split('=', 1)[1].strip()
            if format_value:
                print(f"Found Format (line {line_num}): {format_value}")
                return format_value
    
    print("Format tidak ditemukan, menggunakan default: bfr")
    return "bfr"  # default

def get_file_extension_from_format(format_value):
    """
    Menentukan ekstensi file berdasarkan format
    Args: format_value (string): Format dari config.ini
    Returns: string ekstensi file (dengan titik)
    """
    format_to_extension = {
        'bfr': '.json',
        'v2ray': '.json', 
        'clash': '.yaml',
        'raw': '.txt',
        'sfa': '.txt'
    }
    
    extension = format_to_extension.get(format_value.lower(), '.json')
    print(f"Format '{format_value}' → Extension '{extension}'")
    return extension

def read_output_names_from_config():
    """
    Membaca semua Output_Name dari config.ini
    Format custom (bukan INI standar)
    Returns: list of output names (dengan ekstensi yang sesuai format)
    """
    config_path = 'config.ini'
    
    if not os.path.exists(config_path):
        print(f"Error: {config_path} tidak ditemukan!")
        return []
    
    # Baca format terlebih dahulu
    format_value = read_format_from_config()
    extension = get_file_extension_from_format(format_value)
    
    output_names = []
    
    # Baca file baris per baris
    with open(config_path, 'r', encoding='utf-8') as f:
        lines = f.readlines()
    
    for line_num, line in enumerate(lines, 1):
        line = line.strip()
        
        # Cari baris yang mengandung Output_Name
        if line.startswith('Output_Name='):
            # Extract value setelah =
            output_name = line.split('=', 1)[1].strip()
            if output_name:
                # Pastikan output_name memiliki ekstensi yang sesuai
                # Hapus ekstensi lama jika ada
                if '.' in output_name:
                    base_name = output_name.rsplit('.', 1)[0]
                else:
                    base_name = output_name
                
                # Tambahkan ekstensi yang sesuai dengan format
                final_output_name = base_name + extension
                output_names.append(final_output_name)
                print(f"Found Output_Name (line {line_num}): {output_name} → {final_output_name}")
    
    return output_names

def get_tag_from_filename(filename):
    """
    Mengubah nama file menjadi tag (tanpa ekstensi)
    Mendukung berbagai ekstensi: .json, .yaml, .yml, .txt
    """
    # Hapus ekstensi apapun dari filename
    if '.' in filename:
        return filename.rsplit('.', 1)[0]
    return filename

def format_outbound_tag(tag):
    """
    Format tag untuk outbounds: ganti spasi dengan -, tambah - jika tidak ada spasi
    """
    if ' ' in tag:
        return tag.replace(' ', '-')
    else:
        return tag + '-'

def format_provider_tag(tag):
    """
    Format tag untuk providers: ganti spasi dengan _, tambah _ jika tidak ada spasi
    """
    if ' ' in tag:
        return tag.replace(' ', '_')
    else:
        return tag + '_'

def update_config_json(output_names):
    """
    Update config.json berdasarkan output_names dari config.ini
    """
    config_path = '../config.json'
    
    if not os.path.exists(config_path):
        print(f"Error: {config_path} tidak ditemukan!")
        return False
    
    # Baca config.json
    with open(config_path, 'r', encoding='utf-8') as f:
        config_data = json.load(f)
    
    # Generate tags dari output_names
    auto_tags = [get_tag_from_filename(name) for name in output_names]
    outbound_tags = [format_outbound_tag(tag) for tag in auto_tags]
    provider_tags = [format_provider_tag(tag) for tag in auto_tags]
    print(f"Generated tags: {auto_tags}")
    print(f"Outbound tags: {outbound_tags}")
    print(f"Provider tags: {provider_tags}")
    
    # 1. Update outbound_providers
    print("\n=== Updating outbound_providers ===")
    
    # Preserve provider manual (Vmess)
    manual_providers = [
        {
            "type": "local",
            "path": "./provider/Vmess Tls.json",
            "tag": "Vmess_Tls"
        },
        {
            "type": "local",
            "path": "./provider/Vmess Ntls.json",
            "tag": "Vmess_Ntls"
        }
    ]
    
    # Tambahkan provider otomatis dari config.ini
    auto_providers = []
    for i, output_name in enumerate(output_names):
        tag = provider_tags[i]
        provider = {
            "type": "local",
            "path": f"./provider/{output_name}",
            "tag": tag
        }
        auto_providers.append(provider)
        print(f"Added provider: {tag} -> ./provider/{output_name}")
    
    # Gabungkan manual + auto providers
    new_providers = manual_providers + auto_providers
    config_data['outbound_providers'] = new_providers
    
    print(f"✅ Total providers: {len(new_providers)} (2 manual Vmess + {len(auto_providers)} auto dari config.ini)")
    
    # 2. Update individual outbounds (urltest untuk setiap provider)
    print("\n=== Updating individual outbounds ===")
    outbounds = config_data.get('outbounds', [])
    
    # Hapus outbound lama yang auto-generated (yang ada di auto_tags)
    # Tapi pertahankan yang manual seperti server, best latency, vmess, dll
    manual_tags = [
        'server', 'best latency', 'best latency vmess', 'best latency cf',
        'Vmess Tls', 'Vmess Ntls', 'direct', 'block', 'dns'
    ]
    
    # Filter outbound: pertahankan manual, hapus yang auto-generated lama
    filtered_outbounds = []
    for outbound in outbounds:
        tag = outbound.get('tag', '')
        if tag in manual_tags or outbound.get('type') in ['selector', 'direct', 'block', 'dns']:
            filtered_outbounds.append(outbound)
        else:
            print(f"Removed old auto-generated outbound: {tag}")
    
    # Tambahkan outbound baru untuk setiap provider
    for i, output_name in enumerate(output_names):
        tag = outbound_tags[i]
        provider_tag = provider_tags[i]
        outbound = {
            "type": "urltest",
            "tag": tag,
            "providers": provider_tag,
            "url": "https://www.gstatic.com/generate_204",
            "interval": "1m0s"
        }
        filtered_outbounds.append(outbound)
        print(f"Added urltest outbound: {tag}")
    
    # Update manual Vmess outbounds to new format
    for outbound in filtered_outbounds:
        if outbound.get('tag') == 'Vmess Tls':
            outbound['tag'] = 'Vmess-Tls'
            outbound['providers'] = 'Vmess_Tls'
        elif outbound.get('tag') == 'Vmess Ntls':
            outbound['tag'] = 'Vmess-Ntls'
            outbound['providers'] = 'Vmess_Ntls'

    config_data['outbounds'] = filtered_outbounds

    # 3. Update "server" outbounds dan providers
    print("\n=== Updating 'server' configuration ===")
    for outbound in config_data['outbounds']:
        if outbound.get('tag') == 'server' and outbound.get('type') == 'selector':
            # Update outbounds array
            fixed_outbounds = ['best latency', 'best latency vmess', 'best latency cf', 'Vmess-Tls', 'Vmess-Ntls']
            outbound['outbounds'] = fixed_outbounds + outbound_tags
            print(f"Updated server.outbounds: {outbound['outbounds']}")

            # Update providers array
            fixed_providers = ['Vmess_Tls', 'Vmess_Ntls']
            outbound['providers'] = fixed_providers + provider_tags
            print(f"Updated server.providers: {outbound['providers']}")
            break
    
    # 4. Update "best latency vmess" outbounds
    print("\n=== Updating 'best latency vmess' configuration ===")
    for outbound in config_data['outbounds']:
        if outbound.get('tag') == 'best latency vmess' and outbound.get('type') == 'urltest':
            outbound['outbounds'] = ['Vmess-Tls', 'Vmess-Ntls']
            print(f"Updated best latency vmess.outbounds: {outbound['outbounds']}")
            break

    # 5. Update "best latency cf" outbounds
    print("\n=== Updating 'best latency cf' configuration ===")
    for outbound in config_data['outbounds']:
        if outbound.get('tag') == 'best latency cf' and outbound.get('type') == 'urltest':
            # Hanya auto_tags (tanpa vmess manual)
            outbound['outbounds'] = auto_tags
            print(f"Updated best latency cf.outbounds: {outbound['outbounds']}")
            break
    
    # Simpan config.json
    with open(config_path, 'w', encoding='utf-8') as f:
        json.dump(config_data, f, indent=2, ensure_ascii=False)
    
    print(f"\n✅ config.json berhasil diupdate!")
    return True

def update_auto_download_conf(output_names):
    """
    Update auto-download.conf berdasarkan output_names dari config.ini
    Preserve Vmess URLs yang manual dan gunakan format backslash yang benar
    """
    import urllib.parse
    
    conf_path = '../auto-download/auto-download.conf'
    
    if not os.path.exists(conf_path):
        print(f"Error: {conf_path} tidak ditemukan!")
        return False
    
    print("\n=== Updating auto-download.conf ===")
    
    # Generate PROVIDER_URLS dengan URL encoding
    base_url = "https://raw.githubusercontent.com/exball/sing-box-config/refs/heads/Master/provider"
    
    # URLs manual untuk Vmess (preserve)
    manual_urls = [
        f"{base_url}/Vmess%20Tls.json",
        f"{base_url}/Vmess%20Ntls.json"
    ]
    
    # URLs otomatis dari config.ini
    auto_urls = []
    for output_name in output_names:
        # URL encode nama file untuk handle spasi dan karakter khusus
        encoded_name = urllib.parse.quote(output_name)
        url = f"{base_url}/{encoded_name}"
        auto_urls.append(url)
        print(f"Added URL: {url}")
    
    # Gabungkan URLs
    all_urls = manual_urls + auto_urls
    
    # Baca file conf
    with open(conf_path, 'r', encoding='utf-8') as f:
        lines = f.readlines()
    
    # Update PROVIDER_URLS section dengan format backslash
    new_lines = []
    in_provider_urls = False
    
    for line in lines:
        if line.strip().startswith('PROVIDER_URLS="'):
            # Mulai section PROVIDER_URLS
            in_provider_urls = True
            new_lines.append('PROVIDER_URLS="\n')
            
            # Tambahkan URLs dengan format backslash
            for i, url in enumerate(all_urls):
                if i == len(all_urls) - 1:  # URL terakhir tanpa backslash
                    new_lines.append(f'{url}\n')
                else:  # URL dengan backslash
                    new_lines.append(f'{url} \\\n')
            
            new_lines.append('"\n')
        elif in_provider_urls and line.strip() == '"':
            # Akhir section PROVIDER_URLS (sudah ditambahkan di atas)
            in_provider_urls = False
            continue
        elif in_provider_urls:
            # Skip baris dalam PROVIDER_URLS lama
            continue
        else:
            # Baris biasa, pertahankan
            new_lines.append(line)
    
    # Simpan file conf
    with open(conf_path, 'w', encoding='utf-8') as f:
        f.writelines(new_lines)
    
    print(f"✅ auto-download.conf berhasil diupdate!")
    print(f"📋 Total URLs: {len(all_urls)} (2 manual Vmess + {len(auto_urls)} auto dari config.ini)")
    return True

def cleanup_unused_provider_files(output_names):
    """
    Hapus file provider yang tidak digunakan lagi
    Preserve file Vmess manual, hapus file auto yang tidak ada di config.ini
    Mendukung berbagai format file: .json, .yaml, .yml, .txt
    """
    import os
    import glob
    
    provider_dir = '../provider'
    
    if not os.path.exists(provider_dir):
        print(f"⚠️  Direktori {provider_dir} tidak ditemukan, skip cleanup")
        return True
    
    print("\n=== Cleaning up unused provider files ===")
    
    # File manual yang harus di-preserve (format apapun)
    manual_base_names = {
        'Vmess Tls',
        'Vmess Ntls'
    }
    
    # File yang seharusnya ada (dari config.ini)
    expected_files = set(output_names)
    
    # Scan semua file provider dengan berbagai ekstensi
    all_extensions = ['*.json', '*.yaml', '*.yml', '*.txt']
    all_files = []
    
    for ext in all_extensions:
        files = glob.glob(os.path.join(provider_dir, ext))
        all_files.extend(files)
    
    deleted_count = 0
    for file_path in all_files:
        filename = os.path.basename(file_path)
        base_name = get_tag_from_filename(filename)
        
        # Check apakah file ini manual atau expected
        is_manual = base_name in manual_base_names
        is_expected = filename in expected_files
        
        if is_manual or is_expected:
            print(f"✅ Keeping file: {filename}")
        else:
            try:
                os.remove(file_path)
                print(f"🗑️  Deleted unused file: {filename}")
                deleted_count += 1
            except Exception as e:
                print(f"❌ Failed to delete {filename}: {e}")
    
    if deleted_count > 0:
        print(f"🧹 Cleanup completed: {deleted_count} unused files deleted")
    else:
        print("✨ No unused files found, directory is clean")
    
    return True

def main():
    """
    Main function untuk menjalankan sinkronisasi
    """
    print("=" * 60)
    print("🔄 SYNC CONFIG SCRIPT")
    print("=" * 60)
    print(f"Waktu eksekusi: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print()
    
    # 1. Baca Output_Name dari config.ini
    print("📖 Membaca config.ini...")
    output_names = read_output_names_from_config()
    
    if not output_names:
        print("❌ Tidak ada Output_Name yang ditemukan di config.ini!")
        sys.exit(1)
    
    print(f"✅ Ditemukan {len(output_names)} Output_Name:")
    for i, name in enumerate(output_names, 1):
        print(f"   {i}. {name}")
    
    # 2. Update config.json
    print(f"\n📝 Mengupdate config.json...")
    if not update_config_json(output_names):
        print("❌ Gagal mengupdate config.json!")
        sys.exit(1)
    
    # 3. Update auto-download.conf
    print(f"\n📝 Mengupdate auto-download.conf...")
    if not update_auto_download_conf(output_names):
        print("❌ Gagal mengupdate auto-download.conf!")
        sys.exit(1)
    
    # 4. Cleanup unused provider files
    print(f"\n🧹 Membersihkan file provider yang tidak digunakan...")
    if not cleanup_unused_provider_files(output_names):
        print("❌ Gagal membersihkan file provider!")
        sys.exit(1)
    
    print("\n" + "=" * 60)
    print("✅ SINKRONISASI BERHASIL COMPLETED!")
    print("=" * 60)
    print("📋 Yang telah diupdate:")
    print("   • config.json (outbound_providers, outbounds, server, best latency cf)")
    print("   • auto-download.conf (PROVIDER_URLS)")
    print("   • provider/ (cleanup unused files)")
    print()
    print("🎯 Sistem sekarang tersinkronisasi dengan config.ini")
    print("=" * 60)

if __name__ == "__main__":
    main()