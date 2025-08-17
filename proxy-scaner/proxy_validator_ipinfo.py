#!/usr/bin/env python3
"""
Proxy Validator Script - Enhanced Version
Features:
- File selection menu for .txt files
- Flexible input format parsing (IP:Port, IP,Port, etc.)
- Only processes IPs with ports (skips IPs without ports)
- Validates and corrects Country/Organization data via API
- Uses 'org' field as primary, 'asname' field as backup for organization info
- Better error handling and progress tracking
"""

# ============================================================================
# KONFIGURASI SCRIPT - UBAH SESUAI KEBUTUHAN
# ============================================================================
#
# PANDUAN KONFIGURASI:
# 
# 1. UNTUK KONEKSI LAMBAT/TIDAK STABIL:
#    - BATCH_SIZE = 100-200 (lebih kecil)
#    - MAX_RETRIES = 8-10 (lebih banyak)
#    - REQUEST_DELAY = 3-5 (lebih lama)
#    - TIMEOUT_SECONDS = 90-120 (lebih lama)
#
# 2. UNTUK KONEKSI CEPAT/STABIL:
#    - BATCH_SIZE = 800-1000 (lebih besar)
#    - MAX_RETRIES = 3-4 (lebih sedikit)
#    - REQUEST_DELAY = 1-2 (lebih cepat)
#    - TIMEOUT_SECONDS = 30-60 (lebih cepat)
#
# 3. UNTUK DATASET BESAR (>10k IPs):
#    - BATCH_SIZE = 500-800 (optimal)
#    - MAX_RETRIES = 6 (standard)
#    - REQUEST_DELAY = 2 (standard)
#
# ============================================================================

# API Configuration - Multiple Tokens Support
API_TOKENS = [
    "78b59887616e57",
    "ea23036aa3f797",
    "2c18bfaab2f28c",
    "c89402dd5554ac",
    "df780be2632088",
    "878e3e53210405",
]

API_URL = "https://ipinfo.io/batch"  # IPinfo.io batch API endpoint

# Batch Processing Configuration
BATCH_SIZE = 900  # Jumlah IP per batch (max: 1000 untuk IPinfo.io)
                  # Rekomendasi: 500 (optimal untuk stabilitas dan kecepatan)
                  # Semakin besar = lebih cepat, tapi lebih berisiko timeout
                  # Semakin kecil = lebih lambat, tapi lebih stabil

# Retry Configuration
MAX_RETRIES = 6   # Jumlah percobaan maksimal per batch yang gagal
                  # Rekomendasi: 6 (balance antara persistence dan waktu)
                  # Contoh: 6 = 1 percobaan awal + 5 retry
                  # Semakin besar = lebih persistent, tapi lebih lama jika gagal

# Timing Configuration
REQUEST_DELAY = 2  # Jeda antar batch dalam detik (minimum 1 detik)
                   # Untuk menghindari rate limiting dari API
                   # IPinfo.io free plan: 50k requests/bulan

TIMEOUT_SECONDS = 60  # Timeout untuk setiap request API dalam detik
                      # Jika request lebih lama dari ini, akan dianggap gagal

# Progressive Backoff Configuration (untuk retry)
BACKOFF_BASE = 10     # Base waktu tunggu untuk retry (detik)
BACKOFF_JITTER = 5    # Random jitter maksimal (detik)
                      # Formula: (retry_attempt * BACKOFF_BASE) + random(1, BACKOFF_JITTER)
                      # Contoh retry timing:
                      # Retry 1: ~11-15 detik
                      # Retry 2: ~21-25 detik  
                      # Retry 3: ~31-35 detik

# Rate Limiting Configuration
RATE_LIMIT_MONTHLY = 500000  # Limit bulanan untuk free plan IPinfo.io
RATE_LIMIT_JITTER = 2       # Random jitter untuk delay antar batch (detik)

# Token Management Configuration
AUTO_SWITCH_TOKENS = True   # Otomatis ganti token jika limit tidak cukup
SAFETY_BUFFER = 100         # Buffer minimum requests yang disisakan per token
                           # Contoh: Jika sisa limit 150 dan butuh 200 requests,
                           # script akan switch ke token berikutnya untuk menjaga
                           # buffer 100 requests di token pertama

# Directory Configuration
TEMP_DIR = "temp_batches_ipinfo"        # Direktori untuk file batch sementara
PROGRESS_FILE = "validation_progress_ipinfo.json"  # File untuk menyimpan progress
PROXY_DATA_DIR = "proxy_data"           # Direktori untuk data proxy per negara

# ============================================================================
# JANGAN UBAH KODE DI BAWAH INI KECUALI ANDA TAHU APA YANG DILAKUKAN
# ============================================================================

import json
import time
import requests
import os
import sys
import glob
import re
from typing import List, Dict, Tuple, Optional
from datetime import datetime
import traceback
import random

