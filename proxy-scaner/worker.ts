// Worker for parallel proxy checking
import * as tls from "tls";

export type ProxyStruct = {
  address: string;
  port: number;
  country: string;
  org?: string;
};

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

// Timeout configuration (adjust here)
export const FAST_TIMEOUT_MS = 2000;   // First pass timeout
export const RETRY_TIMEOUT_MS = 5000;  // Retry pass timeout

const IP_RESOLVER_PATH = "/";

function getResolverDomain(): string {
  const now = new Date();
  const utcPlus8 = new Date(now.getTime() + 8 * 60 * 60 * 1000);
  const hour = utcPlus8.getUTCHours();
  if (hour >= 0 && hour < 6) return "resolver.exbal.my.id";
  if (hour >= 6 && hour < 12) return "resolver.ex-vpn.my.id";
  if (hour >= 12 && hour < 18) return "resolver.xtunnel.my.id";
  return "resolver.ex27.my.id";
}

async function sendRequest(host: string, path: string, proxy: any = null, timeoutMs: number = 5000) {
  return new Promise((resolve, reject) => {
    const options = {
      host: proxy ? proxy.host : host,
      port: proxy ? proxy.port : 443,
      servername: host,
    };

    const socket = tls.connect(options, () => {
      const request =
        `GET ${path} HTTP/1.1\r\n` +
        `Host: ${host}\r\n` +
        `User-Agent: Mozilla/5.0\r\n` +
        `Connection: close\r\n\r\n`;
      socket.write(request);
    });

    let responseBody = "";

    const timeout = setTimeout(() => {
      socket.destroy();
      reject(new Error("socket timeout"));
    }, timeoutMs);

    socket.on("data", (data) => (responseBody += data.toString()));
    socket.on("end", () => {
      clearTimeout(timeout);
      const body = responseBody.split("\r\n\r\n")[1] || "";
      resolve(body);
    });
    socket.on("error", (error) => reject(error));
  });
}

let myGeoIpString: any = null;

async function checkProxy(proxyAddress: string, proxyPort: number, timeoutMs: number = 3000): Promise<ProxyTestResult> {
  let result: ProxyTestResult = { error: true, message: "Unknown error" };
  const proxyInfo = { host: proxyAddress, port: proxyPort };
  const currentResolverDomain = getResolverDomain();

  try {
    const start = Date.now();
    const [ipinfo, myip] = await Promise.all([
      sendRequest(currentResolverDomain, IP_RESOLVER_PATH, proxyInfo, timeoutMs),
      myGeoIpString == null ? sendRequest(currentResolverDomain, IP_RESOLVER_PATH, null, timeoutMs) : myGeoIpString,
    ]);
    const finish = Date.now();

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
          // Use input IP for consistency
          ip: proxyAddress,
          country: parsedIpInfo.country || "Unknown",
          countryCode: parsedIpInfo.countryCode || "Unknown",
          isp: parsedIpInfo.isp || "Unknown ISP",
          org: parsedIpInfo.org || "Unknown Provider",
          as: parsedIpInfo.as || "Unknown AS",
          asname: parsedIpInfo.asname || "Unknown ASName",
          asOrganization: parsedIpInfo.asOrganization || parsedIpInfo.org || "Unknown Provider",
        },
      };
    }
  } catch (e: any) {
    result = { error: true, message: e?.message || String(e) };
  }

  return result;
}

// Web Worker API
export type WorkerInit = { proxies: ProxyStruct[]; concurrency: number; timeoutMs?: number };

// Use loose typing to avoid requiring WebWorker lib in tsconfig
const ctx: any = self as any;

ctx.onmessage = async (ev: any) => {
  const { proxies, concurrency, timeoutMs = 3000 } = ev.data as WorkerInit;
  const results: { ip: string; port: number; countryCode: string }[] = [];

  let index = 0;
  async function loop() {
    while (true) {
      const i = index++;
      if (i >= proxies.length) break;
      const p = proxies[i];
      try {
        const r = await checkProxy(p.address, p.port, timeoutMs);
        if (!r.error && r.result?.proxyip) {
          results.push({ ip: r.result.ip, port: p.port, countryCode: p.country });
        }
      } catch {}
    }
  }

  const workers = Array.from({ length: Math.max(1, concurrency || 1) }, () => loop());
  await Promise.all(workers);

  ctx.postMessage({ type: "done", results });
};