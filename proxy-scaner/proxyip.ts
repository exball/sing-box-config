// Daftar token dari proxy_validator_ipinfo.py
const API_TOKENS = [
  "78b59887616e57",
  "ea23036aa3f797",
  "2c18bfaab2f28c",
  "c89402dd5554ac",
  "df780be2632088",
  "878e3e53210405",
  "04b42435d8eded"
];

const TOKEN_INDEX_FILE = ".ipinfo_token_index";

// Fungsi untuk membaca indeks token terakhir dari file dan rotasi
async function getNextTokenIndex(): Promise<number> {
  let idx = 0;
  try {
    const file = Bun.file(TOKEN_INDEX_FILE);
    if (await file.exists()) {
      const content = await file.text();
      const lastIdx = parseInt(content.trim());
      if (!isNaN(lastIdx)) {
        idx = (lastIdx + 1) % API_TOKENS.length;
      }
    }
  } catch {}
  await Bun.write(TOKEN_INDEX_FILE, idx.toString());
  return idx;
}
import * as tls from "tls";

interface ProxyStruct {
  address: string;
  port: number;
  country: string;
  org: string;
}

interface ProxyTestResult {
  error: boolean;
  message?: string;
  result?: {
    proxy: string;
    proxyip: boolean;
    ip: string;
    port: number;
    delay: number;
    country: string;
    countryCode: string;
    isp: string;
    org: string;
    as: string;
    asname: string;
    asOrganization: string;
  };
}

interface ProxyHistoryEntry {
  address: string;
  port: number;
  country: string;
  org: string;
  activeCount: number;
  isCurrentlyActive: boolean;
}

interface ProxyHistory {
  totalChecksRun: number;
  proxies: { [key: string]: ProxyHistoryEntry };
}

interface IPDataEntry {
  ip: string[];
  country: string;      // country code, misal "ID"
  asn: string;          // ASN number, misal "AS63949"
  as_name: string;      // Organization/AS name
}

interface Statistics {
  totalProxies: 0;
  uniqueIPs: 0;
  cacheHits: 0;
  jsonLookups: 0;
  missingIPs: 0;
  batchAPIRequests: 0;
  countriesLoaded: 0;
}

let myGeoIpString: any = null;

// Cache untuk IP yang sudah diperiksa (untuk multiple ports)
const ipDataCache = new Map<string, IPDataEntry>();

// Cache untuk IP yang tidak ditemukan (untuk batch API)
const missingIPsCache = new Set<string>();

// Cache untuk file JSON yang sudah di-load
const countryDataCache = new Map<string, IPDataEntry[]>();

// Statistics
const stats: Statistics = {
  totalProxies: 0,
  uniqueIPs: 0,
  cacheHits: 0,
  jsonLookups: 0,
  missingIPs: 0,
  batchAPIRequests: 0,
  countriesLoaded: 0
};

// Country code to country name mapping
const countryMapping: { [key: string]: string } = {
  'AE': 'United Arab Emirates',
  'AL': 'Albania',
  'AM': 'Armenia',
  'AR': 'Argentina',
  'AT': 'Austria',
  'AU': 'Australia',
  'AZ': 'Azerbaijan',
  'BE': 'Belgium',
  'BG': 'Bulgaria',
  'BR': 'Brazil',
  'CA': 'Canada',
  'CH': 'Switzerland',
  'CN': 'China',
  'CO': 'Colombia',
  'CY': 'Cyprus',
  'CZ': 'Czech Republic',
  'DE': 'Germany',
  'DK': 'Denmark',
  'EE': 'Estonia',
  'EG': 'Egypt',
  'ES': 'Spain',
  'FI': 'Finland',
  'FR': 'France',
  'GB': 'United Kingdom',
  'GE': 'Georgia',
  'HK': 'Hong Kong',
  'HU': 'Hungary',
  'ID': 'Indonesia',
  'IE': 'Ireland',
  'IL': 'Israel',
  'IN': 'India',
  'IR': 'Iran',
  'IT': 'Italy',
  'JP': 'Japan',
  'KR': 'South Korea',
  'KZ': 'Kazakhstan',
  'LT': 'Lithuania',
  'LU': 'Luxembourg',
  'LV': 'Latvia',
  'MD': 'Moldova',
  'MU': 'Mauritius',
  'MX': 'Mexico',
  'MY': 'Malaysia',
  'NL': 'Netherlands',
  'NZ': 'New Zealand',
  'PH': 'Philippines',
  'PL': 'Poland',
  'PR': 'Puerto Rico',
  'PT': 'Portugal',
  'QA': 'Qatar',
  'RO': 'Romania',
  'RS': 'Serbia',
  'RU': 'Russia',
  'SA': 'Saudi Arabia',
  'SE': 'Sweden',
  'SG': 'Singapore',
  'SK': 'Slovakia',
  'TH': 'Thailand',
  'TR': 'Turkey',
  'TW': 'Taiwan',
  'UA': 'Ukraine',
  'US': 'United States',
  'UZ': 'Uzbekistan',
  'VN': 'Vietnam',
  'ZA': 'South Africa'
};

