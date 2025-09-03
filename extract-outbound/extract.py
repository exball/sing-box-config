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
import copy
from datetime import datetime
from collections import defaultdict
import pytz
import hashlib

# Variabel global untuk menyimpan format outbound
outbound_format = None

# File untuk menyimpan history proxy yang sudah diambil
HISTORY_FILE = "proxy_history.json"

 # URL untuk mengambil proxy (4 domain dengan pembagian 6 jam)
PROXY_URL_PERIOD1 = "https://vpn.ex-vpn.my.id"      # Digunakan dari 00:00-05:59 (UTC+8)
PROXY_URL_PERIOD2 = "https://vpn.exbal.my.id"       # Digunakan dari 06:00-11:59 (UTC+8)
PROXY_URL_PERIOD3 = "https://proxy.xtunnel.my.id"   # Digunakan dari 12:00-17:59 (UTC+8)
PROXY_URL_PERIOD4 = "https://vpn.ex27.my.id"        # Digunakan dari 18:00-23:59 (UTC+8)

 # Fungsi untuk mendapatkan URL proxy berdasarkan waktu saat ini (UTC+8)
def get_proxy_base_url():
    """
    Mengembalikan URL dasar untuk mengambil proxy berdasarkan waktu saat ini.
    Pembagian 4 domain dengan periode 6 jam masing-masing:
    - Dari jam 00:00-05:59 (UTC+8): menggunakan vpn.ex-vpn.my.id
    - Dari jam 06:00-11:59 (UTC+8): menggunakan vpn.exbal.my.id
    - Dari jam 12:00-17:59 (UTC+8): menggunakan proxy.xtunnel.my.id
    - Dari jam 18:00-23:59 (UTC+8): menggunakan vpn.ex27.my.id
    """
    # Dapatkan waktu saat ini dalam UTC
    utc_now = datetime.now(pytz.UTC)
    # Konversi ke zona waktu UTC+8
    tz_utc8 = pytz.timezone('Asia/Singapore')  # Singapore menggunakan UTC+8
    now_utc8 = utc_now.astimezone(tz_utc8)
    # Ambil jam dalam format 24 jam
    current_hour = now_utc8.hour
    # Tentukan URL berdasarkan jam (pembagian 6 jam per domain)
    if 0 <= current_hour < 6:
        print(f"Waktu saat ini: {now_utc8.strftime('%H:%M:%S')} (UTC+8) - Menggunakan {PROXY_URL_PERIOD1}")
        return PROXY_URL_PERIOD1
    elif 6 <= current_hour < 12:
        print(f"Waktu saat ini: {now_utc8.strftime('%H:%M:%S')} (UTC+8) - Menggunakan {PROXY_URL_PERIOD2}")
        return PROXY_URL_PERIOD2
    elif 12 <= current_hour < 18:
        print(f"Waktu saat ini: {now_utc8.strftime('%H:%M:%S')} (UTC+8) - Menggunakan {PROXY_URL_PERIOD3}")
        return PROXY_URL_PERIOD3
    else:
        print(f"Waktu saat ini: {now_utc8.strftime('%H:%M:%S')} (UTC+8) - Menggunakan {PROXY_URL_PERIOD4}")
        return PROXY_URL_PERIOD4

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
def generate_proxy_id(outbound):
    """
    Generate unique ID untuk proxy berdasarkan server, port, dan beberapa field unik lainnya.
    """
    # Ambil field-field yang unik untuk membuat ID
    server = outbound.get("server", "")
    port = str(outbound.get("server_port", ""))
    uuid = outbound.get("uuid", "")
    password = outbound.get("password", "")
    
    # Gabungkan field-field untuk membuat string unik
    unique_string = f"{server}:{port}:{uuid}:{password}"
    
    # Generate hash MD5 untuk ID yang lebih pendek
    return hashlib.md5(unique_string.encode()).hexdigest()[:12]

def migrate_old_history_format(history):
    """
    Migrasi format history lama ke format baru yang menggunakan Country + Provider tracking.
    
    Args:
        history: Dictionary history dalam format lama atau baru
    
    Returns:
        Dictionary history dalam format baru: {country_name: {provider_name: {used_ip_ports, last_reset}}}
    """
    migrated_history = {}
    
    for key, value in history.items():
        # Skip provider_selection keys dari format lama
        if key.startswith("provider_selection_"):
            continue
            
        if isinstance(value, dict):
            # Cek apakah ini sudah format baru (country -> provider -> data)
            if key.endswith(" proxy"):
                # Sudah format baru - copy langsung
                migrated_history[key] = value
                continue
            
            # Format lama (provider -> category -> data)
            # Extract provider name (hapus suffix seperti " ws tls [proxy]")
            provider_name = key
            if " ws " in provider_name and " [proxy]" in provider_name:
                # Ambil bagian sebelum " ws "
                provider_name = provider_name.split(" ws ")[0]
            
            for category_key, category_data in value.items():
                # Parse category_key untuk mendapatkan country
                if "_" in category_key:
                    country_code = category_key.split("_")[0]
                    country_name = f"{country_code} proxy"
                    
                    # Inisialisasi country jika belum ada
                    if country_name not in migrated_history:
                        migrated_history[country_name] = {}
                    
                    # Jika masih menggunakan format lama dengan last_index atau sudah format baru
                    if isinstance(category_data, dict):
                        if "last_index" in category_data:
                            # Format lama - konversi ke format baru
                            migrated_history[country_name][provider_name] = {
                                "used_ip_ports": [],  # Mulai dengan list kosong
                                "last_reset": datetime.now().isoformat()
                            }
                            print(f"🔄 Migrated old history format for '{country_name}' provider '{provider_name}'")
                        elif "used_ip_ports" in category_data:
                            # Sudah format baru - merge dengan existing data
                            if provider_name not in migrated_history[country_name]:
                                migrated_history[country_name][provider_name] = {
                                    "used_ip_ports": [],
                                    "last_reset": datetime.now().isoformat()
                                }
                            
                            # Merge used_ip_ports (hindari duplikasi)
                            existing_ips = set(migrated_history[country_name][provider_name]["used_ip_ports"])
                            new_ips = set(category_data.get("used_ip_ports", []))
                            merged_ips = list(existing_ips.union(new_ips))
                            migrated_history[country_name][provider_name]["used_ip_ports"] = merged_ips
    
    return migrated_history

