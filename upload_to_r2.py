#!/usr/bin/env python3
import os
import boto3
import glob
import json
from botocore.config import Config

def upload_to_r2():
    """
    Upload semua file JSON ke Cloudflare R2 Storage
    """
    # Ambil kredensial dari environment variables
    r2_access_key_id = os.environ.get('R2_ACCESS_KEY_ID')
    r2_secret_access_key = os.environ.get('R2_SECRET_ACCESS_KEY')
    r2_account_id = os.environ.get('R2_ACCOUNT_ID')
    r2_bucket_name = os.environ.get('R2_BUCKET_NAME', 'cloud')
    
    # Validasi kredensial
    if not all([r2_access_key_id, r2_secret_access_key, r2_account_id]):
        print("Error: R2 credentials not found in environment variables")
        print("Please set R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, and R2_ACCOUNT_ID")
        return False
    
    # Konfigurasi endpoint R2
    endpoint_url = f'https://{r2_account_id}.r2.cloudflarestorage.com'
    
    # Inisialisasi klien S3 (R2 kompatibel dengan API S3)
    s3_config = Config(
        region_name='auto',
        signature_version='s3v4',
    )
    
    s3_client = boto3.client(
        's3',
        endpoint_url=endpoint_url,
        aws_access_key_id=r2_access_key_id,
        aws_secret_access_key=r2_secret_access_key,
        config=s3_config
    )
    
    # Cari semua file JSON di direktori saat ini
    json_files = glob.glob('*.json')
    
    if not json_files:
        print("No JSON files found to upload")
        return False
    
    # Ambil nama folder dari environment variable (default: "sing-box_config")
    folder_name = os.environ.get('R2_FOLDER_NAME', 'sing-box_config')
    
    # Pastikan folder name tidak memiliki trailing slash
    if folder_name.endswith('/'):
        folder_name = folder_name[:-1]
    
    # Upload setiap file JSON
    uploaded_files = []
    for json_file in json_files:
        try:
            # Buat key dengan format: folder_name/file_name
            object_key = f"{folder_name}/{json_file}"
            
            print(f"Uploading {json_file} to R2 folder '{folder_name}'...")
            
            # Set Content-Type header
            s3_client.upload_file(
                json_file, 
                r2_bucket_name, 
                object_key,
                ExtraArgs={'ContentType': 'application/json'}
            )
            
            # Buat file publik (jika diinginkan)
            s3_client.put_object_acl(
                Bucket=r2_bucket_name,
                Key=object_key,
                ACL='public-read'
            )
            
            # Dapatkan URL publik
            file_url = f'https://{r2_bucket_name}.{r2_account_id}.r2.cloudflarestorage.com/{object_key}'
            uploaded_files.append({"file": json_file, "url": file_url})
            
            print(f"Successfully uploaded {json_file} to R2")
            print(f"Public URL: {file_url}")
            
        except Exception as e:
            print(f"Error uploading {json_file}: {str(e)}")
    
    # Buat file ringkasan upload
    if uploaded_files:
        summary = {
            "uploaded_files": uploaded_files,
            "total_files": len(uploaded_files)
        }
        
        with open('upload_summary.json', 'w') as f:
            json.dump(summary, f, indent=4)
        
        print(f"Successfully uploaded {len(uploaded_files)} files to R2")
        return True
    
    return False

if __name__ == "__main__":
    upload_to_r2()