// File paths
const KV_PAIR_PROXY_FILE = "./kvProxyList.json";
const RAW_PROXY_LIST_FILE = "./rawProxyList.txt";
const PROXY_LIST_FILE = "./proxyList.txt";
const ACTIVE_PROXY_HISTORY_FILE = "./active-proxy-history.txt";
const PROXY_DATA_DIR = "./proxy_data";

// Fungsi untuk menentukan domain resolver berdasarkan waktu UTC+8
function getResolverDomain(): string {
  const now = new Date();
  // Konversi ke UTC+8 (tambah 8 jam ke UTC)
  const utcPlus8 = new Date(now.getTime() + (8 * 60 * 60 * 1000));
  const hour = utcPlus8.getUTCHours();

  // Pembagian 4 domain dengan periode 6 jam masing-masing:
  // 00:00-05:59 UTC+8 → ip.resolver1.workers.dev
  // 06:00-11:59 UTC+8 → ip.resolver2.workers.dev
  // 12:00-17:59 UTC+8 → ip.resolver3.workers.dev
  // 18:00-23:59 UTC+8 → ip.resolver4.workers.dev
  if (hour >= 0 && hour < 6) {
    return "ip.resolver1.workers.dev";
  } else if (hour >= 6 && hour < 12) {
    return "ip.resolver2.workers.dev";
  } else if (hour >= 12 && hour < 18) {
    return "ip.resolver3.workers.dev";
  } else {
    return "ip.resolver4.workers.dev";
  }
}

const IP_RESOLVER_PATH = "/";
const CONCURRENCY = 60;

const CHECK_QUEUE: string[] = [];

// Load country data on-demand
async function loadCountryData(countryCode: string): Promise<IPDataEntry[]> {
  // Cek cache dulu
  if (countryDataCache.has(countryCode)) {
    return countryDataCache.get(countryCode)!;
  }
  
  try {
    const filePath = `${PROXY_DATA_DIR}/${countryCode}.json`;
    const data = await Bun.file(filePath).json() as IPDataEntry[];
    
    // Cache untuk penggunaan berikutnya
    countryDataCache.set(countryCode, data);
    stats.countriesLoaded++;
    console.log(`📂 Loaded ${data.length} IPs from ${countryCode}.json`);
    
    return data;
  } catch (error) {
    console.log(`⚠️ Failed to load ${countryCode}.json`);
    countryDataCache.set(countryCode, []); // Cache empty array
    return [];
  }
}

// Find IP in specific country data
async function findIPInCountryData(ip: string, countryCode: string): Promise<IPDataEntry | null> {
  const countryData = await loadCountryData(countryCode);
  // Format baru: cari IP pada array 'ip'
  const ipData = countryData.find(entry => Array.isArray(entry.ip) && entry.ip.includes(ip));
  if (ipData) {
    stats.jsonLookups++;
    return ipData;
  } else {
    return null;
  }
}

// Cache-aware IP lookup
async function getIPData(ip: string, countryCode: string): Promise<IPDataEntry> {
  if (ipDataCache.has(ip)) {
    stats.cacheHits++;
    return ipDataCache.get(ip)!;
  }
  // 2. Cari di file JSON negara spesifik
  const ipData = await findIPInCountryData(ip, countryCode);
  if (ipData) {
    // 3. Create individual IP data for caching (normalize from group data)
    const individualIPData: IPDataEntry = {
      ip: [ip],
      country: ipData.country,
      asn: ipData.asn,
      as_name: ipData.as_name
    };
  ipDataCache.set(ip, individualIPData);
  return individualIPData;
  } else {
    // 4. Tambah ke missing IPs untuk batch API nanti
    missingIPsCache.add(ip);
    stats.missingIPs++;
    console.log(`❌ IP ${ip} not found in ${countryCode}.json - added to batch queue`);
    // 5. Return fallback data sementara
    const fallbackData: IPDataEntry = {
      ip: [ip],
      country: countryMapping[countryCode] || countryCode,
      asn: "-",
      as_name: "-"
    };
    return fallbackData;
  }
}

