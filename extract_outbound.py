#!/usr/bin/env python3
import json
import re
import requests
import sys
import os
import time
import random
from datetime import datetime
from collections import defaultdict

# Fungsi untuk mendapatkan emoji bendera berdasarkan kode negara
def get_flag_emoji(country_code):
    # Konversi kode negara ke emoji bendera
    # Setiap karakter dalam kode negara dikonversi ke regional indicator symbol
    if not country_code or len(country_code) != 2:
        return ""
    
    # Konversi kode negara ke emoji bendera
    # Contoh: 'ID' -> '🇮🇩'
    code_points = [ord(c) + 127397 for c in country_code.upper()]
    return chr(code_points[0]) + chr(code_points[1])

# Fungsi untuk mendapatkan nama negara dari kode negara
def get_country_name(country_code):
    country_names = {
        "ID": "Indonesia",
        "SG": "Singapore",
        "US": "United States",
        "JP": "Japan",
        "KR": "South Korea",
        "HK": "Hong Kong",
        "TW": "Taiwan",
        "GB": "United Kingdom",
        "DE": "Germany",
        "FR": "France",
        "CA": "Canada",
        "AU": "Australia",
        "NL": "Netherlands",
        "RU": "Russia",
        "IN": "India",
        "BR": "Brazil",
        "IT": "Italy",
        "ES": "Spain",
        "MX": "Mexico",
        "TR": "Turkey"
    }
    return country_names.get(country_code, country_code)

# Fungsi untuk mencoba beberapa kali jika request gagal
def fetch_with_retry(url, max_retries=5, retry_delay=3):
    for attempt in range(max_retries):
        try:
            response = requests.get(url, timeout=30)
            if response.status_code == 200:
                return response
            
            print(f"Attempt {attempt+1}/{max_retries} failed with status code {response.status_code}")
            
            # Jika bukan attempt terakhir, tunggu sebelum mencoba lagi
            if attempt < max_retries - 1:
                # Tambahkan jitter untuk menghindari thundering herd
                jitter = random.uniform(0, 2)
                time.sleep(retry_delay + jitter)
        except requests.RequestException as e:
            print(f"Attempt {attempt+1}/{max_retries} failed with error: {e}")
            
            # Jika bukan attempt terakhir, tunggu sebelum mencoba lagi
            if attempt < max_retries - 1:
                jitter = random.uniform(0, 2)
                time.sleep(retry_delay + jitter)
    
    # Jika semua percobaan gagal
    raise Exception(f"Failed to fetch data after {max_retries} attempts")

