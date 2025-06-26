#!/usr/bin/env python3
import json
import re
import requests
import sys
import os
import time
import random
import argparse
import configparser
from datetime import datetime
from collections import defaultdict

# Variabel global untuk menyimpan format outbound
outbound_format = None

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
        "AR": "Argentina",
        "AM": "Armenia",
        "AU": "Australia",
        "AT": "Austria",
        "BE": "Belgium",
        "BR": "Brazil",
        "BG": "Bulgaria",
        "CA": "Canada",
        "CN": "China",
        "CY": "Cyprus",
        "CZ": "Czech Republic",
        "DK": "Denmark",
        "EE": "Estonia",
        "FI": "Finland",
        "FR": "France",
        "DE": "Germany",
        "HK": "Hong Kong",
        "HU": "Hungary",
        "IN": "India",
        "ID": "Indonesia",
        "IE": "Ireland",
        "IT": "Italy",
        "JP": "Japan",
        "KZ": "Kazakhstan",
        "KR": "South Korea",
        "LV": "Latvia",
        "LT": "Lithuania",
        "LU": "Luxembourg",
        "MY": "Malaysia",
        "MU": "Mauritius",
        "MX": "Mexico",
        "MD": "Moldova",
        "NL": "Netherlands",
        "PH": "Philippines",
        "PL": "Poland",
        "PT": "Portugal",
        "RO": "Romania",
        "RU": "Russia",
        "RS": "Serbia",
        "SG": "Singapore",
        "SK": "Slovakia",
        "ES": "Spain",
        "SE": "Sweden",
        "CH": "Switzerland",
        "TW": "Taiwan",
        "TH": "Thailand",
        "TR": "Turkey",
        "UA": "Ukraine",
        "AE": "United Arab Emirates",
        "GB": "United Kingdom",
        "US": "United States",
        "VN": "Vietnam",
        "TF": "French Southern Territories"
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

def parse_config_input(config_str):
    """
    Parse konfigurasi input dari string.
    Format: key=value1, value2, value3
    """
    result = {}
    if not config_str:
        return result
        
    lines = config_str.strip().split('\n')
    for line in lines:
        if '=' in line:
            key, values = line.split('=', 1)
            key = key.strip()
            # Split values by comma and strip whitespace
            values = [v.strip() for v in values.split(',')]
            result[key] = values
    return result

def read_config_file(file_path):
    """
    Membaca konfigurasi dari file.
    Format file:
    #Komentar (opsional)
    Country_ID= ID, SG
    Protocol= vless, trojan
    Security= tls, ntls
    Output_Name= output.json
    
    #Komentar untuk blok berikutnya (opsional)
    Country_ID= JP
    ...
    """
    if not os.path.exists(file_path):
        print(f"Error: File konfigurasi '{file_path}' tidak ditemukan.")
        return []
    
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()
    except Exception as e:
        print(f"Error: Gagal membaca file konfigurasi '{file_path}': {str(e)}")
        return []
    
    # Pisahkan file menjadi blok-blok konfigurasi
    # Blok dipisahkan oleh baris kosong atau baris yang dimulai dengan #
    blocks = []
    current_block = []
    
    lines = content.split('\n')
    for i, line in enumerate(lines):
        line_num = i + 1  # Line numbers start at 1
        line = line.strip()
        
        # Jika baris adalah komentar atau kosong dan ada blok sebelumnya, simpan blok
        if (line.startswith('#') or not line) and current_block:
            blocks.append('\n'.join(current_block))
            current_block = []
            continue
        
        # Jika baris adalah komentar atau kosong, lewati
        if line.startswith('#') or not line:
            continue
        
        # Validasi format baris
        if '=' not in line:
            print(f"Warning: Baris {line_num} tidak mengikuti format 'key= value': '{line}'")
            continue
            
        # Tambahkan baris ke blok saat ini
        current_block.append(line)
        
        # Jika ini adalah baris terakhir dan ada blok, simpan blok
        if i == len(lines) - 1 and current_block:
            blocks.append('\n'.join(current_block))
    
    # Parse setiap blok menjadi dictionary
    configs = []
    for block_index, block in enumerate(blocks):
        config = parse_config_input(block)
        
        # Validasi konfigurasi
        if not config:
            print(f"Warning: Blok konfigurasi #{block_index+1} kosong atau tidak valid.")
            continue
            
        # Periksa apakah semua parameter yang diperlukan ada
        missing_params = []
        for param in ["Country_ID", "Protocol", "Security", "Output_Name"]:
            if param not in config:
                missing_params.append(param)
        
        if missing_params:
            print(f"Warning: Blok konfigurasi #{block_index+1} tidak lengkap. Parameter yang hilang: {', '.join(missing_params)}")
            continue
            
        # Periksa apakah semua parameter memiliki nilai
        empty_params = []
        for param in ["Country_ID", "Protocol", "Security", "Output_Name"]:
            if not config.get(param, []):
                empty_params.append(param)
                
        if empty_params:
            print(f"Warning: Blok konfigurasi #{block_index+1} memiliki parameter kosong: {', '.join(empty_params)}")
            continue
            
        configs.append(config)
    
    return configs