// Batch API lookup for missing IPs
async function batchLookupMissingIPs(): Promise<void> {
  if (missingIPsCache.size === 0) {
    console.log("✅ No missing IPs to lookup via API");
    return;
  }
  console.log(`🔍 Starting batch IP lookup for ${missingIPsCache.size} missing IPs via ipinfo.io`);
  const missingIPs = Array.from(missingIPsCache);
  const BATCH_SIZE = 250; // ipinfo.io batch limit
    // Ambil indeks token berikutnya
    const tokenIdx = await getNextTokenIndex();
    const API_TOKEN = API_TOKENS[tokenIdx];
    console.log(`🔑 Menggunakan IPinfo Token #${tokenIdx + 1}: ...${API_TOKEN.slice(-8)}`);
  const API_URL = `https://api.ipinfo.io/batch/lite?token=${API_TOKEN}`;
  for (let i = 0; i < missingIPs.length; i += BATCH_SIZE) {
    const batch = missingIPs.slice(i, i + BATCH_SIZE);
    let attempt = 0;
    let success = false;
    while (attempt < 5 && !success) {
      attempt++;
      try {
        console.log(`📡 API Batch ${Math.floor(i/BATCH_SIZE) + 1}: ${batch.length} IPs (Attempt ${attempt})`);
        const response = await fetch(API_URL, {
          method: 'POST',
          headers: {
            'Content-Type': 'text/plain',
            'User-Agent': 'ProxyScanner/1.0'
          },
          body: batch.join('\n')
        });
        if (response.ok) {
          const results = await response.json();
          // results: { [ip: string]: {...} }
          const processed: IPDataEntry[] = [];
          for (const ip of Object.keys(results)) {
            const data = results[ip];
            processed.push({
              ip: [ip],
              country: data.country || '-',
              asn: data.org ? data.org.split(' ')[0] : '-',
              as_name: data.org ? data.org.split(' ').slice(1).join(' ') : '-'
            });
            ipDataCache.set(ip, processed[processed.length-1]);
          }
          await updateCountryJSONFileBatch(processed);
          stats.batchAPIRequests++;
          if (i + BATCH_SIZE < missingIPs.length) {
            console.log("⏳ Waiting 5 seconds for rate limiting...");
            await new Promise(resolve => setTimeout(resolve, 5000));
          }
          success = true;
        } else {
          console.log(`❌ API request failed: ${response.status} (Attempt ${attempt})`);
        }
      } catch (error: any) {
        console.log(`❌ Batch API error (Attempt ${attempt}):`, error.message);
      }
      if (!success && attempt < 5) {
        console.log("🔁 Retrying batch in 3 seconds...");
        await new Promise(resolve => setTimeout(resolve, 3000));
      }
    }
    if (!success) {
      console.log(`❌ Batch failed after 5 attempts. Skipping this batch.`);
    }
  }
}

// Process batch results and update JSON files (ipinfo.io only)
async function processBatchResults(results: { [ip: string]: any }): Promise<void> {
  const countryUpdates = new Map<string, IPDataEntry[]>();
  for (const ip of Object.keys(results)) {
    const data = results[ip];
    // ipinfo.io always returns the IP as the key
    const country = data.country || '-';
    const ipData: IPDataEntry = {
      ip: [ip],
      country: country,
      asn: data.org ? data.org.split(' ')[0] : '-',
      as_name: data.org ? data.org.split(' ').slice(1).join(' ') : '-'
    };
    if (!countryUpdates.has(country)) {
      countryUpdates.set(country, []);
    }
    countryUpdates.get(country)!.push(ipData);
    ipDataCache.set(ip, ipData);
    console.log(`✅ API result cached: ${ip} - ${country} - ${ipData.as_name}`);
  }
  for (const [country, newData] of Array.from(countryUpdates)) {
    await updateCountryJSONFile(country, newData);
  }
}

// Helper function to convert old format to grouped format
function convertToGroupedFormat(data: IPDataEntry[]): IPDataEntry[] {
  if (!data || data.length === 0) return [];
  
  // Check if data is already in grouped format
  const isAlreadyGrouped = data.some(item => Array.isArray(item.ip));
  if (isAlreadyGrouped) return data;
  // Group by metadata
  return groupProxiesByMetadata(data);
}

