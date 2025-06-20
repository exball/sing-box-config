#!/usr/bin/env python3
import json
import re
import requests
import sys
import os
import time
import random
import argparse
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

# Fungsi untuk memproses konfigurasi dan mengambil outbound
def process_config(config):
    # Ekstrak parameter dari konfigurasi
    countries = [c.strip() for c in config.get("Country_ID", "ID,SG,US").split(",")]
    protocols = [p.strip().lower() for p in config.get("Protocol", "vless,trojan").split(",")]
    securities = [s.strip().lower() for s in config.get("Security", "tls,ntls").split(",")]
    output_name = config.get("Output_Name", "outbound.json")
    
    print(f"\nProcessing configuration:")
    print(f"Countries: {', '.join(countries)}")
    print(f"Protocols: {', '.join(protocols)}")
    print(f"Securities: {', '.join(securities)}")
    print(f"Output file: {output_name}")
    
    # Dictionary untuk menyimpan outbound berdasarkan negara, protokol, dan keamanan
    outbounds_by_category = defaultdict(list)
    all_outbounds = []
    
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
                        config_data = json.loads(json_str)
                    except json.JSONDecodeError as e:
                        print(f"Warning: Error parsing JSON for {country}: {e}")
                        continue
                    
                    # Ekstrak bagian Outbound
                    if "outbounds" not in config_data:
                        print(f"Warning: No 'outbounds' section found in configuration for {country}")
                        continue
                    
                    outbounds = config_data["outbounds"]
                    
                    # Filter outbound berdasarkan protokol dan keamanan
                    filtered_outbounds = []
                    
                    # Untuk melacak provider yang sudah diambil (untuk negara selain Indonesia)
                    providers_seen = set()
                    
                    for outbound in outbounds:
                        if (outbound.get("type") == protocol and 
                            ((security == "tls" and outbound.get("tls", {}).get("enabled") == True) or
                             (security == "ntls" and (not outbound.get("tls") or outbound.get("tls", {}).get("enabled") != True)))):
                            
                            # Tambahkan emoji bendera ke tag
                            provider_name = "unknown"
                            if "tag" in outbound:
                                tag_parts = outbound["tag"].split(" ")
                                if len(tag_parts) >= 3:
                                    # Ambil nomor urut
                                    number = tag_parts[0]
                                    # Tambahkan emoji bendera
                                    flag_emoji = get_flag_emoji(country)
                                    # Ambil provider dan seterusnya (skip nomor dan emoji asli)
                                    provider_parts = tag_parts[2:]
                                    # Ekstrak nama provider untuk tracking
                                    provider_name = ' '.join(provider_parts).lower()
                                    # Gabungkan kembali dengan emoji yang benar
                                    clean_tag = f"{number} {flag_emoji} {' '.join(provider_parts)}"
                                    outbound["tag"] = clean_tag
                            
                            # Buat salinan outbound tanpa field country_code
                            outbound_copy = {}
                            
                            # Tambahkan field dalam urutan yang diinginkan
                            for key in ["server", "server_port", "tag"]:
                                if key in outbound:
                                    outbound_copy[key] = outbound[key]
                            
                            # Tambahkan network setelah tag
                            outbound_copy["network"] = "tcp"
                            
                            # Tambahkan field lainnya
                            for key in outbound:
                                if key not in ["server", "server_port", "tag", "country_code"] and key not in outbound_copy:
                                    outbound_copy[key] = outbound[key]
                            
                            # Logika untuk memfilter proxy:
                            # 1. Untuk Indonesia (ID): Ambil semua proxy
                            # 2. Untuk negara lain: Ambil hanya 1 proxy per provider
                            if country == "ID" or provider_name not in providers_seen:
                                filtered_outbounds.append(outbound_copy)
                                
                                # Tambahkan provider ke set untuk melacak (kecuali untuk Indonesia)
                                if country != "ID":
                                    providers_seen.add(provider_name)
                                    
                                    # Debug info
                                    print(f"Added {country} proxy from provider: {provider_name}")
                    
                    print(f"Found {len(filtered_outbounds)} {protocol} {security} proxies from {country}")
                    
                    # Simpan outbound berdasarkan kategori (negara, protokol, keamanan)
                    category_key = f"{country}_{protocol}_{security}"
                    outbounds_by_category[category_key].extend(filtered_outbounds)
                    
                    # Juga simpan semua outbound dalam satu list
                    all_outbounds.extend(filtered_outbounds)
                
                except Exception as e:
                    print(f"Error processing {country} {protocol} {security}: {e}")
    
    # Buat hasil untuk output file - hanya berisi outbounds saja
    result = {
        "outbounds": all_outbounds
    }
    
    # Simpan ke file output
    with open(output_name, "w", encoding="utf-8") as f:
        json.dump(result, f, indent=4, ensure_ascii=False)
    
    print(f"Successfully saved {len(all_outbounds)} proxies to {output_name}")
    
    return {
        "outbounds": all_outbounds,
        "outbounds_by_category": outbounds_by_category
    }