def main():
    # URL API untuk mendapatkan konfigurasi BFR
    # Kita bisa mendapatkan proxy dari beberapa negara
    countries = ["ID", "SG", "US"]  # Indonesia, Singapore, United States
    protocols = ["vless", "trojan"]  # Protokol yang didukung
    securities = ["tls", "ntls"]  # Jenis keamanan yang didukung
    
    # Dictionary untuk menyimpan outbound berdasarkan negara, protokol, dan keamanan
    outbounds_by_category = defaultdict(list)
    all_outbounds = []
    
    # Gunakan direktori utama untuk menyimpan file output
    proxies_dir = ""  # Direktori utama (root)
    
    for country in countries:
        for protocol in protocols:
            for security in securities:
                url = f"https://proxy.exbal.my.id/api/bfr?cc={country}&protocols={protocol}&securities={security}"
                
                try:
                    print(f"Fetching {protocol} {security} proxies from {country}...")
                    
                    # Mengambil konfigurasi BFR dengan retry
                    response = fetch_with_retry(url)
                    bfr_config = response.text
                    
                    # Mencari bagian JSON dalam konfigurasi BFR
                    json_match = re.search(r'(\{[\s\S]*\})', bfr_config)
                    if not json_match:
                        print(f"Warning: Could not find JSON configuration in BFR response for {country}")
                        continue
                    
                    json_str = json_match.group(1)
                    
                    # Parse JSON
                    try:
                        config = json.loads(json_str)
                    except json.JSONDecodeError as e:
                        print(f"Warning: Error parsing JSON for {country}: {e}")
                        continue
                    
                    # Ekstrak bagian Outbound
                    if "outbounds" not in config:
                        print(f"Warning: No 'outbounds' section found in configuration for {country}")
                        continue
                    
                    outbounds = config["outbounds"]
                    
                    # Filter outbound berdasarkan protokol dan keamanan
                    filtered_outbounds = []
                    for outbound in outbounds:
                        if (outbound.get("type") == protocol and 
                            ((security == "tls" and outbound.get("tls", {}).get("enabled") == True) or
                             (security == "ntls" and (not outbound.get("tls") or outbound.get("tls", {}).get("enabled") != True)))):
                            
                            # Tambahkan emoji bendera ke tag
                            if "tag" in outbound:
                                tag_parts = outbound["tag"].split(" ")
                                if len(tag_parts) >= 3:
                                    # Ambil nomor urut
                                    number = tag_parts[0]
                                    # Tambahkan emoji bendera
                                    flag_emoji = get_flag_emoji(country)
                                    # Ambil provider dan seterusnya (skip nomor dan emoji asli)
                                    provider_parts = tag_parts[2:]
                                    # Gabungkan kembali dengan emoji yang benar
                                    clean_tag = f"{number} {flag_emoji} {' '.join(provider_parts)}"
                                    outbound["tag"] = clean_tag
                            
                            # Tambahkan metadata negara untuk memudahkan filtering
                            outbound["country_code"] = country
                            
                            filtered_outbounds.append(outbound)
                    
                    print(f"Found {len(filtered_outbounds)} {protocol} {security} proxies from {country}")
                    
                    # Simpan outbound berdasarkan kategori (negara, protokol, keamanan)
                    category_key = f"{country}_{protocol}_{security}"
                    outbounds_by_category[category_key].extend(filtered_outbounds)
                    
                    # Juga simpan semua outbound dalam satu list
                    all_outbounds.extend(filtered_outbounds)
                
                except Exception as e:
                    print(f"Error processing {country} {protocol} {security}: {e}")
    
    # Timestamp untuk semua file
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S UTC")
    
    # Simpan file untuk setiap kategori (negara, protokol, keamanan)
    for category_key, outbounds in outbounds_by_category.items():
        if outbounds:
            # Parse kategori
            country, protocol, security = category_key.split("_")
            
            # Buat hasil untuk kategori ini
            category_result = {
                "Outbound": outbounds,
                "updated_at": timestamp,
                "total_proxies": len(outbounds),
                "country": country,
                "country_name": get_country_name(country),
                "protocol": protocol,
                "security": security
            }
            
            # Format nama file: "ID Vless Tls.json", "SG Trojan Ntls.json", dll.
            # Simpan di direktori utama
            category_file = f"{country} {protocol.capitalize()} {security.upper()}.json"
            with open(category_file, "w", encoding="utf-8") as f:
                json.dump(category_result, f, indent=4, ensure_ascii=False)
            
            print(f"Successfully saved {len(outbounds)} {protocol} {security} proxies from {country} to {category_file}")
    
    # Simpan juga semua proxy ke file gabungan
    all_result = {
        "Outbound": all_outbounds,
        "updated_at": timestamp,
        "total_proxies": len(all_outbounds)
    }
    
    # Simpan file gabungan di direktori utama
    all_file = "outbound-all.json"  # File gabungan di direktori utama
    with open(all_file, "w", encoding="utf-8") as f:
        json.dump(all_result, f, indent=4, ensure_ascii=False)
    
    print(f"Successfully saved all {len(all_outbounds)} proxies to {all_file}")
    
    # Simpan juga ke file utama di root direktori untuk kompatibilitas
    # Ubah nama file utama di sini
    main_file = "outbound.json"  # Ganti dengan nama file utama yang Anda inginkan
    with open(main_file, "w", encoding="utf-8") as f:
        json.dump(all_result, f, indent=4, ensure_ascii=False)
    
    print(f"Successfully saved all {len(all_outbounds)} proxies to {main_file}")
    
    # Buat README.md dengan informasi tentang proxy
    readme_content = f"""# Proxy List

Automatically updated list of working proxies.

## Stats
- Last Updated: {timestamp}
- Total Proxies: {len(all_outbounds)}

## Proxy Breakdown
"""
    
    # Hitung jumlah proxy per kategori (negara, protokol, keamanan)
    category_counts = {}
    for category_key, outbounds in outbounds_by_category.items():
        if outbounds:
            category_counts[category_key] = len(outbounds)
    
    # Hitung jumlah proxy per negara (untuk backward compatibility)
    country_counts = {}
    for outbound in all_outbounds:
        country = outbound.get("country_code", "Unknown")
        if country in country_counts:
            country_counts[country] += 1
        else:
            country_counts[country] = 1
    
    # Tampilkan jumlah proxy per negara
    for country, count in country_counts.items():
        flag_emoji = get_flag_emoji(country)
        country_name = get_country_name(country)
        readme_content += f"- {flag_emoji} {country} ({country_name}): {count} proxies\n"
    
    readme_content += f"""
## Detailed Breakdown
"""

    # Tampilkan jumlah proxy per kategori
    for category_key, count in category_counts.items():
        country, protocol, security = category_key.split("_")
        flag_emoji = get_flag_emoji(country)
        country_name = get_country_name(country)
        readme_content += f"- {flag_emoji} {country} {protocol.capitalize()} {security.upper()}: {count} proxies\n"
    
    readme_content += f"""
## Usage

This repository is automatically updated every 6 hours with fresh proxies.

### Available Files

- `outbound-all.json` - All proxies from all countries
- `outbound.json` - All proxies (same as outbound-all.json, for compatibility)
"""

    # Tambahkan informasi tentang file per kategori
    for category_key in outbounds_by_category.keys():
        if outbounds_by_category[category_key]:
            country, protocol, security = category_key.split("_")
            flag_emoji = get_flag_emoji(country)
            country_name = get_country_name(country)
            file_name = f"{country} {protocol.capitalize()} {security.upper()}.json"
            readme_content += f"- `{file_name}` - {protocol.capitalize()} {security.upper()} proxies from {flag_emoji} {country_name}\n"

    readme_content += """
### How to use

1. Download the appropriate JSON file for your needs
2. Import it into your proxy client that supports the Outbound format
3. Enjoy!

"""
    
    # Simpan README.md
    with open("README.md", "w", encoding="utf-8") as f:
        f.write(readme_content)
    
    print("README.md updated with proxy information")

if __name__ == "__main__":
    main()