// Helper function to group proxies by metadata
function groupProxiesByMetadata(proxiesData: IPDataEntry[]): IPDataEntry[] {
  const grouped = new Map<string, IPDataEntry>();
  for (const proxy of proxiesData) {
    // Key: country|asn|as_name
    const metadataKey = `${proxy.country}|${proxy.asn}|${proxy.as_name}`;
    if (!grouped.has(metadataKey)) {
      grouped.set(metadataKey, {
        ip: [],
        country: proxy.country,
        asn: proxy.asn,
        as_name: proxy.as_name
      });
    }
    const group = grouped.get(metadataKey)!;
    for (const ip of proxy.ip) {
      if (!group.ip.includes(ip)) group.ip.push(ip);
    }
  }
  return Array.from(grouped.values());
}

// Helper function to merge grouped data
function mergeGroupedData(existingData: IPDataEntry[], newData: IPDataEntry[]): IPDataEntry[] {
  const existingGroups = new Map<string, IPDataEntry>();
  for (const group of existingData) {
    const metadataKey = `${group.country}|${group.asn}|${group.as_name}`;
    existingGroups.set(metadataKey, group);
  }
  for (const newGroup of newData) {
    const metadataKey = `${newGroup.country}|${newGroup.asn}|${newGroup.as_name}`;
    if (existingGroups.has(metadataKey)) {
      const existingGroup = existingGroups.get(metadataKey)!;
      for (const ip of newGroup.ip) {
        if (!existingGroup.ip.includes(ip)) existingGroup.ip.push(ip);
      }
    } else {
      existingGroups.set(metadataKey, newGroup);
    }
  }
  return Array.from(existingGroups.values());
}

// Update country JSON files with grouping support
async function updateCountryJSONFile(countryCode: string, newData: IPDataEntry[]): Promise<void> {
  const filePath = `${PROXY_DATA_DIR}/${countryCode}.json`;
  try {
    let existingData: IPDataEntry[] = [];
    try {
      existingData = await Bun.file(filePath).json();
    } catch {
      existingData = [];
    }
    // Gabungkan IP ke grup metadata yang sama
    for (const newEntry of newData) {
      const match = existingData.find(e =>
        e.country === newEntry.country &&
        e.asn === newEntry.asn &&
        e.as_name === newEntry.as_name
      );
      if (match) {
        for (const ip of newEntry.ip) {
          if (!match.ip.includes(ip)) match.ip.push(ip);
        }
      } else {
        existingData.push(newEntry);
      }
    }
    await Bun.write(filePath, JSON.stringify(existingData, null, 2));
    countryDataCache.set(countryCode, existingData);
  } catch (error: any) {
    console.log(`❌ Error updating ${countryCode}.json:`, error.message);
  }
}

// Helper untuk batch update banyak country sekaligus
async function updateCountryJSONFileBatch(newData: IPDataEntry[]): Promise<void> {
  const grouped: { [country: string]: IPDataEntry[] } = {};
  for (const entry of newData) {
    if (!grouped[entry.country]) grouped[entry.country] = [];
    grouped[entry.country].push(entry);
  }
  for (const country of Object.keys(grouped)) {
    await updateCountryJSONFile(country, grouped[country]);
  }
}

// Update proxy entries that used fallback data
async function updateProxyListWithAPIResults(): Promise<void> {
  if (missingIPsCache.size === 0) {
    return;
  }
  
  console.log("🔄 Updating proxyList.txt with API results...");
  
  try {
    // Read current proxyList.txt
    const proxyListContent = await Bun.file(PROXY_LIST_FILE).text();
    const lines = proxyListContent.split('\n').filter(line => line.trim());
    
    const updatedLines: string[] = [];
    let updatedCount = 0;
    
    for (const line of lines) {
      const parts = line.split(',');
      if (parts.length >= 4) {
        const ip = parts[0];
        const port = parts[1];
        
        // Check if we have updated data for this IP
        if (ipDataCache.has(ip)) {
          const ipData = ipDataCache.get(ip)!;
          const updatedLine = `${ip},${port},${ipData.country},${ipData.as_name}`;
          updatedLines.push(updatedLine);
          updatedCount++;
        } else {
          updatedLines.push(line);
        }
      } else {
        updatedLines.push(line);
      }
    }
    
    if (updatedCount > 0) {
      await Bun.write(PROXY_LIST_FILE, updatedLines.join('\n'));
      console.log(`✅ Updated ${updatedCount} proxy entries with API data`);
    }
    
  } catch (error: any) {
    console.log(`❌ Error updating proxyList.txt:`, error.message);
  }
}

