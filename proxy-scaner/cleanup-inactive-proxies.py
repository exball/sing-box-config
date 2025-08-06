#!/usr/bin/env python3
"""
Proxy Cleanup Tool
This tool removes proxies with activeCount = 0 from rawProxyList.txt
"""

import os
import sys
import shutil
from typing import Set, List

# File paths
RAW_PROXY_LIST_FILE = "./rawProxyList.txt"
ACTIVE_PROXY_HISTORY_FILE = "./active-proxy-history.txt"
RAW_PROXY_LIST_BACKUP_FILE = "./rawProxyList.txt.backup"

def parse_proxy_history() -> Set[str]:
    """Parse active-proxy-history.txt and get inactive proxies"""
    inactive_proxies = set()
    
    try:
        with open(ACTIVE_PROXY_HISTORY_FILE, 'r', encoding='utf-8') as f:
            lines = f.readlines()
        
        for line in lines:
            trimmed_line = line.strip()
            
            # Skip empty lines, headers, and statistics lines
            if (not trimmed_line or 
                trimmed_line.startswith('#') or 
                trimmed_line.startswith('total checks run') or
                trimmed_line.startswith('----------') or
                trimmed_line.startswith('  - ')):
                continue
            
            # Parse proxy lines: IP,PORT,COUNTRY,ORG = ACTIVE_COUNT
            equal_index = trimmed_line.rfind(' = ')
            if equal_index == -1:
                continue
            
            proxy_part = trimmed_line[:equal_index]
            active_count_str = trimmed_line[equal_index + 3:]
            
            try:
                active_count = int(active_count_str)
            except ValueError:
                continue
            
            # If active count is 0, add to inactive set
            if active_count == 0:
                parts = proxy_part.split(',')
                if len(parts) >= 2:
                    ip = parts[0]
                    port = parts[1]
                    proxy_key = f"{ip},{port}"
                    inactive_proxies.add(proxy_key)
        
        print(f"📊 Found {len(inactive_proxies)} inactive proxies (activeCount = 0)")
        return inactive_proxies
        
    except Exception as error:
        print(f"❌ Error reading proxy history: {error}")
        return set()

def cleanup_raw_proxy_list():
    """Clean up rawProxyList.txt"""
    try:
        # First, create a backup of the original file
        with open(RAW_PROXY_LIST_FILE, 'r', encoding='utf-8') as f:
            original_content = f.read()
        
        with open(RAW_PROXY_LIST_BACKUP_FILE, 'w', encoding='utf-8') as f:
            f.write(original_content)
        print(f"💾 Backup created: {RAW_PROXY_LIST_BACKUP_FILE}")
        
        # Get inactive proxies from history
        inactive_proxies = parse_proxy_history()
        
        if len(inactive_proxies) == 0:
            print("✅ No inactive proxies found. Nothing to clean up.")
            return
        
        # Read and process rawProxyList.txt
        raw_proxy_lines = [line.strip() for line in original_content.split('\n') if line.strip()]
        active_proxy_lines = []
        removed_count = 0
        
        print(f"📋 Processing {len(raw_proxy_lines)} proxies from rawProxyList.txt")
        
        for line in raw_proxy_lines:
            parts = line.split(',')
            if len(parts) >= 2:
                ip = parts[0]
                port = parts[1]
                proxy_key = f"{ip},{port}"
                
                if proxy_key in inactive_proxies:
                    print(f"🗑️  Removing inactive proxy: {proxy_key}")
                    removed_count += 1
                else:
                    active_proxy_lines.append(line)
            else:
                # Keep malformed lines as-is
                active_proxy_lines.append(line)
        
        # Write cleaned content back to file
        cleaned_content = '\n'.join(active_proxy_lines)
        with open(RAW_PROXY_LIST_FILE, 'w', encoding='utf-8') as f:
            f.write(cleaned_content)
        
        print(f"\n✅ Cleanup completed!")
        print(f"📊 Statistics:")
        print(f"   - Original proxies: {len(raw_proxy_lines)}")
        print(f"   - Removed inactive: {removed_count}")
        print(f"   - Remaining active: {len(active_proxy_lines)}")
        print(f"   - Backup saved to: {RAW_PROXY_LIST_BACKUP_FILE}")
        
    except Exception as error:
        print(f"❌ Error during cleanup: {error}")

def preview_cleanup():
    """Show preview of what will be removed"""
    try:
        inactive_proxies = parse_proxy_history()
        
        if len(inactive_proxies) == 0:
            print("✅ No inactive proxies found. Nothing to clean up.")
            return
        
        with open(RAW_PROXY_LIST_FILE, 'r', encoding='utf-8') as f:
            raw_proxy_content = f.read()
        
        raw_proxy_lines = [line.strip() for line in raw_proxy_content.split('\n') if line.strip()]
        
        print(f"\n🔍 Preview of proxies that will be removed:")
        print(f"   (Proxies with activeCount = 0 in {ACTIVE_PROXY_HISTORY_FILE})")
        print("=" * 60)
        
        preview_count = 0
        total_to_remove = 0
        
        for line in raw_proxy_lines:
            parts = line.split(',')
            if len(parts) >= 2:
                ip = parts[0]
                port = parts[1]
                proxy_key = f"{ip},{port}"
                
                if proxy_key in inactive_proxies:
                    if preview_count < 20:  # Limit preview to first 20 items
                        print(f"   {line}")
                        preview_count += 1
                    total_to_remove += 1
        
        if total_to_remove > preview_count:
            remaining = total_to_remove - preview_count
            print(f"   ... and {remaining} more proxies")
        
        print("=" * 60)
        print(f"📊 Total proxies to be removed: {total_to_remove}")
        print(f"📊 Total proxies in rawProxyList.txt: {len(raw_proxy_lines)}")
        print(f"📊 Proxies that will remain: {len(raw_proxy_lines) - total_to_remove}")
        
    except Exception as error:
        print(f"❌ Error during preview: {error}")

def main():
    print("🧹 Proxy Cleanup Tool")
    print("This tool removes proxies with activeCount = 0 from rawProxyList.txt\n")
    
    # Check if required files exist
    if not os.path.exists(RAW_PROXY_LIST_FILE):
        print(f"❌ File not found: {RAW_PROXY_LIST_FILE}")
        sys.exit(1)
    
    if not os.path.exists(ACTIVE_PROXY_HISTORY_FILE):
        print(f"❌ File not found: {ACTIVE_PROXY_HISTORY_FILE}")
        sys.exit(1)
    
    # Get command line argument
    if len(sys.argv) < 2:
        print("Usage:")
        print("  python3 cleanup-inactive-proxies.py preview  - Show what will be removed")
        print("  python3 cleanup-inactive-proxies.py cleanup  - Actually remove inactive proxies")
        print("")
        print("Short forms:")
        print("  python3 cleanup-inactive-proxies.py p        - Preview")
        print("  python3 cleanup-inactive-proxies.py c        - Cleanup")
        return
    
    command = sys.argv[1].lower()
    
    if command in ['preview', 'p']:
        preview_cleanup()
    elif command in ['cleanup', 'clean', 'c']:
        cleanup_raw_proxy_list()
    else:
        print("❌ Invalid command. Use 'preview' or 'cleanup'")
        sys.exit(1)

if __name__ == "__main__":
    main()