class ProxyValidatorIPinfo:
    def __init__(self):
        # Load configuration from global constants
        self.API_TOKENS = API_TOKENS.copy()  # Copy to avoid modifying original
        self.current_token_index = 0
        self.current_token = self.API_TOKENS[0] if self.API_TOKENS else None
        self.API_URL = API_URL
        self.AUTO_SWITCH_TOKENS = AUTO_SWITCH_TOKENS
        self.SAFETY_BUFFER = SAFETY_BUFFER
        self.BATCH_SIZE = BATCH_SIZE
        self.RATE_LIMIT = RATE_LIMIT_MONTHLY
        self.REQUEST_DELAY = REQUEST_DELAY
        self.TIMEOUT_SECONDS = TIMEOUT_SECONDS
        self.MAX_RETRIES = MAX_RETRIES
        self.BACKOFF_BASE = BACKOFF_BASE
        self.BACKOFF_JITTER = BACKOFF_JITTER
        self.RATE_LIMIT_JITTER = RATE_LIMIT_JITTER
        
        # File and directory settings
        self.input_file = None  # Will be selected by user
        self.output_file = None  # Will be generated based on input file
        self.temp_dir = TEMP_DIR
        self.progress_file = PROGRESS_FILE
        self.proxy_data_dir = PROXY_DATA_DIR
        self.save_proxy_data = False  # Option to save proxy data by country
        
        # Token usage tracking
        self.token_usage = {}  # Track usage per token
        self.token_limits = {}  # Track remaining limits per token
        for i, token in enumerate(self.API_TOKENS):
            self.token_usage[i] = 0
            self.token_limits[i] = None  # Will be fetched from API
        
        self.stats = {
            'total_lines': 0,
            'skipped_no_port': 0,
            'processed_ips': 0,
            'enriched_country': 0,
            'enriched_org': 0,
            'corrected_country': 0,
            'corrected_org': 0,
            'invalid_ips': 0,
            'duplicates_removed': 0
        }
        
    def log(self, message: str):
        """Print timestamped log message"""
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        print(f"[{timestamp}] {message}")
    
    def display_configuration(self):
        """Display current configuration settings"""
        self.log("Current Configuration:")
        self.log("="*50)
        self.log(f"API Tokens: {len(self.API_TOKENS)} token(s) configured")
        self.log(f"Auto Token Switch: {'Enabled' if self.AUTO_SWITCH_TOKENS else 'Disabled'}")
        self.log(f"Safety Buffer: {self.SAFETY_BUFFER} requests per token")
        self.log(f"Batch Size: {self.BATCH_SIZE} IPs per batch")
        self.log(f"Max Retries: {self.MAX_RETRIES} attempts per failed batch")
        self.log(f"Request Delay: {self.REQUEST_DELAY}s between batches")
        self.log(f"Timeout: {self.TIMEOUT_SECONDS}s per API request")
        self.log(f"Backoff Base: {self.BACKOFF_BASE}s (retry timing)")
        self.log(f"Backoff Jitter: ±{self.BACKOFF_JITTER}s (random variation)")
        self.log(f"Rate Limit Jitter: ±{self.RATE_LIMIT_JITTER}s (batch delay variation)")
        self.log(f"Monthly Rate Limit: {self.RATE_LIMIT:,} requests per token")
        self.log("="*50)
    
    def check_token_limit(self, token: str) -> Optional[int]:
        """Check remaining requests for a token"""
        try:
            # Use a simple request to check limits
            response = requests.get(f"https://ipinfo.io/8.8.8.8?token={token}", timeout=10)
            
            if response.status_code == 200:
                # Check rate limit headers
                remaining = response.headers.get('X-RateLimit-Remaining')
                if remaining:
                    return int(remaining)
                else:
                    # If no header, assume we have requests available
                    return self.RATE_LIMIT
            elif response.status_code == 429:
                # Rate limited
                return 0
            else:
                self.log(f"Warning: Could not check token limit (status: {response.status_code})")
                return None
                
        except Exception as e:
            self.log(f"Warning: Error checking token limit: {e}")
            return None
    
    def get_best_token_for_requests(self, needed_requests: int) -> Optional[int]:
        """Find the best token that can handle the needed requests"""
        if not self.AUTO_SWITCH_TOKENS or len(self.API_TOKENS) == 1:
            return 0  # Use current token
        
        self.log(f"Checking token limits for {needed_requests} needed requests...")
        
        best_token_index = None
        best_remaining = -1
        
        for i, token in enumerate(self.API_TOKENS):
            # Check current limit for this token
            remaining = self.check_token_limit(token)
            
            if remaining is not None:
                self.token_limits[i] = remaining
                available_requests = remaining - self.SAFETY_BUFFER
                
                self.log(f"Token {i+1}: {remaining:,} remaining, {available_requests:,} available (after buffer)")
                
                # Check if this token can handle the needed requests
                if available_requests >= needed_requests:
                    if remaining > best_remaining:
                        best_remaining = remaining
                        best_token_index = i
                else:
                    self.log(f"Token {i+1}: Not sufficient for {needed_requests:,} requests")
            else:
                self.log(f"Token {i+1}: Could not check limit, assuming available")
                # If we can't check, assume it's available (fallback)
                if best_token_index is None:
                    best_token_index = i
        
        if best_token_index is not None:
            self.log(f"Selected Token {best_token_index+1} with {self.token_limits.get(best_token_index, 'unknown')} remaining requests")
        else:
            self.log("Warning: No token has sufficient requests available")
            best_token_index = 0  # Fallback to first token
        
        return best_token_index
    
    def switch_token(self, token_index: int):
        """Switch to a different token"""
        if 0 <= token_index < len(self.API_TOKENS):
            old_index = self.current_token_index
            self.current_token_index = token_index
            self.current_token = self.API_TOKENS[token_index]
            
            if old_index != token_index:
                self.log(f"Switched from Token {old_index+1} to Token {token_index+1}")
                self.log(f"New token: ...{self.current_token[-8:]}")  # Show last 8 chars for identification
        else:
            self.log(f"Error: Invalid token index {token_index}")
    
    def clean_org_name(self, org_name: str) -> str:
        """Clean organization name by replacing commas with periods"""
        if org_name and org_name != 'UNKNOWN':
            return org_name.replace(',', '.')
        return org_name
    
    def get_organization_info(self, api_result: Dict) -> str:
        """
        Get organization info from IPinfo.io response
        Uses org field and extracts organization name from ASN format
        """
        # IPinfo.io uses org field with format "AS12345 Organization Name"
        org = api_result.get('org', '').strip()
        if org and org != '':
            # Extract organization name from "AS12345 Organization Name" format
            if org.startswith('AS') and ' ' in org:
                # Split and take everything after the first space
                org_name = org.split(' ', 1)[1]
                return self.clean_org_name(org_name)
            else:
                # If not in ASN format, use as is
                return self.clean_org_name(org)
        
        # Fallback
        return 'Unknown Organization'
    

    def scan_txt_files(self) -> List[str]:
        """Scan current directory for .txt files"""
        txt_files = glob.glob("*.txt")
        # Filter out output files to avoid confusion
        txt_files = [f for f in txt_files if not f.startswith('proxy-validated-')]
        return sorted(txt_files)
    
    def select_file(self, txt_files: List[str]) -> str:
        """Interactive file selection with preview"""
        if not txt_files:
            return None
        
        self.log("Available .txt files for proxy validation:")
        print("\n" + "="*50)
        for i, filename in enumerate(txt_files, 1):
            # Show file size and preview
            try:
                file_size = os.path.getsize(filename)
                with open(filename, 'r', encoding='utf-8') as f:
                    first_line = f.readline().strip()
                    line_count = sum(1 for _ in f) + 1
                
                print(f"{i:2d}. {filename}")
                print(f"     Size: {file_size:,} bytes | Lines: {line_count:,}")
                print(f"     Preview: {first_line[:60]}{'...' if len(first_line) > 60 else ''}")
                print()
            except Exception as e:
                print(f"{i:2d}. {filename} (Error reading file: {e})")
        
        print("="*50)
        
        while True:
            try:
                choice = input(f"\nSelect file (1-{len(txt_files)}) or 'q' to quit: ").strip()
                
                if choice.lower() == 'q':
                    self.log("Validation cancelled by user")
                    sys.exit(0)
                
                choice_num = int(choice)
                if 1 <= choice_num <= len(txt_files):
                    selected_file = txt_files[choice_num - 1]
                    self.log(f"Selected file: {selected_file}")
                    return selected_file
                else:
                    print(f"Please enter a number between 1 and {len(txt_files)}")
                    
            except ValueError:
                print("Please enter a valid number or 'q' to quit")
            except KeyboardInterrupt:
                self.log("\nValidation cancelled by user")
                sys.exit(0)
    
    def ask_save_proxy_data_option(self):
        """Ask user if they want to save proxy data by country"""
        print("\n" + "="*60)
        print("OPSI PENYIMPANAN DATA PROXY")
        print("="*60)
        print("Apakah Anda ingin menyimpan data proxy berdasarkan negara?")
        print("Data akan disimpan dalam format JSON di direktori 'proxy_data/'")
        print("dengan file terpisah untuk setiap negara.")
        print()
        print('''[
            {
                "ip": [
                    "45.196.29.0",
                    "45.196.29.1",
                    "45.196.29.2"
                ],
                "country": "ID",
                "asn": "AS13335",
                "as_name": "Cloudflare, Inc."
            }
        ]''')
        print("="*60)
        
        while True:
            try:
                choice = input("\nSimpan data proxy berdasarkan negara? (y/n): ").strip().lower()
                
                if choice in ['y', 'yes', 'ya']:
                    self.save_proxy_data = True
                    self.log("Opsi penyimpanan data proxy berdasarkan negara: AKTIF")
                    break
                elif choice in ['n', 'no', 'tidak']:
                    self.save_proxy_data = False
                    self.log("Opsi penyimpanan data proxy berdasarkan negara: TIDAK AKTIF")
                    break
                else:
                    print("Silakan masukkan 'y' untuk ya atau 'n' untuk tidak")
                    
            except KeyboardInterrupt:
                self.log("\nValidation cancelled by user")
                sys.exit(0)

    def display_file_menu(self) -> str:
        """Display file selection menu and return selected file"""
        txt_files = self.scan_txt_files()
        
        if not txt_files:
            self.log("No .txt files found in current directory!")
            sys.exit(1)
        
        self.log("Available .txt files for proxy validation:")
        print("\n" + "="*50)
        for i, filename in enumerate(txt_files, 1):
            # Show file size and preview
            try:
                file_size = os.path.getsize(filename)
                with open(filename, 'r', encoding='utf-8') as f:
                    first_line = f.readline().strip()
                    line_count = sum(1 for _ in f) + 1
                
                print(f"{i:2d}. {filename}")
                print(f"     Size: {file_size:,} bytes | Lines: {line_count:,}")
                print(f"     Preview: {first_line[:60]}{'...' if len(first_line) > 60 else ''}")
                print()
            except Exception as e:
                print(f"{i:2d}. {filename} (Error reading file: {e})")
        
        print("="*50)
        
        while True:
            try:
                choice = input(f"\nSelect file (1-{len(txt_files)}) or 'q' to quit: ").strip()
                
                if choice.lower() == 'q':
                    self.log("Validation cancelled by user")
                    sys.exit(0)
                
                choice_num = int(choice)
                if 1 <= choice_num <= len(txt_files):
                    selected_file = txt_files[choice_num - 1]
                    self.log(f"Selected file: {selected_file}")
                    return selected_file
                else:
                    print(f"Please enter a number between 1 and {len(txt_files)}")
                    
            except ValueError:
                print("Please enter a valid number or 'q' to quit")
            except KeyboardInterrupt:
                self.log("\nValidation cancelled by user")
                sys.exit(0)
    
    def is_valid_ip(self, ip: str) -> bool:
        """Validate IP address format"""
        ip_pattern = re.compile(
            r'^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}'
            r'(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'
        )
        return bool(ip_pattern.match(ip))
    
    def is_valid_port(self, port: str) -> bool:
        """Validate port number"""
        try:
            port_num = int(port)
            return 1 <= port_num <= 65535
        except ValueError:
            return False
    
    def parse_proxy_line(self, line: str) -> Optional[Tuple[str, str, str, str]]:
        """
        Parse line and extract IP, Port, Country, Organization
        Returns None if no port is found (IP will be skipped)
        """
        line = line.strip()
        if not line or line.startswith('#'):
            return None
        
        ip_part = None
        port = None
        country = 'UNKNOWN'
        org = 'UNKNOWN'
        
        try:
            if ':' in line:
                # Format: IP:Port or IP:Port,Country,Organization
                parts = line.split(':', 1)
                ip_part = parts[0].strip()
                remaining = parts[1].strip()
                
                if ',' in remaining:
                    # IP:Port,Country,Organization
                    sub_parts = remaining.split(',')
                    port = sub_parts[0].strip()
                    country = sub_parts[1].strip() if len(sub_parts) > 1 and sub_parts[1].strip() else 'UNKNOWN'
                    org = self.clean_org_name(sub_parts[2].strip()) if len(sub_parts) > 2 and sub_parts[2].strip() else 'UNKNOWN'
                else:
                    # IP:Port
                    port = remaining
                    
            elif ',' in line:
                # Format: IP,Port,Country,Organization
                parts = line.split(',')
                if len(parts) >= 2:
                    ip_part = parts[0].strip()
                    port = parts[1].strip()
                    country = parts[2].strip() if len(parts) > 2 and parts[2].strip() else 'UNKNOWN'
                    org = self.clean_org_name(parts[3].strip()) if len(parts) > 3 and parts[3].strip() else 'UNKNOWN'
                else:
                    # Only IP, no port - skip this line
                    return None
            else:
                # Only IP, no port - skip this line
                return None
            
            # Validate IP and port
            if not ip_part or not port:
                return None
                
            if not self.is_valid_ip(ip_part):
                self.stats['invalid_ips'] += 1
                return None
                
            if not self.is_valid_port(port):
                return None
            
            return (ip_part, port, country, org)
            
        except Exception as e:
            self.log(f"Error parsing line '{line}': {e}")
            return None
        
    def load_proxies(self) -> List[Tuple[str, str, str, str]]:
        """Load and parse proxies from selected file with flexible format support"""
        proxies = []
        
        try:
            with open(self.input_file, 'r', encoding='utf-8') as f:
                for line_num, line in enumerate(f, 1):
                    self.stats['total_lines'] += 1
                    
                    if not line.strip():
                        continue
                    
                    parsed = self.parse_proxy_line(line)
                    if parsed is None:
                        self.stats['skipped_no_port'] += 1
                        continue
                    
                    ip, port, country, org = parsed
                    proxies.append((ip, port, country, org))
                    self.stats['processed_ips'] += 1
                        
        except FileNotFoundError:
            self.log(f"Error: {self.input_file} not found!")
            sys.exit(1)
        except Exception as e:
            self.log(f"Error reading {self.input_file}: {e}")
            sys.exit(1)
        
        # Display parsing statistics
        self.log(f"File parsing completed:")
        self.log(f"  - Total lines read: {self.stats['total_lines']:,}")
        self.log(f"  - IPs skipped (no port): {self.stats['skipped_no_port']:,}")
        self.log(f"  - Invalid IPs: {self.stats['invalid_ips']:,}")
        self.log(f"  - IPs to process: {self.stats['processed_ips']:,}")
        
        if self.stats['processed_ips'] == 0:
            self.log("No valid IPs with ports found! Please check your input file format.")
            sys.exit(1)
            
        return proxies
    
    def remove_duplicates(self, proxies: List[Tuple[str, str, str, str]]) -> List[Tuple[str, str, str, str]]:
        """Remove duplicate proxies based on IP:Port combination before API validation"""
        self.log("Removing duplicate proxies before validation...")
        
        original_count = len(proxies)
        seen_proxies = set()
        unique_proxies = []
        
        for proxy in proxies:
            ip, port, country, org = proxy
            proxy_key = (ip, port)
            
            if proxy_key not in seen_proxies:
                seen_proxies.add(proxy_key)
                unique_proxies.append(proxy)
            else:
                self.stats['duplicates_removed'] += 1
        
        removed_count = original_count - len(unique_proxies)
        self.log(f"Removed {removed_count:,} duplicate proxies")
        self.log(f"Unique proxies to validate: {len(unique_proxies):,}")
        
        return unique_proxies
    
    def create_batch_files(self, proxies: List[Tuple[str, str, str, str]]) -> int:
        """Split proxies into smaller JSON batch files for IPinfo.io"""
        if not os.path.exists(self.temp_dir):
            os.makedirs(self.temp_dir)
            
        batch_count = 0
        for i in range(0, len(proxies), self.BATCH_SIZE):
            batch = proxies[i:i + self.BATCH_SIZE]
            
            # Create IP list for IPinfo.io batch API
            ip_list = []
            metadata = []
            
            for proxy in batch:
                ip, port, old_country, old_org = proxy
                ip_list.append(ip)
                metadata.append({
                    "original_port": port,
                    "original_country": old_country,
                    "original_org": old_org
                })
            
            # Save IP list for API request
            batch_file = f"{self.temp_dir}/batch_{batch_count:03d}.json"
            with open(batch_file, 'w', encoding='utf-8') as f:
                json.dump(ip_list, f, indent=2)
                
            # Store metadata separately
            meta_file = f"{self.temp_dir}/meta_{batch_count:03d}.json"
            with open(meta_file, 'w', encoding='utf-8') as f:
                json.dump(metadata, f, indent=2)
                
            batch_count += 1
            
        self.log(f"Created {batch_count} batch files ({self.BATCH_SIZE} IPs each) in {self.temp_dir}/")
        return batch_count
    
    def load_progress(self) -> Dict:
        """Load validation progress"""
        if os.path.exists(self.progress_file):
            try:
                with open(self.progress_file, 'r') as f:
                    return json.load(f)
            except:
                pass
        return {"completed_batches": [], "failed_batches": []}
    
    def save_progress(self, progress: Dict):
        """Save validation progress"""
        with open(self.progress_file, 'w') as f:
            json.dump(progress, f, indent=2)
    
    def validate_batch(self, batch_num: int) -> List[Dict]:
        """Validate single batch using IPinfo.io API"""
        batch_file = f"{self.temp_dir}/batch_{batch_num:03d}.json"
        meta_file = f"{self.temp_dir}/meta_{batch_num:03d}.json"
        
        try:
            # Load batch IP list
            with open(batch_file, 'r') as f:
                ip_list = json.load(f)
                
            # Load metadata
            with open(meta_file, 'r') as f:
                metadata = json.load(f)
            
            # Make API request to IPinfo.io
            headers = {
                'Content-Type': 'application/json',
                'User-Agent': 'ProxyValidator-IPinfo/1.0',
                'Authorization': f'Bearer {self.current_token}'
            }
            
            # IPinfo.io batch API expects array of IPs
            response = requests.post(
                self.API_URL,
                json=ip_list,
                headers=headers,
                timeout=self.TIMEOUT_SECONDS
            )
            
            if response.status_code == 200:
                api_results = response.json()
                self.log(f"Batch {batch_num + 1}: Successfully processed {len(api_results)} IPs")
                
                # Track token usage
                unique_ips_in_batch = len(set(ip_list))
                self.token_usage[self.current_token_index] += unique_ips_in_batch
                
                # Update remaining limit if available in headers
                remaining = response.headers.get('X-RateLimit-Remaining')
                if remaining:
                    self.token_limits[self.current_token_index] = int(remaining)
                

                
                # Combine API results with original data
                validated_proxies = []
                
                # Process ALL input IPs (including duplicates) and match with API results
                for i, ip in enumerate(ip_list):
                    if i < len(metadata):
                        original = metadata[i]
                        
                        # Check if this IP has API data
                        if ip in api_results:
                            result = api_results[ip]
                            
                            # Check if API returned valid data
                            if isinstance(result, dict) and 'country' in result:
                                org_info = self.get_organization_info(result)
                                
                                proxy_data = {
                                    'ip': ip,
                                    'port': original['original_port'],
                                    'country_code': result.get('country', 'UNKNOWN'),  # IPinfo.io uses 'country' for country code
                                    'org': org_info,
                                    'original_country': original['original_country'],
                                    'original_org': original['original_org']
                                }
                                
                                # Add simplified API data for proxy data saving
                                if self.save_proxy_data:
                                    # Extract ASN and AS name from org field
                                    org_field = result.get('org', '')
                                    asn = 'Unknown ASN'
                                    as_name = 'Unknown AS Name'
                                    
                                    if org_field.startswith('AS') and ' ' in org_field:
                                        parts = org_field.split(' ', 1)
                                        asn = parts[0]  # e.g., "AS63949"
                                        as_name = parts[1]  # e.g., "Akamai Connected Cloud"
                                    
                                    proxy_data['api_data'] = {
                                        'ip': ip,
                                        'country': result.get('country', 'UNKNOWN'),
                                        'asn': asn,
                                        'as_name': as_name
                                    }
                                
                                validated_proxies.append(proxy_data)
                            else:
                                # Keep original data if validation failed
                                self.log(f"Warning: No valid data for IP {ip}")
                                proxy_data = {
                                    'ip': ip,
                                    'port': original['original_port'],
                                    'country_code': original['original_country'],
                                    'org': self.clean_org_name(original['original_org']),
                                    'original_country': original['original_country'],
                                    'original_org': original['original_org']
                                }
                                
                                # Add minimal API data for failed validations
                                if self.save_proxy_data:
                                    proxy_data['api_data'] = {
                                        'ip': ip,
                                        'country': original['original_country'],
                                        'asn': 'Unknown ASN',
                                        'as_name': original['original_org']
                                    }
                                
                                validated_proxies.append(proxy_data)
                        else:
                            # IP not returned by API - use original data
                            proxy_data = {
                                'ip': ip,
                                'port': original['original_port'],
                                'country_code': original['original_country'],
                                'org': self.clean_org_name(original['original_org']),
                                'original_country': original['original_country'],
                                'original_org': original['original_org']
                            }
                            
                            # Add minimal API data for missing IPs
                            if self.save_proxy_data:
                                proxy_data['api_data'] = {
                                    'ip': ip,
                                    'country': original['original_country'],
                                    'asn': 'Unknown ASN',
                                    'as_name': original['original_org']
                                }
                            
                            validated_proxies.append(proxy_data)

                
                return validated_proxies
                
            elif response.status_code == 429:
                self.log(f"Rate limit exceeded for Token {self.current_token_index + 1}")
                
                # Try to switch to another token if available
                if len(self.API_TOKENS) > 1 and self.AUTO_SWITCH_TOKENS:
                    # Mark current token as exhausted
                    self.token_limits[self.current_token_index] = 0
                    
                    # Find next available token
                    for i in range(len(self.API_TOKENS)):
                        if i != self.current_token_index:
                            remaining = self.check_token_limit(self.API_TOKENS[i])
                            if remaining and remaining > self.SAFETY_BUFFER:
                                self.log(f"Switching to Token {i + 1} (has {remaining:,} requests remaining)")
                                self.switch_token(i)
                                return None  # Signal to retry with new token
                    
                    self.log("No other tokens available with sufficient limits")
                
                self.log(f"Waiting 90s for rate limit reset...")
                time.sleep(90)
                return None  # Signal to retry
            else:
                self.log(f"API Error {response.status_code}: {response.text}")
                return []
                
        except requests.exceptions.ConnectionError as e:
            self.log(f"Connection error for batch {batch_num}: {e}")
            return None  # Signal to retry
        except requests.exceptions.Timeout as e:
            self.log(f"Timeout error for batch {batch_num}: {e}")
            return None  # Signal to retry
        except Exception as e:
            self.log(f"Unexpected error validating batch {batch_num}: {e}")
            return []
    
    def validate_all_batches(self, total_batches: int) -> List[Dict]:
        """Validate all batches with improved retry logic"""
        progress = self.load_progress()
        all_validated = []
        
        for batch_num in range(total_batches):
            # Skip if already completed
            if batch_num in progress["completed_batches"]:
                self.log(f"Skipping batch {batch_num + 1}/{total_batches} (already completed)")
                # Load existing results
                result_file = f"{self.temp_dir}/result_{batch_num:03d}.json"
                if os.path.exists(result_file):
                    with open(result_file, 'r') as f:
                        batch_results = json.load(f)
                        all_validated.extend(batch_results)
                continue
            
            self.log(f"Processing batch {batch_num + 1}/{total_batches} ({((batch_num + 1) / total_batches * 100):.1f}%)")
            
            # Validate batch with retry logic
            for retry in range(self.MAX_RETRIES):
                batch_results = self.validate_batch(batch_num)
                
                if batch_results is not None:  # Success or empty result
                    # Save batch results
                    result_file = f"{self.temp_dir}/result_{batch_num:03d}.json"
                    with open(result_file, 'w') as f:
                        json.dump(batch_results, f, indent=2)
                    
                    all_validated.extend(batch_results)
                    progress["completed_batches"].append(batch_num)
                    
                    # Remove from failed list if it was there
                    if batch_num in progress["failed_batches"]:
                        progress["failed_batches"].remove(batch_num)
                    
                    self.save_progress(progress)
                    break
                    
                elif retry < self.MAX_RETRIES - 1:
                    wait_time = (retry + 1) * self.BACKOFF_BASE + random.randint(1, self.BACKOFF_JITTER)  # Progressive backoff
                    self.log(f"Retrying batch {batch_num + 1} in {wait_time}s (attempt {retry + 2}/{self.MAX_RETRIES})")
                    time.sleep(wait_time)
                else:
                    self.log(f"Failed to process batch {batch_num + 1} after {self.MAX_RETRIES} attempts")
                    progress["failed_batches"].append(batch_num)
                    self.save_progress(progress)
            
            # Rate limiting delay with jitter
            if batch_num < total_batches - 1:
                delay = self.REQUEST_DELAY + random.uniform(0, self.RATE_LIMIT_JITTER)  # Add jitter
                self.log(f"Waiting {delay:.1f}s (rate limit + jitter)...")
                time.sleep(delay)
        
        if progress["failed_batches"]:
            self.log(f"Warning: {len(progress['failed_batches'])} batches failed: {progress['failed_batches']}")
        
        return all_validated
    
    def save_proxy_data_by_country(self, validated_proxies: List[Dict]):
        """Save proxy data by country in JSON format, grouped by identical metadata (ASN, AS Name, ISP, org, etc)."""
        if not self.save_proxy_data:
            return

        self.log("Menyimpan data proxy berdasarkan negara (grouped)...")

        # Create proxy_data directory if it doesn't exist
        if not os.path.exists(self.proxy_data_dir):
            os.makedirs(self.proxy_data_dir)
            self.log(f"Direktori {self.proxy_data_dir}/ dibuat")

        # Group proxies by country, then by (asn, as_name, isp, org, etc)
        country_data = {}
        for proxy in validated_proxies:
            if 'api_data' in proxy:
                api = proxy['api_data']
                country_code = proxy['country_code']
                asn = api.get('asn', 'Unknown ASN')
                as_name = api.get('as_name', 'Unknown AS Name')
                isp = api.get('isp', 'Unknown ISP')
                org = api.get('org', 'Unknown Org')
                # Key: (asn, as_name, isp, org)
                group_key = (asn, as_name, isp, org)
                if country_code not in country_data:
                    country_data[country_code] = {}
                if group_key not in country_data[country_code]:
                    country_data[country_code][group_key] = []
                # Simpan IP (atau list IP) ke grup
                ip = api.get('ip')
                if ip:
                    country_data[country_code][group_key].append(ip)

        saved_countries = 0
        total_proxies_saved = 0

        for country_code, group_dict in country_data.items():
            if country_code == 'UNKNOWN':
                filename = f"{self.proxy_data_dir}/UNKNOWN.json"
            else:
                filename = f"{self.proxy_data_dir}/{country_code}.json"

            # Build grouped data list
            grouped_list = []
            for (asn, as_name, isp, org), ip_list in group_dict.items():
                grouped_list.append({
                    "ip": ip_list,
                    "country": country_code,
                    "asn": asn,
                    "as_name": as_name,
                    "isp": isp,
                    "org": org
                })
                total_proxies_saved += len(ip_list)

            try:
                with open(filename, 'w', encoding='utf-8') as f:
                    json.dump(grouped_list, f, indent=2, ensure_ascii=False)
                saved_countries += 1
                self.log(f"  - {country_code}: {len(grouped_list)} grup, {sum(len(g['ip']) for g in grouped_list)} IP disimpan ke {filename}")
            except Exception as e:
                self.log(f"Error menyimpan data untuk negara {country_code}: {e}")

        self.log(f"Data proxy berhasil disimpan:")
        self.log(f"  - {saved_countries} file negara")
        self.log(f"  - {total_proxies_saved} IP ditambahkan (grouped)")
        self.log(f"  - Lokasi: {self.proxy_data_dir}/")
    
    def save_results(self, validated_proxies: List[Dict]):
        """Sort by country code, then ISP, and save to output file with detailed tracking"""
        self.log("Analyzing and sorting results...")
        
        # Track data changes and enrichments
        for proxy in validated_proxies:
            original_country = proxy.get('original_country', 'UNKNOWN')
            original_org = proxy.get('original_org', 'UNKNOWN')
            new_country = proxy['country_code']
            new_org = proxy['org']
            
            # Track country changes/enrichments
            if original_country == 'UNKNOWN' and new_country != 'UNKNOWN':
                self.stats['enriched_country'] += 1
            elif original_country != 'UNKNOWN' and original_country != new_country:
                self.stats['corrected_country'] += 1
            
            # Track Organization changes/enrichments
            if original_org == 'UNKNOWN' and new_org != 'Unknown Organization':
                self.stats['enriched_org'] += 1
            elif original_org != 'UNKNOWN' and original_org != new_org:
                self.stats['corrected_org'] += 1
        
        # Sort by country code (primary) and Organization (secondary)
        validated_proxies.sort(key=lambda x: (x['country_code'].upper(), x['org'].upper()))
        
        # Save to output file
        with open(self.output_file, 'w', encoding='utf-8') as f:
            for proxy in validated_proxies:
                line = f"{proxy['ip']},{proxy['port']},{proxy['country_code']},{proxy['org']}\n"
                f.write(line)
        
        self.log(f"Saved {len(validated_proxies)} validated proxies to {self.output_file}")
    
    def print_summary(self, validated_proxies: List[Dict]):
        """Print validation summary with statistics"""
        self.log("")
        self.log("="*60)
        self.log("VALIDATION SUMMARY")
        self.log("="*60)
        self.log(f"Input file: {os.path.basename(self.input_file)}")
        self.log(f"Output file: {os.path.basename(self.output_file)}")
        self.log(f"Total lines processed: {self.stats['total_lines']:,}")
        self.log(f"IPs skipped (no port): {self.stats['skipped_no_port']:,}")
        self.log(f"Invalid IPs: {self.stats['invalid_ips']:,}")
        self.log(f"Duplicates removed: {self.stats['duplicates_removed']:,}")
        self.log(f"Successfully validated (unique): {len(validated_proxies):,}")
        
        # Count countries
        country_stats = {}
        for proxy in validated_proxies:
            country = proxy.get('country_code', 'UNKNOWN')
            country_stats[country] = country_stats.get(country, 0) + 1
        
        self.log("")
        self.log("DATA CHANGES:")
        self.log(f"  - Country data enriched: {self.stats['enriched_country']:,}")
        self.log(f"  - Country data corrected: {self.stats['corrected_country']:,}")
        self.log(f"  - Organization data enriched: {self.stats['enriched_org']:,}")
        self.log(f"  - Organization data corrected: {self.stats['corrected_org']:,}")
        self.log("")
        self.log("COUNTRIES DISTRIBUTION:")
        for country, count in sorted(country_stats.items()):
            percentage = (count / len(validated_proxies)) * 100
            self.log(f"  - {country}: {count:,} ({percentage:.1f}%)")
        
        # Token usage summary
        if len(self.API_TOKENS) > 1:
            self.log("")
            self.log("TOKEN USAGE SUMMARY:")
            total_used = 0
            for i, token in enumerate(self.API_TOKENS):
                used = self.token_usage.get(i, 0)
                remaining = self.token_limits.get(i, 'Unknown')
                total_used += used
                
                if used > 0:
                    self.log(f"  - Token {i+1} (...{token[-8:]}): {used:,} requests used, {remaining} remaining")
                else:
                    self.log(f"  - Token {i+1} (...{token[-8:]}): Not used")
            
            self.log(f"  - Total API requests made: {total_used:,}")
        else:
            used = self.token_usage.get(0, 0)
            remaining = self.token_limits.get(0, 'Unknown')
            self.log("")
            self.log("TOKEN USAGE:")
            self.log(f"  - API requests made: {used:,}")
            self.log(f"  - Remaining requests: {remaining}")
        
        self.log("="*60)
    
    def cleanup_temp_files(self):
        """Remove temporary batch files"""
        if os.path.exists(self.temp_dir):
            import shutil
            shutil.rmtree(self.temp_dir)
            self.log(f"Cleaned up temporary files in {self.temp_dir}/")
        
        if os.path.exists(self.progress_file):
            os.remove(self.progress_file)
            self.log("Cleaned up progress file")
    
    def run(self):
        """Main execution flow otomatis untuk workflow GitHub Actions"""
        try:
            import shutil
            import time
            start_time = time.time()
            self.log("=== Proxy Validator IPinfo (Non-Interaktif, Mode Otomatis) ===")
            # Cek file input
            if not os.path.exists("rawProxyList.txt"):
                self.log(f"Error: rawProxyList.txt tidak ditemukan!")
                self.log("Pastikan rawProxyList.txt tersedia di direktori kerja.")
                return

            # Backup file sebelum update
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            backup_file = f"rawProxyList_backup_{timestamp}.txt"
            shutil.copy2("rawProxyList.txt", backup_file)
            self.log(f"✅ Backup dibuat: {backup_file}")

            # Set input/output file
            self.input_file = "rawProxyList.txt"
            self.output_file = "rawProxyList.txt"
            self.save_proxy_data = True

            # Load proxies
            proxies = self.load_proxies()
            if not proxies:
                self.log("No valid proxies found!")
                return

            proxies = self.remove_duplicates(proxies)
            total_batches = self.create_batch_files(proxies)
            validated_proxies = self.validate_all_batches(total_batches)

            # Simpan data per negara
            self.save_proxy_data_by_country(validated_proxies)

            # Simpan hasil ke output file (rawProxyList.txt)
            with open(self.output_file, 'w', encoding='utf-8') as f:
                for proxy in validated_proxies:
                    ip = proxy.get('query', '')
                    port = proxy.get('port', '')
                    country = proxy.get('country', '')
                    org = proxy.get('org', '')
                    f.write(f"{ip}:{port},{country},{org}\n")
            self.log(f"✅ rawProxyList.txt diupdate dengan {len(validated_proxies)} proxy tervalidasi")

            # Statistik negara
            country_stats = {}
            for proxy in validated_proxies:
                code = proxy.get('countryCode', 'XX')
                country_stats[code] = country_stats.get(code, 0) + 1
            self.log(f"🌍 Distribusi negara:")
            for country, count in sorted(country_stats.items()):
                self.log(f"  - {country}: {count}")

            self.cleanup_temp_files()
            total_time = (time.time() - start_time) / 60
            self.log(f"\nValidation completed successfully in {total_time:.1f} minutes!")
            self.log(f"Results saved to: {self.output_file}")

        except KeyboardInterrupt:
            self.log("Dibatalkan oleh user.")
        except Exception as e:
            self.log(f"Terjadi error fatal: {e}")
            traceback.print_exc()
            sys.exit(1)

if __name__ == "__main__":
    validator = ProxyValidatorIPinfo()
    validator.run()