// Show final statistics
function showFinalStatistics() {
  console.log("\n📊 Final Statistics:");
  console.log(`Total proxies processed: ${stats.totalProxies}`);
  console.log(`Unique IPs encountered: ${stats.uniqueIPs}`);
  console.log(`Cache hits: ${stats.cacheHits}`);
  console.log(`JSON file lookups: ${stats.jsonLookups}`);
  console.log(`Countries loaded: ${stats.countriesLoaded}`);
  console.log(`Missing IPs (API lookup): ${stats.missingIPs}`);
  console.log(`Batch API requests: ${stats.batchAPIRequests}`);
  if (stats.totalProxies > 0) {
    console.log(`Cache hit ratio: ${((stats.cacheHits / stats.totalProxies) * 100).toFixed(2)}%`);
  }
}

async function sendRequest(host: string, path: string, proxy: any = null) {
  return new Promise((resolve, reject) => {
    const options = {
      host: proxy ? proxy.host : host,
      port: proxy ? proxy.port : 443,
      servername: host,
    };

    const socket = tls.connect(options, () => {
      const request =
        `GET ${path} HTTP/1.1\r\n` + `Host: ${host}\r\n` + `User-Agent: Mozilla/5.0\r\n` + `Connection: close\r\n\r\n`;
      socket.write(request);
    });

    let responseBody = "";

    const timeout = setTimeout(() => {
      socket.destroy();
      reject(new Error("socket timeout"));
    }, 5000);

    socket.on("data", (data) => (responseBody += data.toString()));
    socket.on("end", () => {
      clearTimeout(timeout);
      const body = responseBody.split("\r\n\r\n")[1] || "";
      resolve(body);
    });
    socket.on("error", (error) => {
      // console.log(error);
      reject(error);
    });
  });
}

export async function checkProxy(proxyAddress: string, proxyPort: number): Promise<ProxyTestResult> {
  let result: ProxyTestResult = {
    message: "Unknown error",
    error: true,
  };

  const proxyInfo = { host: proxyAddress, port: proxyPort };
  const currentResolverDomain = getResolverDomain();

  try {
    const start = new Date().getTime();
    const [ipinfo, myip] = await Promise.all([
      sendRequest(currentResolverDomain, IP_RESOLVER_PATH, proxyInfo),
      myGeoIpString == null ? sendRequest(currentResolverDomain, IP_RESOLVER_PATH, null) : myGeoIpString,
    ]);
    const finish = new Date().getTime();

    // Save local geoip
    if (myGeoIpString == null) myGeoIpString = myip;

    const parsedIpInfo = JSON.parse(ipinfo as string);
    const parsedMyIp = JSON.parse(myip as string);

    // Check if proxy is active by comparing IPs
    if (parsedIpInfo.ip && parsedIpInfo.ip !== parsedMyIp.ip) {
      // Proxy is active! But use INPUT IP instead of resolver response
      // This solves IPv6 issues and ensures consistent IPv4 usage
      result = {
        error: false,
        result: {
          proxy: proxyAddress,
          port: proxyPort,
          proxyip: true,
          delay: finish - start,
          ip: proxyAddress,  // ← Use input IP, not resolver response
          // Keep other useful info from resolver (but override IP)
          country: parsedIpInfo.country || "Unknown",
          countryCode: parsedIpInfo.countryCode || "Unknown",
          isp: parsedIpInfo.isp || "Unknown ISP",
          org: parsedIpInfo.org || "Unknown Provider",
          as: parsedIpInfo.as || "Unknown AS",
          asname: parsedIpInfo.asname || "Unknown ASName",
          asOrganization: parsedIpInfo.asOrganization || parsedIpInfo.org || "Unknown Provider"
        },
      };
    }
  } catch (error: any) {
    result.message = error.message;
  }

  return result;
}

// async function checkProxy(proxyAddress: string, proxyPort: number): Promise<ProxyTestResult> {
//   const controller = new AbortController();
//   setTimeout(() => controller.abort(), 5000);

//   try {
//     const res = await Bun.fetch(IP_RESOLVER_DOMAIN + `?ip=${proxyAddress}:${proxyPort}`, {
//       signal: controller.signal,
//     });

//     if (res.status == 200) {
//       return {
//         error: false,
//         result: await res.json(),
//       };
//     } else {
//       throw new Error(res.statusText);
//     }
//   } catch (e: any) {
//     return {
//       error: true,
//       message: e.message,
//     };
//   }
// }

