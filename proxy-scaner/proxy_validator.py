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

import json
import time
import requests
import os
import sys
import re
from typing import List, Dict, Tuple, Optional
from datetime import datetime
import random

class ProxyValidatorEnhanced:
    def __init__(self):
        self.API_URL = "http://ip-api.com/batch"
        self.BATCH_SIZE = 90  # Optimized balance between speed and stability
        self.RATE_LIMIT = 15  # requests per minute
        self.REQUEST_DELAY = 60 / self.RATE_LIMIT + 1  # ~5 seconds with buffer
        self.input_file = "rawProxyList.txt"  # Fixed input file
        self.backup_file = None  # Will be generated for backup
        self.update_input_file = True  # Update rawProxyList.txt with validated data
        self.temp_dir = "temp_batches"
        self.progress_file = "validation_progress.json"
        self.proxy_data_dir = "proxy_data"  # Directory for country-based proxy data
        self.save_proxy_data = True  # Always save proxy data by country
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
    
    def clean_org_name(self, org_name: str) -> str:
        """Clean organization name by replacing commas with periods"""
        if org_name and org_name != 'UNKNOWN':
            return org_name.replace(',', '.')
        return org_name
    
    def get_organization_info(self, api_result: Dict) -> str:
        """
        Get organization info with priority: org -> asname -> Unknown Organization
        """
        # First priority: org field
        org = api_result.get('org', '').strip()
        if org and org != '':
            return self.clean_org_name(org)
        
        # Second priority: asname field (direct ASName without AS number)
        asname = api_result.get('asname', '').strip()
        if asname and asname != '':
            return self.clean_org_name(asname)
        
        # Fallback
        return 'Unknown Organization'
    
    def check_input_file(self):
        """Check if rawProxyList.txt exists"""
        if not os.path.exists(self.input_file):
            self.log(f"Error: {self.input_file} not found!")
            self.log("Please ensure rawProxyList.txt exists in the current directory.")
            sys.exit(1)
        
        # Show file info
        try:
            file_size = os.path.getsize(self.input_file)
            with open(self.input_file, 'r', encoding='utf-8') as f:
                first_line = f.readline().strip()
                line_count = sum(1 for _ in f) + 1
            
            self.log(f"Input file: {self.input_file}")
            self.log(f"File size: {file_size:,} bytes | Lines: {line_count:,}")
            self.log(f"Preview: {first_line[:60]}{'...' if len(first_line) > 60 else ''}")
        except Exception as e:
            self.log(f"Error reading input file: {e}")
            sys.exit(1)
    
    def create_backup(self):
        """Create backup of rawProxyList.txt before updating"""
        try:
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            self.backup_file = f"rawProxyList_backup_{timestamp}.txt"
            
            # Copy original file to backup
            import shutil
            shutil.copy2(self.input_file, self.backup_file)
            
            self.log(f"✅ Backup created: {self.backup_file}")
            return True
            
        except Exception as e:
            self.log(f"❌ Error creating backup: {e}")
            return False
    
    def update_raw_proxy_list(self, validated_proxies: List[Dict]):
        """Update rawProxyList.txt with validated data"""
        try:
            self.log("🔄 Updating rawProxyList.txt with validated data...")
            
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
            
            # Sort proxies by country code for consistency
            validated_proxies.sort(key=lambda x: (x['country_code'], x['ip']))
            
            # Write updated data to rawProxyList.txt
            with open(self.input_file, 'w', encoding='utf-8') as f:
                for proxy in validated_proxies:
                    f.write(f"{proxy['ip']},{proxy['port']},{proxy['country_code']},{proxy['org']}\n")
            
            self.log(f"✅ rawProxyList.txt updated with {len(validated_proxies)} validated proxies")
            
            # Show file statistics
            file_size = os.path.getsize(self.input_file)
            self.log(f"📊 Updated file size: {file_size:,} bytes")
            
            # Show country distribution
            country_stats = {}
            for proxy in validated_proxies:
                country = proxy['country_code']
                country_stats[country] = country_stats.get(country, 0) + 1
            
            self.log(f"🌍 Countries distribution:")
            for country, count in sorted(country_stats.items()):
                percentage = (count / len(validated_proxies)) * 100
                self.log(f"   - {country}: {count:,} ({percentage:.1f}%)")
            
            return True
            
        except Exception as e:
            self.log(f"❌ Error updating rawProxyList.txt: {e}")
            
            # Try to restore from backup if update failed
            if self.backup_file and os.path.exists(self.backup_file):
                try:
                    import shutil
                    shutil.copy2(self.backup_file, self.input_file)
                    self.log(f"🔄 Restored from backup: {self.backup_file}")
                except Exception as restore_error:
                    self.log(f"❌ Failed to restore from backup: {restore_error}")
            
            return False
    



    
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
        """Split proxies into smaller JSON batch files"""
        if not os.path.exists(self.temp_dir):
            os.makedirs(self.temp_dir)
            
        batch_count = 0
        for i in range(0, len(proxies), self.BATCH_SIZE):
            batch = proxies[i:i + self.BATCH_SIZE]
            batch_ips = []
            
            for proxy in batch:
                ip, port, old_country, old_org = proxy
                batch_ips.append({
                    "query": ip,
                    "fields": "status,country,countryCode,isp,org,as,asname,query",
                    "original_port": port,
                    "original_country": old_country,
                    "original_org": old_org
                })
            
            batch_file = f"{self.temp_dir}/batch_{batch_count:03d}.json"
            with open(batch_file, 'w', encoding='utf-8') as f:
                api_queries = []
                for item in batch_ips:
                    api_queries.append({
                        "query": item["query"],
                        "fields": "status,country,countryCode,isp,org,as,asname,query"
                    })
                json.dump(api_queries, f, indent=2)
                
            # Store metadata separately
            meta_file = f"{self.temp_dir}/meta_{batch_count:03d}.json"
            with open(meta_file, 'w', encoding='utf-8') as f:
                json.dump(batch_ips, f, indent=2)
                
            batch_count += 1
            
        self.log(f"Created {batch_count} batch files (80 IPs each) in {self.temp_dir}/")
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
        """Validate single batch with better error handling"""
        batch_file = f"{self.temp_dir}/batch_{batch_num:03d}.json"
        meta_file = f"{self.temp_dir}/meta_{batch_num:03d}.json"
        
        try:
            # Load batch queries
            with open(batch_file, 'r') as f:
                queries = json.load(f)
                
            # Load metadata
            with open(meta_file, 'r') as f:
                metadata = json.load(f)
            
            # Make API request with better settings
            headers = {
                'Content-Type': 'application/json',
                'User-Agent': 'ProxyValidator/2.0',
                'Connection': 'close'  # Force close connection
            }
            
            session = requests.Session()
            session.headers.update(headers)
            
            response = session.post(
                self.API_URL, 
                json=queries,
                timeout=60,  # Increased timeout
                stream=False
            )
            
            session.close()  # Explicitly close session
            
            if response.status_code == 200:
                api_results = response.json()
                
                # Check rate limit headers
                remaining = response.headers.get('X-Rl', '15')
                ttl = response.headers.get('X-Ttl', '60')
                self.log(f"Batch {batch_num + 1}: Rate limit {remaining} remaining, {ttl}s until reset")
                
                # Combine API results with original data
                validated_proxies = []
                for i, result in enumerate(api_results):
                    if i < len(metadata):
                        original = metadata[i]
                        
                        if result.get('status') == 'success':
                            proxy_data = {
                                'ip': result['query'],
                                'port': original['original_port'],
                                'country_code': result.get('countryCode', 'UNKNOWN'),
                                'org': self.get_organization_info(result),
                                'original_country': original['original_country'],
                                'original_org': original['original_org']
                            }
                            
                            # Add full API data for proxy data saving
                            if self.save_proxy_data:
                                proxy_data['api_data'] = {
                                    'query': result['query'],
                                    'country': result.get('country', 'Unknown'),
                                    'countryCode': result.get('countryCode', 'UNKNOWN'),
                                    'isp': result.get('isp', 'Unknown ISP'),
                                    'org': result.get('org', 'Unknown Organization'),
                                    'as': result.get('as', 'Unknown AS'),
                                    'asname': result.get('asname', 'Unknown ASName')
                                }
                            
                            validated_proxies.append(proxy_data)
                        else:
                            # Keep original data if validation failed
                            self.log(f"Warning: Validation failed for IP {original['query']}: {result.get('message', 'Unknown error')}")
                            proxy_data = {
                                'ip': original['query'],
                                'port': original['original_port'],
                                'country_code': original['original_country'],
                                'org': self.clean_org_name(original['original_org']),
                                'original_country': original['original_country'],
                                'original_org': original['original_org']
                            }
                            
                            # Add minimal API data for failed validations
                            if self.save_proxy_data:
                                proxy_data['api_data'] = {
                                    'query': original['query'],
                                    'country': 'Unknown',
                                    'countryCode': original['original_country'],
                                    'isp': 'Unknown ISP',
                                    'org': original['original_org'],
                                    'as': 'Unknown AS',
                                    'asname': 'Unknown ASName'
                                }
                            
                            validated_proxies.append(proxy_data)
                
                return validated_proxies
                
            elif response.status_code == 429:
                self.log(f"Rate limit exceeded. Waiting 90s...")
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
            max_retries = 6  # Increased retries
            for retry in range(max_retries):
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
                    
                elif retry < max_retries - 1:
                    wait_time = (retry + 1) * 10 + random.randint(1, 5)  # Progressive backoff
                    self.log(f"Retrying batch {batch_num + 1} in {wait_time}s (attempt {retry + 2}/{max_retries})")
                    time.sleep(wait_time)
                else:
                    self.log(f"Failed to process batch {batch_num + 1} after {max_retries} attempts")
                    progress["failed_batches"].append(batch_num)
                    self.save_progress(progress)
            
            # Rate limiting delay with jitter
            if batch_num < total_batches - 1:
                delay = self.REQUEST_DELAY + random.uniform(0, 2)  # Add jitter
                self.log(f"Waiting {delay:.1f}s (rate limit + jitter)...")
                time.sleep(delay)
        
        if progress["failed_batches"]:
            self.log(f"Warning: {len(progress['failed_batches'])} batches failed: {progress['failed_batches']}")
        
        return all_validated
    
    def save_proxy_data_by_country(self, validated_proxies: List[Dict]):
        """Save proxy data by country in JSON format"""
        if not self.save_proxy_data:
            return
            
        self.log("Menyimpan data proxy berdasarkan negara...")
        
        # Create proxy_data directory if it doesn't exist
        if not os.path.exists(self.proxy_data_dir):
            os.makedirs(self.proxy_data_dir)
            self.log(f"Direktori {self.proxy_data_dir}/ dibuat")
        
        # Group proxies by country
        country_data = {}
        for proxy in validated_proxies:
            if 'api_data' in proxy:
                country_code = proxy['country_code']
                if country_code not in country_data:
                    country_data[country_code] = []
                
                # Add the API data to country group
                country_data[country_code].append(proxy['api_data'])
        
        # Save each country's data to separate JSON files
        saved_countries = 0
        total_proxies_saved = 0
        
        for country_code, proxies_data in country_data.items():
            if country_code == 'UNKNOWN':
                filename = f"{self.proxy_data_dir}/UNKNOWN.json"
            else:
                filename = f"{self.proxy_data_dir}/{country_code}.json"
            
            try:
                # Load existing data if file exists
                existing_data = []
                if os.path.exists(filename):
                    try:
                        with open(filename, 'r', encoding='utf-8') as f:
                            existing_data = json.load(f)
                    except:
                        existing_data = []
                
                # Merge new data with existing data (avoid duplicates by IP)
                existing_ips = {item.get('query') for item in existing_data if isinstance(item, dict)}
                new_data = []
                current_batch_ips = set()
                
                for proxy_data in proxies_data:
                    ip = proxy_data.get('query')
                    # Skip if IP already exists in file or already processed in current batch
                    if ip not in existing_ips and ip not in current_batch_ips:
                        new_data.append(proxy_data)
                        current_batch_ips.add(ip)
                
                # Combine and save
                combined_data = existing_data + new_data
                
                with open(filename, 'w', encoding='utf-8') as f:
                    json.dump(combined_data, f, indent=2, ensure_ascii=False)
                
                saved_countries += 1
                total_proxies_saved += len(new_data)
                
                if new_data:
                    self.log(f"  - {country_code}: {len(new_data)} proxy baru disimpan ke {filename}")
                else:
                    self.log(f"  - {country_code}: Tidak ada data baru (semua sudah ada)")
                    
            except Exception as e:
                self.log(f"Error menyimpan data untuk negara {country_code}: {e}")
        
        self.log(f"Data proxy berhasil disimpan:")
        self.log(f"  - {saved_countries} file negara")
        self.log(f"  - {total_proxies_saved} proxy baru ditambahkan")
        self.log(f"  - Lokasi: {self.proxy_data_dir}/")
    
    def sort_and_save_results(self, validated_proxies: List[Dict]):
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
        
        # Generate detailed summary
        country_stats = {}
        for proxy in validated_proxies:
            country = proxy['country_code']
            country_stats[country] = country_stats.get(country, 0) + 1
        
        # Display comprehensive statistics
        self.log("\n" + "="*60)
        self.log("VALIDATION SUMMARY")
        self.log("="*60)
        self.log(f"Input file: {self.input_file}")
        self.log(f"Output file: {self.output_file}")
        self.log(f"Total lines processed: {self.stats['total_lines']:,}")
        self.log(f"IPs skipped (no port): {self.stats['skipped_no_port']:,}")
        self.log(f"Invalid IPs: {self.stats['invalid_ips']:,}")
        self.log(f"Duplicates removed: {self.stats['duplicates_removed']:,}")
        self.log(f"Successfully validated (unique): {len(validated_proxies):,}")
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
        """Main execution flow for automated proxy validation with rawProxyList.txt update"""
        try:
            start_time = time.time()
            
            self.log("Starting AUTOMATED proxy validation process...")
            self.log("Features: Update rawProxyList.txt with validated data, save country data")
            
            # Step 0: Check input file
            self.check_input_file()
            
            # Step 0.5: Create backup of original file
            if not self.create_backup():
                self.log("❌ Failed to create backup, aborting...")
                sys.exit(1)
            
            self.log(f"Proxy data by country will be saved to: {self.proxy_data_dir}/")
            
            # Step 1: Load and parse proxies
            proxies = self.load_proxies()
            
            # Step 2: Remove duplicates before validation
            proxies = self.remove_duplicates(proxies)
            
            # Step 3: Create batch files
            total_batches = self.create_batch_files(proxies)
            
            # Step 4: Validate all batches
            self.log(f"Starting validation of {total_batches} batches...")
            estimated_time = (total_batches * self.REQUEST_DELAY) / 60
            self.log(f"Estimated completion time: {estimated_time:.1f} minutes")
            
            validated_proxies = self.validate_all_batches(total_batches)
            
            # Step 5: Save proxy data by country
            self.save_proxy_data_by_country(validated_proxies)
            
            # Step 6: Update rawProxyList.txt with validated data
            if not self.update_raw_proxy_list(validated_proxies):
                self.log("❌ Failed to update rawProxyList.txt")
                sys.exit(1)
            
            # Step 7: Cleanup
            self.cleanup_temp_files()
            
            # Final summary
            total_time = (time.time() - start_time) / 60
            self.log(f"\n✅ Validation completed successfully in {total_time:.1f} minutes!")
            self.log(f"📝 rawProxyList.txt updated with validated data")
            self.log(f"💾 Backup saved as: {self.backup_file}")
            self.log(f"🌍 Country data saved to: {self.proxy_data_dir}/")
            
            # Show final statistics
            self.log(f"\n📊 Final Statistics:")
            self.log(f"   Total lines processed: {self.stats['total_lines']}")
            self.log(f"   Valid proxies saved: {self.stats['processed_ips']}")
            self.log(f"   Duplicates removed: {self.stats['duplicates_removed']}")
            self.log(f"   Invalid IPs skipped: {self.stats['invalid_ips']}")
            self.log(f"   Country data enriched: {self.stats['enriched_country']}")
            self.log(f"   Organization data enriched: {self.stats['enriched_org']}")
            
        except KeyboardInterrupt:
            self.log("\nProcess interrupted by user. Progress saved - you can resume later.")
            sys.exit(1)
        except Exception as e:
            self.log(f"Unexpected error: {e}")
            import traceback
            traceback.print_exc()
            sys.exit(1)

if __name__ == "__main__":
    validator = ProxyValidatorEnhanced()
    validator.run()