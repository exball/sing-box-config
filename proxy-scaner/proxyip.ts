import tls from "tls";

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
    asOrganization: string;
  };
}

interface ProxyHistoryEntry {
  address: string;
  port: number;
  country: string;
  org: string;
  activeCount: number;
}

interface ProxyHistory {
  totalChecksRun: number;
  proxies: { [key: string]: ProxyHistoryEntry };
}

let myGeoIpString: any = null;

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

// Perubahan path file untuk menyesuaikan dengan struktur direktori baru
const KV_PAIR_PROXY_FILE = "./kvProxyList.json";
const RAW_PROXY_LIST_FILE = "./rawProxyList.txt";
const PROXY_LIST_FILE = "./proxyList.txt";
const ACTIVE_PROXY_HISTORY_FILE = "./active-proxy-history.txt";

// Fungsi untuk menentukan domain resolver berdasarkan waktu UTC+8
function getResolverDomain(): string {
  const now = new Date();
  // Konversi ke UTC+8 (tambah 8 jam ke UTC)
  const utcPlus8 = new Date(now.getTime() + (8 * 60 * 60 * 1000));
  const hour = utcPlus8.getUTCHours();
  
  // Gunakan resolver.ex-vpn.my.id dari jam 00:00-11:59 UTC+8
  // Gunakan resolver.exbal.my.id dari jam 12:00-23:59 UTC+8
  if (hour >= 0 && hour < 12) {
    console.log(`[${utcPlus8.toISOString()}] Menggunakan domain: resolver.ex-vpn.my.id (jam ${hour}:xx UTC+8)`);
    return "resolver.ex-vpn.my.id";
  } else {
    console.log(`[${utcPlus8.toISOString()}] Menggunakan domain: resolver.exbal.my.id (jam ${hour}:xx UTC+8)`);
    return "resolver.exbal.my.id";
  }
}

const IP_RESOLVER_PATH = "/";
const CONCURRENCY = 99;

const CHECK_QUEUE: string[] = [];

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

    if (parsedIpInfo.ip && parsedIpInfo.ip !== parsedMyIp.ip) {
      result = {
        error: false,
        result: {
          proxy: proxyAddress,
          port: proxyPort,
          proxyip: true,
          delay: finish - start,
          ...parsedIpInfo,
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
      const totalChecksMatch = totalChecksLine.match(/total checks run = (\d+)/);
      const totalChecksRun = totalChecksMatch ? parseInt(totalChecksMatch[1]) : 0;

      const proxies: { [key: string]: ProxyHistoryEntry } = {};
      
      // Parse proxy entries (skip first line, separator line, country headers, and statistics)
      for (let i = 2; i < lines.length; i++) {
        const line = lines[i];
        const trimmedLine = line.trim();
        if (trimmedLine === '' || trimmedLine.startsWith('----------') || trimmedLine.startsWith('#') || line.startsWith('  - ')) continue;
        
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
            activeCount
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
  lines.push(`total checks run = ${history.totalChecksRun}`);
  lines.push('----------');
  
  // Sort proxies by country then by address
  const sortedEntries = Object.entries(history.proxies).sort((a, b) => {
    const [, entryA] = a;
    const [, entryB] = b;
    
    // First sort by country
    const countryCompare = entryA.country.localeCompare(entryB.country);
    if (countryCompare !== 0) return countryCompare;
    
    // Then sort by address
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
        const activeProxy = countryProxies.filter(p => p.activeCount > 0).length;
        const inactiveProxy = countryProxies.filter(p => p.activeCount === 0).length;
        
        // Add statistics
        lines.push(`  - Total Proxy = ${totalProxy}`);
        lines.push(`  - Active = ${activeProxy}`);
        lines.push(`  - Inactive = ${inactiveProxy}`);
        
        // Add proxy entries for previous country
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
    const activeProxy = countryProxies.filter(p => p.activeCount > 0).length;
    const inactiveProxy = countryProxies.filter(p => p.activeCount === 0).length;
    
    // Add statistics
    lines.push(`  - Total Proxy = ${totalProxy}`);
    lines.push(`  - Active = ${activeProxy}`);
    lines.push(`  - Inactive = ${inactiveProxy}`);
    
    // Add proxy entries for last country
    for (const proxy of countryProxies) {
      lines.push(`${proxy.address},${proxy.port},${proxy.country},${proxy.org} = ${proxy.activeCount}`);
    }
  }
  
  await Bun.write(ACTIVE_PROXY_HISTORY_FILE, lines.join('\n'));
}

(async () => {
  const proxyList = await readProxyList();
  const proxyChecked: string[] = [];
  const uniqueRawProxies: string[] = [];
  const activeProxyList: string[] = [];
  const kvPair: any = {};

  // Load existing proxy history
  const proxyHistory = await readProxyHistory();
  proxyHistory.totalChecksRun += 1;

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
        activeCount: 0
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
      .then((res) => {
        if (!res.error && res.result?.proxyip === true && res.result.country) {
          // Update proxy history - increment active count
          proxyHistory.proxies[proxyKey].activeCount += 1;
          
          activeProxyList.push(
            `${res.result?.proxy},${res.result?.port},${res.result?.country},${res.result?.asOrganization}`
          );

          if (kvPair[res.result.country] == undefined) kvPair[res.result.country] = [];
          if (kvPair[res.result.country].length < 100) {
            kvPair[res.result.country].push(`${res.result.proxy}:${res.result.port}`);
          }

          proxySaved += 1;
          console.log(`[${i}/${proxyList.length}] Proxy disimpan:`, proxySaved);
        }
        // Note: If proxy is not active, we don't increment the activeCount (it stays the same)
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

  uniqueRawProxies.sort(sortByCountry);
  activeProxyList.sort(sortByCountry);

  // Save proxy history
  await writeProxyHistory(proxyHistory);

  await Bun.write(KV_PAIR_PROXY_FILE, JSON.stringify(kvPair, null, "  "));
  await Bun.write(RAW_PROXY_LIST_FILE, uniqueRawProxies.join("\n"));
  await Bun.write(PROXY_LIST_FILE, activeProxyList.join("\n"));

  console.log(`Waktu proses: ${(Bun.nanoseconds() / 1000000000).toFixed(2)} detik`);
  console.log(`Total pemeriksaan yang telah dilakukan: ${proxyHistory.totalChecksRun}`);
  console.log(`Riwayat proxy disimpan ke: ${ACTIVE_PROXY_HISTORY_FILE}`);
  process.exit(0);
})();

function sortByCountry(a: string, b: string) {
  a = a.split(",")[2];
  b = b.split(",")[2];

  return a.localeCompare(b);
}