async function readProxyList(): Promise<ProxyStruct[]> {
  const proxyList: ProxyStruct[] = [];

  const proxyListString = (await Bun.file(RAW_PROXY_LIST_FILE).text()).split("\n");
  for (const proxy of proxyListString) {
    // Skip empty lines and comment lines
    if (!proxy.trim() || proxy.trim().startsWith('#')) continue;
    
    const parts = proxy.split(",");
    
    // Skip invalid entries (must have at least 3 parts: address, port, country)
    if (parts.length < 3) continue;
    
    const address = parts[0];
    const port = parts[1];
    const country = parts[2];
    
    // Join remaining parts as org (in case org contains commas)
    const org = parts.length > 3 ? parts.slice(3).join(",") : "Unknown";
    
    // Skip invalid entries (must have address and port)
    if (!address || !port) continue;
    
    proxyList.push({
      address,
      port: parseInt(port),
      country: country || "Unknown",
      org: org || "Unknown",
    });
  }

  return proxyList;
}

async function readProxyHistory(): Promise<ProxyHistory> {
  try {
    const historyFile = Bun.file(ACTIVE_PROXY_HISTORY_FILE);
    if (await historyFile.exists()) {
      const content = await historyFile.text();
      const lines = content.split('\n');
      
      if (lines.length === 0) {
        return { totalChecksRun: 0, proxies: {} };
      }

      // Parse total checks run
      const totalChecksLine = lines[0];
      const totalChecksMatch = totalChecksLine.match(/Total checks run = (\d+)/);
      const totalChecksRun = totalChecksMatch ? parseInt(totalChecksMatch[1]) : 0;

      const proxies: { [key: string]: ProxyHistoryEntry } = {};
      
      // Parse proxy entries (skip first line, country summary, separator line, country headers, and statistics)
      for (let i = 1; i < lines.length; i++) {
        const line = lines[i];
        const trimmedLine = line.trim();
        if (trimmedLine === '' || 
            trimmedLine.startsWith('----------') || 
            trimmedLine.startsWith('--------------------') || 
            trimmedLine.startsWith('#') || 
            line.startsWith('  - ') ||
            trimmedLine.startsWith('- ') && trimmedLine.includes(' = ') && trimmedLine.includes(' Active')) continue;
        
        const parts = trimmedLine.split(' = ');
        if (parts.length === 2) {
          const proxyInfo = parts[0];
          const activeCount = parseInt(parts[1]);
          const [address, port, country, org] = proxyInfo.split(',');
          
          const key = `${address}:${port}`;
          proxies[key] = {
            address,
            port: parseInt(port),
            country,
            org,
            activeCount,
            isCurrentlyActive: false // Will be updated during current check
          };
        }
      }

      return { totalChecksRun, proxies };
    }
  } catch (error) {
    console.log("Error reading proxy history:", error);
  }
  
  return { totalChecksRun: 0, proxies: {} };
}

