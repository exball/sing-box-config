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

def read_output_names_from_config():
    """
    Membaca semua Output_Name dari config.ini
    Format custom (bukan INI standar)
    Returns: list of output names (dengan ekstensi .json)
    """
    config_path = 'config.ini'
    
    if not os.path.exists(config_path):
        print(f"Error: {config_path} tidak ditemukan!")
        return []
    
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
                output_names.append(output_name)
                print(f"Found Output_Name (line {line_num}): {output_name}")
    
    return output_names

def get_tag_from_filename(filename):
    """
    Mengubah nama file menjadi tag (tanpa ekstensi .json)
    """
    return filename.replace('.json', '')

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
    print(f"Generated tags: {auto_tags}")
    
    # 1. Update outbound_providers
    print("\n=== Updating outbound_providers ===")
    new_providers = []
    
    # Tambahkan provider otomatis dari config.ini
    for output_name in output_names:
        tag = get_tag_from_filename(output_name)
        provider = {
            "type": "local",
            "path": f"./provider/{output_name}",
            "tag": tag
        }
        new_providers.append(provider)
        print(f"Added provider: {tag} -> ./provider/{output_name}")
    
    config_data['outbound_providers'] = new_providers
    
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
    for output_name in output_names:
        tag = get_tag_from_filename(output_name)
        outbound = {
            "type": "urltest",
            "tag": tag,
            "providers": tag,
            "url": "https://www.gstatic.com/generate_204",
            "interval": "1m0s"
        }
        filtered_outbounds.append(outbound)
        print(f"Added urltest outbound: {tag}")
    
    config_data['outbounds'] = filtered_outbounds
    
    # 3. Update "server" outbounds dan providers
    print("\n=== Updating 'server' configuration ===")
    for outbound in config_data['outbounds']:
        if outbound.get('tag') == 'server' and outbound.get('type') == 'selector':
            # Update outbounds array
            fixed_outbounds = ['best latency', 'best latency vmess', 'best latency cf', 'Vmess Tls', 'Vmess Ntls']
            outbound['outbounds'] = fixed_outbounds + auto_tags
            print(f"Updated server.outbounds: {outbound['outbounds']}")
            
            # Update providers array
            fixed_providers = ['Vmess Tls', 'Vmess Ntls']
            outbound['providers'] = fixed_providers + auto_tags
            print(f"Updated server.providers: {outbound['providers']}")
            break
    
    # 4. Update "best latency cf" outbounds
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
    base_url = "https://raw.githubusercontent.com/exball/sing-box-config/refs/heads/Master/outbound-provider"
    
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
    
    print("\n" + "=" * 60)
    print("✅ SINKRONISASI BERHASIL COMPLETED!")
    print("=" * 60)
    print("📋 Yang telah diupdate:")
    print("   • config.json (outbound_providers, outbounds, server, best latency cf)")
    print("   • auto-download.conf (PROVIDER_URLS)")
    print()
    print("🎯 Sistem sekarang tersinkronisasi dengan config.ini")
    print("=" * 60)

if __name__ == "__main__":
    main()