# Fungsi untuk membaca konfigurasi dari file
def read_config_file(file_path):
    try:
        with open(file_path, 'r') as f:
            configs = []
            current_config = {}
            
            for line in f:
                line = line.strip()
                
                # Skip baris kosong atau komentar
                if not line or line.startswith('#'):
                    continue
                
                # Jika menemukan baris dengan format key=value
                if '=' in line:
                    key, value = line.split('=', 1)
                    key = key.strip()
                    value = value.strip()
                    
                    # Jika ini adalah konfigurasi baru (Output_Name baru)
                    if key == "Output_Name" and "Output_Name" in current_config:
                        # Simpan konfigurasi sebelumnya
                        configs.append(current_config)
                        # Mulai konfigurasi baru
                        current_config = {key: value}
                    else:
                        current_config[key] = value
            
            # Tambahkan konfigurasi terakhir
            if current_config:
                configs.append(current_config)
                
            return configs
    except Exception as e:
        print(f"Error reading config file: {e}")
        return []

# Fungsi untuk membuat README.md
def create_readme(all_results):
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S UTC")
    
    # Gabungkan semua outbound dari semua konfigurasi
    all_outbounds = []
    all_outbounds_by_category = defaultdict(list)
    
    for result in all_results:
        all_outbounds.extend(result["outbounds"])
        for category, outbounds in result["outbounds_by_category"].items():
            all_outbounds_by_category[category].extend(outbounds)
    
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
    for category_key, outbounds in all_outbounds_by_category.items():
        if outbounds:
            category_counts[category_key] = len(outbounds)
    
    # Hitung jumlah proxy per negara
    country_counts = defaultdict(int)
    for category_key, count in category_counts.items():
        country = category_key.split("_")[0]
        country_counts[country] += count
    
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

"""

    # Tambahkan informasi tentang file output yang dibuat
    for result in all_results:
        for category_key, outbounds in result["outbounds_by_category"].items():
            if outbounds:
                country, protocol, security = category_key.split("_")
                flag_emoji = get_flag_emoji(country)
                country_name = get_country_name(country)
                readme_content += f"- {protocol.capitalize()} {security.upper()} proxies from {flag_emoji} {country_name}\n"

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

def main():
    parser = argparse.ArgumentParser(description='Extract outbound configurations from BFR API')
    parser.add_argument('-c', '--config', help='Path to configuration file')
    parser.add_argument('--country', help='Comma-separated list of country codes (e.g., ID,SG,US)')
    parser.add_argument('--protocol', help='Comma-separated list of protocols (e.g., vless,trojan)')
    parser.add_argument('--security', help='Comma-separated list of security types (e.g., tls,ntls)')
    parser.add_argument('--output', help='Output file name')
    
    args = parser.parse_args()
    
    all_results = []
    
    # Jika ada file konfigurasi, baca dari file
    if args.config:
        configs = read_config_file(args.config)
        if configs:
            for config in configs:
                result = process_config(config)
                all_results.append(result)
        else:
            print("No valid configurations found in the config file.")
    # Jika tidak ada file konfigurasi, gunakan argumen command line atau default
    else:
        config = {}
        if args.country:
            config["Country_ID"] = args.country
        if args.protocol:
            config["Protocol"] = args.protocol
        if args.security:
            config["Security"] = args.security
        if args.output:
            config["Output_Name"] = args.output
        
        # Jika tidak ada argumen sama sekali, gunakan default
        if not config:
            print("No configuration provided. Using default values:")
            config = {
                "Country_ID": "ID,SG,US,JP,KR",
                "Protocol": "vless,trojan",
                "Security": "tls,ntls",
                "Output_Name": "outbound.json"
            }
        
        result = process_config(config)
        all_results.append(result)
    
    # Buat README.md dengan informasi tentang semua proxy
    create_readme(all_results)

if __name__ == "__main__":
    main()