def load_proxy_history():
    """
    Load history proxy yang sudah diambil dari file dan migrasi jika diperlukan.
    Format baru: {
        "provider_name": {
            "country_protocol_security": {
                "used_ip_ports": ["IP1:PORT1", "IP2:PORT2", ...],
                "last_reset": "2024-01-01T00:00:00"
            }
        }
    }
    """
    if not os.path.exists(HISTORY_FILE):
        return {}
    
    try:
        with open(HISTORY_FILE, 'r', encoding='utf-8') as f:
            history = json.load(f)
            
        # Migrasi format lama ke format baru jika diperlukan
        migrated_history = migrate_old_history_format(history)
        
        # Jika ada perubahan, simpan format baru
        if migrated_history != history:
            print("📋 Migrating proxy history to new IP:Port tracking format...")
            save_proxy_history(migrated_history)
            return migrated_history
            
        return history
    except Exception as e:
        print(f"Warning: Error loading proxy history: {e}")
        return {}

def save_proxy_history(history):
    """
    Simpan history proxy ke file.
    """
    try:
        with open(HISTORY_FILE, 'w', encoding='utf-8') as f:
            json.dump(history, f, indent=2, ensure_ascii=False)
    except Exception as e:
        print(f"Warning: Error saving proxy history: {e}")

def get_providers_with_unused_proxies(available_providers, country_code, history):
    """
    Dapatkan provider yang masih memiliki proxy dengan IP:Port yang belum digunakan.
    Menggunakan sistem Country + Provider tracking.
    
    Args:
        available_providers: List tuple (provider_name, proxies)
        country_code: Kode negara (ID, SG, JP, dll)
        history: Dictionary history
    
    Returns:
        List tuple (provider_name, proxies, unused_count) yang memiliki proxy belum digunakan
    """
    providers_with_unused = []
    
    for provider_name, proxies in available_providers:
        unused_proxies = get_unused_proxies_for_provider(provider_name, country_code, proxies, history)
        if unused_proxies:
            providers_with_unused.append((provider_name, proxies, len(unused_proxies)))
    
    return providers_with_unused

def get_next_providers(available_providers, country_code, max_count, history):
    """
    Pilih provider berikutnya dengan sistem Country + Provider tracking.
    Provider bisa dipilih berkali-kali selama memiliki proxy dengan IP:Port yang berbeda.
    
    Args:
        available_providers: List tuple (provider_name, proxies)
        country_code: Kode negara (ID, SG, JP, dll)
        max_count: Jumlah maksimal proxy yang ingin dipilih (bukan provider)
        history: Dictionary history
    
    Returns:
        List provider yang dipilih dan history yang diupdate
    """
    if not available_providers:
        return [], history
    
    # Dapatkan provider yang masih memiliki proxy belum digunakan
    providers_with_unused = get_providers_with_unused_proxies(available_providers, country_code, history)
    
    if not providers_with_unused:
        print(f"⚠️ Tidak ada provider dengan proxy baru untuk negara '{country_code}', mencoba reset beberapa provider...")
        # Coba reset provider yang tidak memiliki proxy unused
        for provider_name, proxies in available_providers:
            unused_proxies = get_unused_proxies_for_provider(provider_name, country_code, proxies, history)
            if not unused_proxies and proxies:  # Provider ada proxy tapi semua sudah digunakan
                history = reset_provider_history(provider_name, country_code, history)
        
        # Coba lagi setelah reset
        providers_with_unused = get_providers_with_unused_proxies(available_providers, country_code, history)
    
    if not providers_with_unused:
        print(f"❌ Tidak ada provider yang valid untuk negara '{country_code}'")
        return [], history
    
    # Urutkan provider berdasarkan jumlah proxy yang belum digunakan (descending)
    # Ini memberikan prioritas pada provider dengan lebih banyak pilihan
    providers_with_unused.sort(key=lambda x: x[2], reverse=True)
    
    selected_providers = []
    total_proxies_needed = max_count
    
    # Pilih provider sampai kebutuhan proxy terpenuhi
    for provider_name, all_proxies, unused_count in providers_with_unused:
        if total_proxies_needed <= 0:
            break
            
        # Tentukan berapa proxy yang akan diambil dari provider ini
        # Maksimal 1 proxy per provider per iterasi untuk rotasi yang baik
        proxies_from_this_provider = min(1, unused_count, total_proxies_needed)
        
        if proxies_from_this_provider > 0:
            selected_providers.append((provider_name, all_proxies))
            total_proxies_needed -= proxies_from_this_provider
    
    # Jika masih butuh lebih banyak proxy, ambil lagi dari provider yang sama
    # (ini memungkinkan provider muncul berkali-kali jika punya banyak proxy unused)
    while total_proxies_needed > 0 and providers_with_unused:
        added_any = False
        for provider_name, all_proxies, unused_count in providers_with_unused:
            if total_proxies_needed <= 0:
                break
                
            # Hitung berapa proxy yang sudah akan diambil dari provider ini
            already_selected_count = sum(1 for p_name, _ in selected_providers if p_name == provider_name)
            remaining_unused = unused_count - already_selected_count
            
            if remaining_unused > 0:
                selected_providers.append((provider_name, all_proxies))
                total_proxies_needed -= 1
                added_any = True
        
        # Jika tidak ada provider yang bisa memberikan proxy lagi, keluar dari loop
        if not added_any:
            break
    
    print(f"📋 Dipilih {len(selected_providers)} provider instances untuk negara '{country_code}'")
    provider_counts = {}
    for provider_name, _ in selected_providers:
        provider_counts[provider_name] = provider_counts.get(provider_name, 0) + 1
    
    for provider_name, count in provider_counts.items():
        # Extract provider name untuk display
        clean_name = provider_name
        if " ws " in clean_name and " [proxy]" in clean_name:
            clean_name = clean_name.split(" ws ")[0]
        print(f"   - {clean_name}: {count} proxy")
    
    return selected_providers, history