async function writeProxyHistory(history: ProxyHistory): Promise<void> {
  const lines: string[] = [];
  
  // Add total checks run
  lines.push(`Total checks run = ${history.totalChecksRun}`);
  lines.push('');
  
  // Calculate and add country summary
  const countrySummary = new Map<string, { total: number; active: number }>();
  
  // Group proxies by country and calculate statistics
  for (const [key, entry] of Object.entries(history.proxies)) {
    const countryName = countryMapping[entry.country] || entry.country;
    
    if (!countrySummary.has(countryName)) {
      countrySummary.set(countryName, { total: 0, active: 0 });
    }
    
    const summary = countrySummary.get(countryName)!;
    summary.total++;
    if (entry.isCurrentlyActive) {
      summary.active++;
    }
  }
  
  // Sort countries alphabetically and add summary
  const sortedCountries = Array.from(countrySummary.entries()).sort((a, b) => a[0].localeCompare(b[0]));
  
  for (const [countryName, stats] of sortedCountries) {
    lines.push(`- ${countryName} = ${stats.active} Active`);
  }
  
  lines.push('');
  lines.push('--------------------');
  lines.push('');
  
  // Sort proxies by country then by activeCount (descending) then by address
  const sortedEntries = Object.entries(history.proxies).sort((a, b) => {
    const [, entryA] = a;
    const [, entryB] = b;
    
    // First sort by country
    const countryCompare = entryA.country.localeCompare(entryB.country);
    if (countryCompare !== 0) return countryCompare;
    
    // Then sort by activeCount (descending - highest first)
    const activeCountCompare = entryB.activeCount - entryA.activeCount;
    if (activeCountCompare !== 0) return activeCountCompare;
    
    // Finally sort by address
    return entryA.address.localeCompare(entryB.address);
  });
  
  // Group entries by country and add country headers with statistics
  let currentCountry = '';
  let countryProxies: ProxyHistoryEntry[] = [];
  
  for (const [key, entry] of sortedEntries) {
    // If country changes, process the previous country's statistics
    if (entry.country !== currentCountry) {
      // Process previous country if it exists
      if (currentCountry !== '' && countryProxies.length > 0) {
        // Calculate statistics for previous country
        const totalProxy = countryProxies.length;
        const currentlyActiveProxy = countryProxies.filter(p => p.isCurrentlyActive).length;
        const everActiveProxy = countryProxies.filter(p => p.activeCount > 0).length;
        const inactiveProxy = countryProxies.filter(p => p.activeCount === 0).length;
        
        // Add statistics
        lines.push(`  - Total Proxy = ${totalProxy}`);
        lines.push(`  - Active = ${currentlyActiveProxy} (${everActiveProxy})`);
        lines.push(`  - Inactive = ${inactiveProxy}`);
        
        // Add proxy entries for previous country (already sorted by activeCount descending)
        for (const proxy of countryProxies) {
          lines.push(`${proxy.address},${proxy.port},${proxy.country},${proxy.org} = ${proxy.activeCount}`);
        }
      }
      
      // Add empty line before new country (except for first country)
      if (currentCountry !== '') {
        lines.push('');
      }
      
      // Add new country header
      const countryName = countryMapping[entry.country] || entry.country;
      lines.push(`# ${countryName} #`);
      currentCountry = entry.country;
      countryProxies = [];
    }
    
    // Add entry to current country's proxy list
    countryProxies.push(entry);
  }
  
  // Process the last country
  if (currentCountry !== '' && countryProxies.length > 0) {
    const totalProxy = countryProxies.length;
    const currentlyActiveProxy = countryProxies.filter(p => p.isCurrentlyActive).length;
    const everActiveProxy = countryProxies.filter(p => p.activeCount > 0).length;
    const inactiveProxy = countryProxies.filter(p => p.activeCount === 0).length;
    
    // Add statistics
    lines.push(`  - Total Proxy = ${totalProxy}`);
    lines.push(`  - Active = ${currentlyActiveProxy} (${everActiveProxy})`);
    lines.push(`  - Inactive = ${inactiveProxy}`);
    
    // Add proxy entries for last country (already sorted by activeCount descending)
    for (const proxy of countryProxies) {
      lines.push(`${proxy.address},${proxy.port},${proxy.country},${proxy.org} = ${proxy.activeCount}`);
    }
  }
  
  await Bun.write(ACTIVE_PROXY_HISTORY_FILE, lines.join('\n'));
}