def load_outbound_format(format_file="config_format.ini"):
    """
    Membaca format outbound dari file konfigurasi format.
    Jika file tidak ada, gunakan format default.
    """
    if not os.path.exists(format_file):
        print(f"Warning: Format file '{format_file}' tidak ditemukan. Menggunakan format default.")
        return None
    
    try:
        with open(format_file, 'r', encoding='utf-8') as f:
            format_json = json.load(f)
        print(f"Format outbound berhasil dimuat dari '{format_file}'")
        return format_json
    except Exception as e:
        print(f"Error: Gagal membaca file format '{format_file}': {str(e)}")
        print("Menggunakan format default.")
        return None

def apply_outbound_format(outbound, format_template, protocol_format=None):
    """
    Menerapkan format template ke outbound berdasarkan protokol.
    - Pilih template yang sesuai berdasarkan protokol (vless, trojan, shadowsocks)
    - Jika field di template kosong ("") dan field tersebut ada di outbound asli, gunakan nilai dari outbound asli
    - Jika field di template kosong ("") dan field tersebut tidak ada di outbound asli, jangan tambahkan field tersebut
    - Jika field di template memiliki nilai, gunakan nilai tersebut
    
    Args:
        outbound: Outbound yang akan diformat
        format_template: Template format yang akan diterapkan
        protocol_format: Protokol yang digunakan untuk memilih template (opsional)
    """
    if not format_template:
        return outbound
    
    # Tentukan protokol outbound
    if protocol_format:
        # Gunakan protocol_format jika disediakan
        protocol = protocol_format
    else:
        # Jika tidak, gunakan tipe outbound
        protocol = outbound.get("type", "").lower()
    
    # Pilih template yang sesuai berdasarkan protokol
    if protocol in format_template:
        template = format_template[protocol]
    else:
        # Jika protokol tidak ditemukan dalam template, gunakan outbound asli
        print(f"Warning: No format template found for protocol '{protocol}'. Using default format.")
        return outbound
    
    # Buat hasil kosong yang akan diisi berdasarkan template dan source
    result = {}
    
    # Fungsi rekursif untuk menerapkan format
    def apply_format(target, source, template):
        # Untuk setiap key di template
        for key, template_value in template.items():
            # Jika nilai template adalah dict, proses secara rekursif
            if isinstance(template_value, dict):
                # Jika key ada di source, proses secara rekursif
                if key in source:
                    target[key] = {}
                    apply_format(target[key], source[key], template_value)
                else:
                    # Periksa apakah ada nilai non-empty di template
                    has_non_empty_value = False
                    for sub_key, sub_value in template_value.items():
                        if sub_value != "":
                            has_non_empty_value = True
                            break
                    
                    # Jika ada nilai non-empty, tambahkan objek kosong dan proses
                    if has_non_empty_value:
                        target[key] = {}
                        apply_format(target[key], {}, template_value)
            # Jika nilai template adalah string kosong, gunakan nilai dari source jika ada
            elif template_value == "":
                if key in source:
                    target[key] = source[key]
            # Jika tidak, gunakan nilai dari template
            else:
                target[key] = template_value
    
    apply_format(result, outbound, template)
    return result