def extract_ip_port_from_proxy(proxy):
    """
    Ekstrak IP dan Port dari proxy untuk tracking.
    Untuk vless/trojan, IP:Port sebenarnya ada di transport.path dengan format /IP-PORT
    
    Args:
        proxy: Dictionary proxy data
    
    Returns:
        String dalam format "IP:PORT" atau None jika tidak ditemukan
    """
    try:
        # Prioritas 1: Ambil dari transport.path (untuk vless/trojan)
        if 'transport' in proxy and isinstance(proxy['transport'], dict):
            transport = proxy['transport']
            if 'path' in transport and transport['path']:
                path = transport['path']
                # Format path biasanya: /IP-PORT atau /IP:PORT
                # Contoh: /149.129.250.8-443 atau /8.215.77.247-49640
                if path.startswith('/'):
                    path_content = path[1:]  # Hapus '/' di awal
                    
                    # Coba format IP-PORT (dengan dash)
                    if '-' in path_content:
                        parts = path_content.split('-')
                        if len(parts) >= 2:
                            ip = parts[0]
                            port = parts[1]
                            # Validasi sederhana IP dan port
                            if ip and port and port.isdigit():
                                return f"{ip}:{port}"
                    
                    # Coba format IP:PORT (dengan colon)
                    if ':' in path_content:
                        parts = path_content.split(':')
                        if len(parts) >= 2:
                            ip = parts[0]
                            port = parts[1]
                            # Validasi sederhana IP dan port
                            if ip and port and port.isdigit():
                                return f"{ip}:{port}"
        
        # Prioritas 2: Fallback ke server dan server_port (untuk format lain)
        if 'server' in proxy and 'server_port' in proxy:
            server = proxy['server']
            port = proxy['server_port']
            # Hanya gunakan jika bukan CDN server
            if server and server != 'quiz.int.vidio.com':
                return f"{server}:{port}"
        
        # Prioritas 3: Coba format clash (hostname dan port)
        if 'hostname' in proxy and 'port' in proxy:
            hostname = proxy['hostname']
            port = proxy['port']
            if hostname and hostname != 'quiz.int.vidio.com':
                return f"{hostname}:{port}"
        
        # Jika semua gagal, kembalikan None
        return None
        
    except Exception as e:
        print(f"Warning: Gagal ekstrak IP:Port dari proxy: {e}")
        return None

def get_unused_proxies_for_provider(provider_name, country_code, all_proxies, history):
    """
    Dapatkan proxy yang belum pernah digunakan berdasarkan IP:Port.
    Menggunakan sistem Country + Provider tracking.
    
    Args:
        provider_name: Nama provider (tanpa suffix ws/tls/proxy)
        country_code: Kode negara (ID, SG, JP, dll)
        all_proxies: List semua proxy dari provider ini
        history: Dictionary history
    
    Returns:
        List proxy yang belum pernah digunakan
    """
    if not all_proxies:
        return []
    
    # Format country name sederhana
    country_name = f"{country_code} proxy"
    
    # Extract provider name (hapus suffix seperti " ws tls [proxy]")
    clean_provider_name = provider_name
    if " ws " in clean_provider_name and " [proxy]" in clean_provider_name:
        clean_provider_name = clean_provider_name.split(" ws ")[0]
    
    # Inisialisasi history untuk country ini jika belum ada
    if country_name not in history:
        history[country_name] = {}
    
    if clean_provider_name not in history[country_name]:
        history[country_name][clean_provider_name] = {
            "used_ip_ports": [],
            "last_reset": datetime.now().isoformat()
        }
    
    provider_history = history[country_name][clean_provider_name]
    used_ip_ports = set(provider_history.get("used_ip_ports", []))
    
    # Filter proxy yang belum pernah digunakan
    unused_proxies = []
    for proxy in all_proxies:
        ip_port = extract_ip_port_from_proxy(proxy)
        if ip_port and ip_port not in used_ip_ports:
            unused_proxies.append(proxy)
    
    return unused_proxies