(async () => {
  console.log("🚀 Starting Enhanced Proxy Scanner with Optimized IP Data Lookup");
  
  const proxyList = await readProxyList();
  const proxyChecked: string[] = [];
  const uniqueRawProxies: string[] = [];
  const activeProxyList: string[] = [];
  const kvPair: any = {};

  // Tampilkan informasi domain resolver yang akan digunakan
  const now = new Date();
  const utcPlus8 = new Date(now.getTime() + (8 * 60 * 60 * 1000));
  const hour = utcPlus8.getUTCHours();
  const resolverDomain = getResolverDomain();
  console.log(`[${utcPlus8.toISOString()}] Menggunakan domain resolver: ${resolverDomain} (jam ${hour.toString().padStart(2, '0')}:xx UTC+8)`);

  // Load existing proxy history
  const proxyHistory = await readProxyHistory();
  proxyHistory.totalChecksRun += 1;

  // Reset all isCurrentlyActive flags to false at the start of each check
  for (const key in proxyHistory.proxies) {
    proxyHistory.proxies[key].isCurrentlyActive = false;
  }

  // Create a set of current proxy keys from rawProxyList.txt for efficient lookup
  const currentProxyKeys = new Set<string>();
  for (const proxy of proxyList) {
    currentProxyKeys.add(`${proxy.address}:${proxy.port}`);
  }

  // Remove proxies from history that are no longer in rawProxyList.txt
  const historyKeys = Object.keys(proxyHistory.proxies);
  let removedProxiesCount = 0;
  for (const historyKey of historyKeys) {
    if (!currentProxyKeys.has(historyKey)) {
      delete proxyHistory.proxies[historyKey];
      removedProxiesCount++;
    }
  }

  if (removedProxiesCount > 0) {
    console.log(`Menghapus ${removedProxiesCount} proxy dari riwayat yang sudah tidak ada di rawProxyList.txt`);
  }

  let proxySaved = 0;

  for (let i = 0; i < proxyList.length; i++) {
    const proxy = proxyList[i];
    const proxyKey = `${proxy.address}:${proxy.port}`;
    
    // Initialize proxy in history if not exists, or update country/org info if changed
    if (!proxyHistory.proxies[proxyKey]) {
      proxyHistory.proxies[proxyKey] = {
        address: proxy.address,
        port: proxy.port,
        country: proxy.country,
        org: (proxy.org || "Unknown").replaceAll(/[+]/g, " "),
        activeCount: 0,
        isCurrentlyActive: false
      };
    } else {
      // Update country and org info in case they changed in rawProxyList.txt
      proxyHistory.proxies[proxyKey].country = proxy.country;
      proxyHistory.proxies[proxyKey].org = (proxy.org || "Unknown").replaceAll(/[+]/g, " ");
    }
    
    if (!proxyChecked.includes(proxyKey)) {
      proxyChecked.push(proxyKey);
      try {
        uniqueRawProxies.push(`${proxy.address},${proxy.port},${proxy.country},${(proxy.org || "Unknown").replaceAll(/[+]/g, " ")}`);
      } catch (e: any) {
        continue;
      }
    } else {
      continue;
    }

    CHECK_QUEUE.push(proxyKey);
    checkProxy(proxy.address, proxy.port)
      .then(async (res) => {
        if (!res.error && res.result?.proxyip === true) {
          const proxyIP = res.result.ip;
          const proxyPort = proxy.port; // Use port from rawProxyList
          
          // Get accurate IP data using country code hint
          const ipData = await getIPData(proxyIP, proxy.country);
          
          // Update proxy history - increment active count and mark as currently active
          proxyHistory.proxies[proxyKey].activeCount += 1;
          proxyHistory.proxies[proxyKey].isCurrentlyActive = true;
          
          // Format output - gunakan as_name dan country (format baru)
          const finalResult = `${proxyIP},${proxyPort},${ipData.country},${ipData.as_name}`;
          activeProxyList.push(finalResult);

          if (kvPair[ipData.country] == undefined) kvPair[ipData.country] = [];
          if (kvPair[ipData.country].length < 100) {
            kvPair[ipData.country].push(`${proxyIP}:${proxyPort}`);
          }

          proxySaved += 1;
          stats.totalProxies++;
          
          // Track unique IPs
          if (!ipDataCache.has(proxyIP)) {
            stats.uniqueIPs++;
          }
          
          console.log(`[${i}/${proxyList.length}] ✅ Saved: ${finalResult}`);
        }
        // Note: If proxy is not active, isCurrentlyActive remains false
      })
      .finally(() => {
        CHECK_QUEUE.pop();
      });

    while (CHECK_QUEUE.length >= CONCURRENCY) {
      await Bun.sleep(1);
    }
  }

  // Waiting for all process to be completed
  while (CHECK_QUEUE.length) {
    await Bun.sleep(1);
  }

  console.log("\n🔍 Processing missing IPs with batch API...");
  
  // Batch lookup missing IPs
  await batchLookupMissingIPs();
  
  // Update proxy list with API results
  await updateProxyListWithAPIResults();

  uniqueRawProxies.sort(sortByCountry);
  activeProxyList.sort(sortByCountry);

  // Save proxy history
  await writeProxyHistory(proxyHistory);

  await Bun.write(KV_PAIR_PROXY_FILE, JSON.stringify(kvPair, null, "  "));
  await Bun.write(RAW_PROXY_LIST_FILE, uniqueRawProxies.join("\n"));
  await Bun.write(PROXY_LIST_FILE, activeProxyList.join("\n"));

  // Show final statistics
  showFinalStatistics();

  console.log(`\n⏱️ Waktu proses: ${(Bun.nanoseconds() / 1000000000).toFixed(2)} detik`);
  console.log(`📊 Total pemeriksaan yang telah dilakukan: ${proxyHistory.totalChecksRun}`);
  console.log(`📁 Riwayat proxy disimpan ke: ${ACTIVE_PROXY_HISTORY_FILE}`);
  console.log(`💾 Proxy saved: ${proxySaved}`);
  
  process.exit(0);
})();

function sortByCountry(a: string, b: string) {
  a = a.split(",")[2];
  b = b.split(",")[2];

  return a.localeCompare(b);
}