def parse_args():
    """
    Parse command line arguments.
    """
    parser = argparse.ArgumentParser(description='Extract outbound configurations based on specified criteria.')
    parser.add_argument('--config-file', '-f', type=str, help='Path to configuration file (default: config.ini)')
    parser.add_argument('--format-file', '-o', type=str, help='Path to outbound format file (default: config_format.ini)')
    
    return parser.parse_args()

def process_single_config(config):
    """
    Proses satu konfigurasi dan ambil outbound berdasarkan konfigurasi tersebut.
    """
    # Pastikan semua parameter yang diperlukan ada dalam konfigurasi
    missing_params = []
    for param in ["Country_ID", "Protocol", "Security", "Output_Name"]:
        if param not in config:
            missing_params.append(param)
    
    if missing_params:
        print(f"Error: Missing required parameters in configuration: {', '.join(missing_params)}")
        print("Required parameters: Country_ID, Protocol, Security, Output_Name")
        return 0
    
    # Parse configuration
    countries = [c.upper() for c in config.get("Country_ID", [])]
    protocols = [p.lower() for p in config.get("Protocol", [])]
    securities = [s.lower() for s in config.get("Security", [])]
    output_name = config.get("Output_Name", [""])[0]
    
    # Pastikan semua parameter memiliki nilai
    empty_params = []
    if not countries:
        empty_params.append("Country_ID")
    if not protocols:
        empty_params.append("Protocol")
    if not securities:
        empty_params.append("Security")
    if not output_name:
        empty_params.append("Output_Name")
    
    if empty_params:
        print(f"Error: Empty values for required parameters: {', '.join(empty_params)}")
        print("Please provide values for all required parameters.")
        return 0
        
    # Validasi nilai parameter
    valid_countries = ["AE", "AM", "AR", "AT", "AU", "BE", "BG", "BR", "CA", "CH", "CN", "CY", "CZ", "DE", "DK", 
                      "EE", "ES", "FI", "FR", "GB", "HK", "HU", "ID", "IE", "IN", "IT", "JP", "KR", "KZ", 
                      "LT", "LU", "LV", "MD", "MU", "MX", "MY", "NL", "PH", "PL", "PT", "RO", "RS", "RU", "SE", 
                      "SG", "SK", "TF", "TH", "TR", "TW", "UA", "US", "VN"]
    invalid_countries = [c for c in countries if c not in valid_countries]
    invalid_protocols = [p for p in protocols if p not in ["vless", "trojan", "ss"]]
    invalid_securities = [s for s in securities if s not in ["tls", "ntls"]]
    
    if invalid_countries:
        print(f"Warning: Invalid country codes: {', '.join(invalid_countries)}")
        print("These country codes will be ignored.")
        countries = [c for c in countries if c not in invalid_countries]
        
    if invalid_protocols:
        print(f"Warning: Invalid protocols: {', '.join(invalid_protocols)}")
        print("These protocols will be ignored.")
        protocols = [p for p in protocols if p not in invalid_protocols]
        
    if invalid_securities:
        print(f"Warning: Invalid securities: {', '.join(invalid_securities)}")
        print("These securities will be ignored.")
        securities = [s for s in securities if s not in invalid_securities]
        
    if not countries or not protocols or not securities:
        print("Error: No valid values left for one or more required parameters after validation.")
        print("Please provide valid values for all required parameters.")
        return 0
    
    print(f"\nMenggunakan konfigurasi:")
    print(f"- Negara: {', '.join(countries)}")
    print(f"- Protokol: {', '.join(protocols)}")
    print(f"- Security: {', '.join(securities)}")
    print(f"- Output file: {output_name}")
    
    # Dictionary untuk menyimpan outbound berdasarkan negara, protokol, dan keamanan
    outbounds_by_category = defaultdict(list)
    all_outbounds = []
    
    # Ambil outbound untuk setiap kombinasi negara, protokol, dan keamanan
    # Tentukan URL berdasarkan waktu saat ini
    current_hour = datetime.now().hour
    
    # Gunakan proxy.ex-vpn.my.id dari jam 00:00 sampai 11:59, proxy.exbal.my.id dari jam 12:00 sampai 23:59
    if current_hour < 12:
        base_url = "https://proxy.ex-vpn.my.id/api/bfr"
        print(f"Using proxy.ex-vpn.my.id based on current time: {datetime.now().strftime('%H:%M:%S')}")
    else:
        base_url = "https://proxy.exbal.my.id/api/bfr"
        print(f"Using proxy.exbal.my.id based on current time: {datetime.now().strftime('%H:%M:%S')}")
    
    for country in countries:
        for protocol in protocols:
            for security in securities:
                url = f"{base_url}?cc={country}&protocols={protocol}&securities={security}"
                
                try:
                    print(f"Fetching {protocol} {security} proxies from {country} using {base_url}...")
                    
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
                    
                    # Untuk melacak provider yang sudah diambil (untuk negara selain Indonesia)
                    providers_seen = set()
                    
                    for outbound in outbounds:
                        # Untuk protokol ss, gunakan "shadowsocks" sebagai tipe outbound internal
                        # Catatan: API hanya menerima "protocols=ss", bukan "protocols=shadowsocks"
                        if protocol == "ss":
                            actual_protocol = "shadowsocks"
                            # Gunakan format "shadowsocks" untuk protokol "ss" saat menerapkan format
                            protocol_format = "shadowsocks"
                        else:
                            actual_protocol = protocol
                            protocol_format = protocol
                            
                        # Periksa apakah tipe outbound cocok dengan protokol
                        type_match = outbound.get("type") == actual_protocol
                        
                        # Untuk protokol shadowsocks, tidak perlu memeriksa security (tls/ntls)
                        if actual_protocol == "shadowsocks":
                            security_match = True
                        else:
                            # Untuk protokol lain, periksa security (tls/ntls)
                            security_match = ((security == "tls" and outbound.get("tls", {}).get("enabled") == True) or
                                             (security == "ntls" and (not outbound.get("tls") or outbound.get("tls", {}).get("enabled") != True)))
                        
                        if type_match and security_match:
                            
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
                            
                            # Terapkan format konfigurasi jika tersedia
                            if outbound_format:
                                # Gunakan protocol_format untuk memilih template yang sesuai
                                outbound_copy = apply_outbound_format(outbound_copy, outbound_format, protocol_format)
                            
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
    
    # Simpan semua outbound ke file output yang ditentukan
    all_result = {
        "outbounds": all_outbounds
    }
    
    # Simpan ke file output yang ditentukan
    with open(output_name, "w", encoding="utf-8") as f:
        json.dump(all_result, f, indent=4, ensure_ascii=False)
    
    print(f"Total proxies collected: {len(all_outbounds)}")
    print(f"Successfully saved all proxies to {output_name}")
    
    # Buat summary untuk ditampilkan ke pengguna
    print("\nSummary:")
    
    # Hitung jumlah proxy per kategori (negara, protokol, keamanan)
    category_counts = {}
    for category_key, outbounds in outbounds_by_category.items():
        if outbounds:
            category_counts[category_key] = len(outbounds)
    
    # Tampilkan jumlah proxy per kategori
    for category_key, count in category_counts.items():
        country, protocol, security = category_key.split("_")
        flag_emoji = get_flag_emoji(country)
        country_name = get_country_name(country)
        print(f"- {flag_emoji} {country} {protocol.capitalize()} {security.upper()}: {count} proxies")
    
    return len(all_outbounds)