def reset_provider_history(provider_name, country_code, history):
    """
    Reset history untuk provider tertentu ketika semua proxy sudah digunakan.
    Menggunakan sistem Country + Provider tracking.
    
    Args:
        provider_name: Nama provider
        country_code: Kode negara (ID, SG, JP, dll)
        history: Dictionary history
    
    Returns:
        Updated history
    """
    # Format country name sederhana
    country_name = f"{country_code} proxy"
    
    # Extract provider name (hapus suffix seperti " ws tls [proxy]")
    clean_provider_name = provider_name
    if " ws " in clean_provider_name and " [proxy]" in clean_provider_name:
        clean_provider_name = clean_provider_name.split(" ws ")[0]
    
    if country_name in history and clean_provider_name in history[country_name]:
        print(f"🔄 Reset history untuk '{country_name}' provider '{clean_provider_name}' - semua proxy sudah pernah digunakan")
        history[country_name][clean_provider_name] = {
            "used_ip_ports": [],
            "last_reset": datetime.now().isoformat()
        }
    
    return history

def smart_reset_based_on_availability(country_code, available_providers, history):
    """
    Reset provider berdasarkan perbandingan total proxy vs used proxy.
    Reset hanya provider yang benar-benar habis (total = used).
    
    Args:
        country_code: Kode negara (ID, SG, JP, dll)
        available_providers: List tuple (provider_name, proxies) dari API
        history: Dictionary history
    
    Returns:
        Updated history dan jumlah provider yang direset
    """
    country_key = f"{country_code} proxy"
    reset_count = 0
    reset_providers = []
    
    print(f"\n🔍 Analyzing provider availability for {country_code}:")
    
    for provider_name, all_proxies in available_providers:
        # Hitung total proxy dari API
        total_proxies = len(all_proxies)
        
        # Extract provider name (hapus suffix seperti " ws tls [proxy]")
        clean_provider_name = provider_name
        if " ws " in clean_provider_name and " [proxy]" in clean_provider_name:
            clean_provider_name = clean_provider_name.split(" ws ")[0]
        
        # Hitung proxy yang sudah digunakan dari history
        used_count = 0
        if country_key in history and clean_provider_name in history[country_key]:
            used_ip_ports = history[country_key][clean_provider_name].get("used_ip_ports", [])
            used_count = len(used_ip_ports)
        
        available_count = total_proxies - used_count
        
        print(f"  📊 {clean_provider_name}: {total_proxies} total - {used_count} used = {available_count} available")
        
        # Reset jika semua proxy sudah digunakan (available <= 0 tapi total > 0)
        if available_count <= 0 and total_proxies > 0:
            print(f"  🔄 Resetting {clean_provider_name} (all proxies used)")
            history = reset_provider_history(provider_name, country_code, history)
            reset_count += 1
            reset_providers.append(clean_provider_name)
        elif available_count > 0:
            print(f"  ✅ {clean_provider_name} still has {available_count} unused proxies")
        else:
            print(f"  ⚠️ {clean_provider_name} has no proxies from API")
    
    if reset_count > 0:
        print(f"\n✅ Smart reset completed: {reset_count} providers reset")
        print(f"🔄 Reset providers: {', '.join(reset_providers)}")
        print("💡 These providers can now be used again immediately")
    else:
        print(f"\n✅ No reset needed - all providers still have available proxies")
    
    return history, reset_count

