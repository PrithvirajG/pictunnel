// Prints this machine's LAN IPv4 address, the one phones on the same Wi-Fi use to reach the
// server (task proto:up puts it into the pairing QR code). Virtual adapters (WSL, Hyper-V,
// Docker, VPNs) are skipped. Prints nothing when no address qualifies.
import { networkInterfaces } from "node:os";
import { pathToFileURL } from "node:url";

const VIRTUAL = /vEthernet|WSL|Hyper-V|docker|^br-|^veth|virbr|VirtualBox|VMware|Loopback|Tailscale|ZeroTier|utun|tun\d|wg\d/i;
const PHYSICAL = /Wi-?Fi|WLAN|Wireless|Ethernet|^en|^eth|^wl/i;

function privateV4(ip) {
  const [a, b] = ip.split(".").map(Number);
  return a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168);
}

/** Picks the best LAN address from os.networkInterfaces()-shaped input, or "". */
export function pickLanIp(ifaces) {
  let best = "";
  let bestScore = -1;
  for (const [name, addrs] of Object.entries(ifaces)) {
    if (VIRTUAL.test(name)) continue;
    for (const a of addrs ?? []) {
      const v4 = a.family === "IPv4" || a.family === 4;
      if (!v4 || a.internal || !privateV4(a.address)) continue;
      const score = (PHYSICAL.test(name) ? 2 : 0) + (a.address.startsWith("192.168.") ? 1 : 0);
      if (score > bestScore) {
        best = a.address;
        bestScore = score;
      }
    }
  }
  return best;
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  process.stdout.write(pickLanIp(networkInterfaces()));
}