def main():
    # URL API untuk mendapatkan konfigurasi BFR
    # Kita bisa mendapatkan proxy dari beberapa negara
    # Daftar kode negara yang tersedia (diurutkan berdasarkan nama negara):
        # AR (Argentina)       AM (Armenia)         AU (Australia)   
        # AT (Austria)         BE (Belgium)         BR (Brazil)         
        # BG (Bulgaria)        CA (Canada)          CN (China)       
        # CY (Cyprus)          CZ (Czech Republic)  DK (Denmark)       
        # EE (Estonia)         FI (Finland)         FR (France)
        # DE (Germany)         HK (Hong Kong)       HU (Hungary)      
        # IN (India)           ID (Indonesia)       IE (Ireland)        
        # IT (Italy)           JP (Japan)           KZ (Kazakhstan)  
        # KR (South Korea)     LV (Latvia)          LT (Lithuania)     
        # LU (Luxembourg)      MY (Malaysia)        MU (Mauritius)
        # MX (Mexico)          MD (Moldova)         NL (Netherlands) 
        # PH (Philippines)     PL (Poland)          PT (Portugal)       
        # RO (Romania)         RU (Russia)          RS (Serbia)      
        # SG (Singapore)       SK (Slovakia)        ES (Spain)         
        # SE (Sweden)          CH (Switzerland)     TW (Taiwan)
        # TH (Thailand)        TR (Turkey)          UA (Ukraine)      
        # AE (United Arab E)   GB (United Kingdom)  US (United States)  
        # VN (Vietnam)         TF (French Southern Territories)
    

    # Parse command line arguments
    args = parse_args()
    
    # Tentukan file konfigurasi yang akan digunakan
    config_file = args.config_file if args.config_file else "config.ini"
    format_file = args.format_file if args.format_file else "config_format.ini"
    
    # Muat format outbound
    global outbound_format
    outbound_format = load_outbound_format(format_file)
    
    # Baca konfigurasi dari file
    configs = read_config_file(config_file)
    
    if not configs:
        print(f"Error: No valid configurations found in file '{config_file}'.")
        print("Please create a valid config.ini file with the following format:")
        print("#ID vless tls")
        print("Country_ID= ID")
        print("Protocol= vless")
        print("Security= tls")
        print("Output_Name= ID vless tls.json")
        print("\nAvailable country codes:")
        print("ID (Indonesia), SG (Singapore), US (United States), JP (Japan), KR (South Korea),")
        print("HK (Hong Kong), TW (Taiwan), GB (United Kingdom), DE (Germany), FR (France),")
        print("CA (Canada), AU (Australia), NL (Netherlands), RU (Russia), IN (India),")
        print("BR (Brazil), IT (Italy), ES (Spain), MX (Mexico), TR (Turkey)")
        print("\nAvailable protocols:")
        print("vless, trojan, ss")
        print("\nAvailable securities:")
        print("tls, ntls")
        print("\nUsage:")
        print("python3 extract_outbound.py                  # Use default config.ini file")
        print("python3 extract_outbound.py -f custom.ini    # Use custom.ini file")
        return
    
    print(f"Found {len(configs)} configuration(s) in file '{config_file}'.")
    
    # Process each configuration
    total_proxies = 0
    for i, config in enumerate(configs):
        print(f"\nProcessing configuration {i+1}/{len(configs)}...")
        proxies_count = process_single_config(config)
        total_proxies += proxies_count
    
    print(f"\nTotal proxies collected from all configurations: {total_proxies}")

if __name__ == "__main__":
    main()