def get_next_proxies_for_provider(provider_name, country_code, all_proxies, max_count, history):
    """
    Ambil proxy berikutnya untuk provider dengan sistem Country + Provider tracking.
    
    Args:
        provider_name: Nama provider
        country_code: Kode negara (ID, SG, JP, dll)
        all_proxies: List semua proxy dari provider ini
        max_count: Jumlah maksimal proxy yang ingin diambil
        history: Dictionary history
    
    Returns:
        List proxy yang dipilih dan history yang diupdate
    """
    if not all_proxies:
        return [], history
    
    # Dapatkan proxy yang belum pernah digunakan
    unused_proxies = get_unused_proxies_for_provider(provider_name, country_code, all_proxies, history)
    
    # Jika tidak ada proxy yang belum digunakan, reset history provider ini
    if not unused_proxies:
        print(f"⚠️ Provider '{provider_name}' untuk negara '{country_code}' tidak memiliki proxy baru, melakukan reset...")
        history = reset_provider_history(provider_name, country_code, history)
        unused_proxies = get_unused_proxies_for_provider(provider_name, country_code, all_proxies, history)
    
    # Jika masih tidak ada proxy setelah reset, kembalikan kosong
    if not unused_proxies:
        print(f"❌ Provider '{provider_name}' untuk negara '{country_code}' tidak memiliki proxy yang valid")
        return [], history
    
    # Tentukan berapa banyak proxy yang akan diambil
    proxies_to_take = min(max_count, len(unused_proxies))
    
    # Pilih proxy secara acak dari yang belum pernah digunakan
    selected_proxies = random.sample(unused_proxies, proxies_to_take)
    
    # Format country name sederhana
    country_name = f"{country_code} proxy"
    
    # Extract provider name (hapus suffix seperti " ws tls [proxy]")
    clean_provider_name = provider_name
    if " ws " in clean_provider_name and " [proxy]" in clean_provider_name:
        clean_provider_name = clean_provider_name.split(" ws ")[0]
    
    # Update history dengan IP:Port yang baru digunakan
    if country_name not in history:
        history[country_name] = {}
    
    if clean_provider_name not in history[country_name]:
        history[country_name][clean_provider_name] = {
            "used_ip_ports": [],
            "last_reset": datetime.now().isoformat()
        }
    
    # Tambahkan IP:Port yang baru digunakan ke history
    for proxy in selected_proxies:
        ip_port = extract_ip_port_from_proxy(proxy)
        if ip_port:
            history[country_name][clean_provider_name]["used_ip_ports"].append(ip_port)
    
    print(f"✅ Dipilih {len(selected_proxies)} proxy dari provider '{clean_provider_name}' untuk '{country_name}'")
    print(f"📊 Total IP:Port yang sudah digunakan: {len(history[country_name][clean_provider_name]['used_ip_ports'])}")
    
    return selected_proxies, history

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
    Format= bfr    # Pengaturan global untuk semua konfigurasi
    
    #Komentar (opsional)
    Country_ID= ID, SG
    Protocol= vless, trojan
    Security= tls, ntls
    Output_Name= output
    
    #Komentar untuk blok berikutnya (opsional)
    Country_ID= JP
    ...
    """
    if not os.path.exists(file_path):
        print(f"Error: File konfigurasi '{file_path}' tidak ditemukan.")
        return [], "bfr"
    
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()
    except Exception as e:
        print(f"Error: Gagal membaca file konfigurasi '{file_path}': {str(e)}")
        return [], "bfr"
    
    # Baca pengaturan global Format
    global_format = "bfr"  # Default format
    lines = content.split('\n')
    
    # Cari pengaturan Format global di baris-baris awal
    for line in lines:
        line = line.strip()
        if line.startswith('Format='):
            try:
                global_format = line.split('=', 1)[1].strip().lower()
                
                # Validasi format
                valid_formats = ["bfr", "raw", "clash", "sfa", "v2ray"]
                if global_format not in valid_formats:
                    print(f"Warning: Invalid format type: {global_format}. Using default format: bfr")
                    global_format = "bfr"
                
                break
            except IndexError:
                print("Warning: Format line tidak valid, menggunakan default: bfr")
                global_format = "bfr"
    
    # Pisahkan file menjadi blok-blok konfigurasi
    # Blok dipisahkan oleh baris kosong atau baris yang dimulai dengan #
    blocks = []
    current_block = []
    
    for i, line in enumerate(lines):
        line_num = i + 1  # Line numbers start at 1
        line = line.strip()
        
        # Skip pengaturan global Format
        if line.startswith('Format='):
            continue
        
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
            
        # Validasi Max_Proxies_Per_Provider jika ada
        if "Max_Proxies_Per_Provider" in config:
            try:
                max_proxies_value = config["Max_Proxies_Per_Provider"][0]
                max_proxies_int = int(max_proxies_value)
                if max_proxies_int <= 0:
                    print(f"Warning: Blok konfigurasi #{block_index+1} memiliki Max_Proxies_Per_Provider tidak valid: {max_proxies_value}. Menggunakan nilai default.")
                    config["Max_Proxies_Per_Provider"] = ["1"]
                else:
                    config["Max_Proxies_Per_Provider"] = [str(max_proxies_int)]
            except (ValueError, IndexError):
                print(f"Warning: Blok konfigurasi #{block_index+1} memiliki Max_Proxies_Per_Provider tidak valid. Menggunakan nilai default (1).")
                config["Max_Proxies_Per_Provider"] = ["1"]
            
        configs.append(config)
    
    return configs, global_format

def load_clash_format(format_file="clash_proxies.ini"):
    """
    Membaca format proxy clash dari file konfigurasi format.
    File format berisi template untuk setiap jenis proxy dalam format YAML.
    """
    format_data = {}
    
    if not os.path.exists(format_file):
        print(f"Warning: Format file '{format_file}' tidak ditemukan.")
        return format_data
    
    try:
        import yaml
        with open(format_file, 'r', encoding='utf-8') as f:
            format_data = yaml.safe_load(f)
    except ImportError:
        print(f"Error: PyYAML tidak tersedia, tidak bisa membaca format file '{format_file}'")
        return {}
    except yaml.YAMLError as e:
        print(f"Error: Format file '{format_file}' tidak valid YAML: {e}")
        return {}
    except Exception as e:
        print(f"Error: Gagal membaca format file '{format_file}': {e}")
        return {}
    
    return format_data if format_data else {}

def apply_clash_format(proxy, format_template):
    """
    Menerapkan format template pada proxy clash yang diambil dari API.
    Logika:
    - Field kosong/null di template → gunakan nilai asli dari API
    - Field ada nilainya di template → gunakan nilai dari template (override)
    """
    if not proxy or not format_template:
        return proxy
    
    # Mulai dengan data asli dari API
    formatted_proxy = copy.deepcopy(proxy)
    
    # Fungsi untuk mengecek apakah nilai kosong
    def is_empty_value(value):
        return value is None or value == "" or value == [] or value == {}
    
    # Fungsi untuk menerapkan template secara selektif
    def apply_template_selectively(target, template):
        for key, template_value in template.items():
            if isinstance(template_value, dict):
                # Jika template value adalah dict, proses secara rekursif
                if key not in target:
                    target[key] = {}
                elif not isinstance(target[key], dict):
                    target[key] = {}
                apply_template_selectively(target[key], template_value)
            else:
                # Jika template value tidak kosong, gunakan nilai dari template
                if not is_empty_value(template_value):
                    target[key] = template_value
                # Jika template value kosong, biarkan nilai asli dari API (tidak diubah)
    
    # Terapkan template secara selektif
    apply_template_selectively(formatted_proxy, format_template)
    
    return formatted_proxy

def load_outbound_format(format_file="sing_outbound.ini"):
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

def apply_outbound_format(outbound, format_template):
    """
    Menerapkan format template ke outbound berdasarkan protokol.
    - Pilih template yang sesuai berdasarkan protokol (vless atau trojan)
    - Jika field di template kosong ("") dan field tersebut ada di outbound asli, gunakan nilai dari outbound asli
    - Jika field di template kosong ("") dan field tersebut tidak ada di outbound asli, jangan tambahkan field tersebut
    - Jika field di template memiliki nilai, gunakan nilai tersebut
    """
    if not format_template:
        return outbound
    
    # Tentukan protokol outbound
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

def reset_proxy_history():
    """
    Reset proxy history dengan menghapus file history.
    """
    if os.path.exists(HISTORY_FILE):
        os.remove(HISTORY_FILE)
        print(f"Proxy history reset. File {HISTORY_FILE} deleted.")
    else:
        print(f"No history file found at {HISTORY_FILE}")

def parse_args():
    """
    Parse command line arguments.
    """
    parser = argparse.ArgumentParser(description='Extract outbound configurations based on specified criteria.')
    parser.add_argument('--config-file', '-f', type=str, help='Path to configuration file (default: config.ini)')
    parser.add_argument('--format-file', '-o', type=str, help='Path to outbound format file (default: sing_outbound.ini)')
    parser.add_argument('--reset-history', '-r', action='store_true', help='Reset proxy history before extraction')
    
    return parser.parse_args()

def process_single_config(config, format_type="bfr", format_file="sing_outbound.ini"):
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
    max_proxies_per_provider = int(config.get("Max_Proxies_Per_Provider", ["1"])[0])
    
    # Tambahkan ekstensi berdasarkan format jika belum ada
    if output_name and not any(output_name.endswith(ext) for ext in ['.json', '.yaml', '.yml', '.txt']):
        if format_type == "clash":
            output_name += ".yaml"
        elif format_type in ["bfr", "v2ray"]:
            output_name += ".json"
        elif format_type in ["raw", "sfa"]:
            output_name += ".txt"
        else:
            # Default ke json untuk format yang tidak dikenal
            output_name += ".json"
    
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
    invalid_protocols = [p for p in protocols if p not in ["vless", "trojan"]]
    invalid_securities = [s for s in securities if s not in ["tls", "ntls"]]
    
    # Validasi format type
    valid_formats = ["bfr", "raw", "clash", "sfa", "v2ray"]
    if format_type not in valid_formats:
        print(f"Warning: Invalid format type: {format_type}. Using default format: bfr")
        format_type = "bfr"
    
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
    print(f"- Format: {format_type}")
    print(f"- Max proxies per provider: {max_proxies_per_provider}")
    print(f"- Output file: {output_name}")
    
    # Dictionary untuk menyimpan outbound berdasarkan negara, protokol, dan keamanan
    outbounds_by_category = defaultdict(list)
    all_outbounds = []
    
    # Load proxy history
    proxy_history = load_proxy_history()
    print(f"Loaded proxy history from {HISTORY_FILE}")
    
    # Ambil outbound untuk setiap kombinasi negara, protokol, dan keamanan
    # Dapatkan URL dasar berdasarkan waktu saat ini
    base_url = get_proxy_base_url()
    
    for country in countries:
        for protocol in protocols:
            for security in securities:
                url = f"{base_url}/api/{format_type}?cc={country}&protocols={protocol}&securities={security}&limit=100"
                
                try:
                    print(f"Fetching {protocol} {security} proxies from {country}...")
                    
                    # Mengambil konfigurasi dengan retry
                    response = fetch_with_retry(url)
                    response_text = response.text
                    
                    # Parse response berdasarkan format
                    if format_type == "bfr":
                        # Mencari bagian JSON dalam konfigurasi BFR
                        json_match = re.search(r'(\{[\s\S]*\})', response_text)
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
                    
                    elif format_type == "raw":
                        # Skip raw format karena tidak menghasilkan JSON outbound
                        print(f"Warning: Raw format tidak mendukung ekstraksi outbound untuk {country}")
                        continue
                    
                    elif format_type == "clash":
                        # Parse YAML untuk format clash
                        try:
                            import yaml
                            config_yaml = yaml.safe_load(response_text)
                            
                            # Ekstrak bagian proxies dari clash config
                            if "proxies" not in config_yaml:
                                print(f"Warning: No 'proxies' section found in clash configuration for {country}")
                                continue
                            
                            # Load clash format template
                            clash_format = load_clash_format(format_file)
                            
                            # Apply format template to each proxy
                            formatted_proxies = []
                            for proxy in config_yaml["proxies"]:
                                proxy_type = proxy.get("type", "").lower()
                                if proxy_type in clash_format:
                                    formatted_proxy = apply_clash_format(proxy, clash_format[proxy_type])
                                    formatted_proxies.append(formatted_proxy)
                                else:
                                    # Jika tidak ada template, gunakan proxy asli
                                    formatted_proxies.append(proxy)
                            
                            # Update proxies section with formatted proxies
                            config_yaml["proxies"] = formatted_proxies
                            config = config_yaml
                            
                            if not config["proxies"]:
                                print(f"Warning: No valid proxies found in clash configuration for {country}")
                                continue
                                
                        except ImportError:
                            print(f"Warning: PyYAML not installed, cannot parse clash format for {country}")
                            continue
                        except yaml.YAMLError as e:
                            print(f"Warning: Error parsing YAML for {country}: {e}")
                            continue
                    
                    elif format_type in ["sfa", "v2ray"]:
                        # Format ini sudah dalam format final, tidak bisa di-extract sebagai outbound
                        print(f"Warning: Format {format_type} tidak mendukung ekstraksi outbound untuk {country}")
                        continue
                    
                    else:
                        print(f"Warning: Format {format_type} tidak didukung untuk {country}")
                        continue
                    
                    # Ekstrak bagian Outbound atau Proxies
                    if format_type == "clash":
                        if "proxies" not in config:
                            print(f"Warning: No 'proxies' section found in configuration for {country}")
                            continue
                        outbounds = config["proxies"]
                    else:
                        if "outbounds" not in config:
                            print(f"Warning: No 'outbounds' section found in configuration for {country}")
                            continue
                        outbounds = config["outbounds"]
                    
                    # Filter outbound berdasarkan protokol dan keamanan
                    filtered_outbounds = []
                    
                    # Kelompokkan proxy berdasarkan provider untuk semua negara (termasuk Indonesia)
                    provider_proxies = defaultdict(list)
                    
                    for outbound in outbounds:
                        # Filter berdasarkan format
                        if format_type == "clash":
                            # Filter untuk clash format
                            tls_condition = False
                            if protocol == "trojan":
                                # Untuk trojan, TLS terimplikasi dengan adanya SNI
                                if security == "tls":
                                    tls_condition = outbound.get("sni") is not None
                                else:  # ntls
                                    tls_condition = outbound.get("sni") is None
                            else:
                                # Untuk protokol lain (vless, vmess, dll)
                                if security == "tls":
                                    tls_condition = outbound.get("tls") == True
                                else:  # ntls
                                    tls_condition = outbound.get("tls") != True
                            
                            if outbound.get("type") == protocol and tls_condition:
                                
                                # Tambahkan emoji bendera ke name
                                provider_name = "unknown"
                                if "name" in outbound:
                                    name_parts = outbound["name"].split(" ")
                                    if len(name_parts) >= 3:
                                        # Ambil nomor urut
                                        number = name_parts[0]
                                        # Tambahkan emoji bendera
                                        flag_emoji = get_flag_emoji(country)
                                        # Ambil provider dan seterusnya (skip nomor dan emoji asli)
                                        provider_parts = name_parts[2:]
                                        # Ekstrak nama provider untuk tracking
                                        provider_name = ' '.join(provider_parts).lower()
                                        # Gabungkan kembali dengan emoji yang benar
                                        clean_name = f"{number} {flag_emoji} {' '.join(provider_parts)}"
                                        outbound["name"] = clean_name
                                
                                # Buat salinan outbound
                                outbound_copy = outbound.copy()
                                
                                # Terapkan format konfigurasi clash jika tersedia
                                if outbound_format:
                                    proxy_type = outbound.get("type", "").lower()
                                    if proxy_type in outbound_format:
                                        outbound_copy = apply_clash_format(outbound_copy, outbound_format[proxy_type])
                                
                                # Kelompokkan proxy berdasarkan provider untuk sistem rotasi
                                provider_proxies[provider_name].append(outbound_copy)
                        else:
                            # Filter untuk sing-box format
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
                                
                                # Terapkan format konfigurasi jika tersedia
                                if outbound_format:
                                    outbound_copy = apply_outbound_format(outbound_copy, outbound_format)
                                
                                # Kelompokkan proxy berdasarkan provider untuk sistem rotasi
                                provider_proxies[provider_name].append(outbound_copy)
                    
                    # Gunakan sistem Country + Provider tracking untuk semua negara
                    # Ambil provider yang tersedia
                    available_providers = [(name, proxies) for name, proxies in provider_proxies.items() if proxies]
                    
                    # Lakukan smart reset berdasarkan availability sebelum pemilihan provider
                    proxy_history, reset_count = smart_reset_based_on_availability(
                        country, available_providers, proxy_history
                    )
                    
                    # Pilih provider dengan sistem Country + Provider tracking
                    # Sistem baru memungkinkan provider yang sama muncul berkali-kali jika punya IP:Port berbeda
                    selected_providers, proxy_history = get_next_providers(
                        available_providers, country, max_proxies_per_provider, proxy_history
                    )
                    
                    for provider_name, proxies in selected_providers:
                        # Ambil 1 proxy dari provider ini dengan sistem Country + Provider tracking
                        selected_proxies, proxy_history = get_next_proxies_for_provider(
                            provider_name, country, proxies, 1, proxy_history  # max_count = 1
                        )
                        
                        filtered_outbounds.extend(selected_proxies)
                        
                        # Debug info dengan informasi IP:Port
                        if selected_proxies:
                            for proxy in selected_proxies:
                                ip_port = extract_ip_port_from_proxy(proxy)
                                # Extract provider name untuk display
                                clean_provider_name = provider_name
                                if " ws " in clean_provider_name and " [proxy]" in clean_provider_name:
                                    clean_provider_name = clean_provider_name.split(" ws ")[0]
                                print(f"✅ Added {country} proxy from '{clean_provider_name}': {ip_port}")
                        else:
                            print(f"⚠️ No proxy selected from '{provider_name}' for {country}")
                    
                    print(f"Found {len(filtered_outbounds)} {protocol} {security} proxies from {country}")
                    
                    # Simpan outbound berdasarkan kategori (negara, protokol, keamanan)
                    category_key = f"{country}_{protocol}_{security}"
                    outbounds_by_category[category_key].extend(filtered_outbounds)
                    
                    # Juga simpan semua outbound dalam satu list
                    all_outbounds.extend(filtered_outbounds)
                
                except Exception as e:
                    print(f"Error processing {country} {protocol} {security}: {e}")
    
    # Simpan semua outbound ke file output yang ditentukan
    if format_type == "clash":
        # Untuk format clash, simpan sebagai YAML dengan struktur clash
        all_result = {
            "proxies": all_outbounds
        }
    else:
        # Untuk format lainnya, simpan sebagai JSON dengan struktur sing-box
        all_result = {
            "outbounds": all_outbounds
        }
    
    # Buat direktori provider jika belum ada
    # Gunakan path relatif ke parent directory jika script dijalankan dari extract-outbound
    if os.path.basename(os.getcwd()) == "extract-outbound":
        output_dir = "../provider"
    else:
        output_dir = "provider"
    
    if not os.path.exists(output_dir):
        os.makedirs(output_dir)
        print(f"Created directory: {output_dir}")
    
    # Simpan ke file output yang ditentukan di dalam direktori provider
    output_path = os.path.join(output_dir, output_name)
    if format_type == "clash":
        try:
            import yaml
            with open(output_path, "w", encoding="utf-8") as f:
                yaml.dump(all_result, f, default_flow_style=False, allow_unicode=True)
        except ImportError:
            print("Warning: PyYAML not available, saving as JSON instead")
            with open(output_path, "w", encoding="utf-8") as f:
                json.dump(all_result, f, indent=4, ensure_ascii=False)
    else:
        with open(output_path, "w", encoding="utf-8") as f:
            json.dump(all_result, f, indent=4, ensure_ascii=False)
    
    print(f"Total proxies collected: {len(all_outbounds)}")
    print(f"Successfully saved all proxies to {output_path}")
    
    # Simpan proxy history
    save_proxy_history(proxy_history)
    print(f"Proxy history saved to {HISTORY_FILE}")
    
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

def check_dependencies():
    """
    Memeriksa dan menginstal dependensi yang diperlukan jika belum ada.
    """
    try:
        import pytz
    except ImportError:
        print("Menginstal paket pytz...")
        import subprocess
        subprocess.check_call([sys.executable, "-m", "pip", "install", "pytz"])
        print("Paket pytz berhasil diinstal.")

def main():
    # Periksa dependensi
    check_dependencies()
    
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
    
    # Reset history jika diminta
    if args.reset_history:
        reset_proxy_history()
    
    # Tentukan file konfigurasi yang akan digunakan
    config_file = args.config_file if args.config_file else "config.ini"
    
    # Baca konfigurasi dari file untuk menentukan format file yang tepat
    configs, global_format = read_config_file(config_file)
    
    # Tentukan format file berdasarkan global format atau argument
    if args.format_file:
        format_file = args.format_file
    elif global_format == "clash":
        format_file = "clash_proxies.ini"
    else:
        format_file = "sing_outbound.ini"
    
    # Muat format outbound atau clash
    global outbound_format
    if global_format == "clash":
        outbound_format = load_clash_format(format_file)
    else:
        outbound_format = load_outbound_format(format_file)
    
    if not configs:
        print(f"Error: No valid configurations found in file '{config_file}'.")
        print("Please create a valid config.ini file with the following format:")
        print("#ID vless tls")
        print("Country_ID= ID")
        print("Protocol= vless")
        print("Security= tls")
        print("Output_Name= ID vless tls")
        print("Max_Proxies_Per_Provider= 1  # Optional: max proxies per provider for non-ID countries (default: 1)")
        print("\nAvailable country codes:")
        print("ID (Indonesia), SG (Singapore), US (United States), JP (Japan), KR (South Korea),")
        print("HK (Hong Kong), TW (Taiwan), GB (United Kingdom), DE (Germany), FR (France),")
        print("CA (Canada), AU (Australia), NL (Netherlands), RU (Russia), IN (India),")
        print("BR (Brazil), IT (Italy), ES (Spain), MX (Mexico), TR (Turkey)")
        print("\nAvailable protocols:")
        print("vless, trojan")
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
        proxies_count = process_single_config(config, global_format, format_file)
        total_proxies += proxies_count
    
    print(f"\nTotal proxies collected from all configurations: {total_proxies}")

if __name__ == "__main__":
    main()
