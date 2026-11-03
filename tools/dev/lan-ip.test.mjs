import { test } from "node:test";
import assert from "node:assert/strict";
import { pickLanIp } from "./lan-ip.mjs";

const v4 = (address, internal = false) => ({ address, family: "IPv4", internal });

test("prefers the Wi-Fi adapter over WSL, Hyper-V and Docker adapters", () => {
  const ip = pickLanIp({
    "Loopback Pseudo-Interface 1": [v4("127.0.0.1", true)],
    "vEthernet (WSL (Hyper-V firewall))": [v4("172.20.240.1")],
    "vEthernet (Default Switch)": [v4("172.28.32.1")],
    "Wi-Fi": [{ address: "fe80::1", family: "IPv6", internal: false }, v4("192.168.1.20")],
    docker0: [v4("172.17.0.1")],
  });
  assert.equal(ip, "192.168.1.20");
});

test("takes a 10.x Ethernet address when that is the LAN", () => {
  assert.equal(pickLanIp({ Ethernet: [v4("10.0.0.7")], "vEthernet (WSL)": [v4("192.168.80.1")] }), "10.0.0.7");
});

test("skips public, link-local and loopback addresses", () => {
  assert.equal(pickLanIp({ eth0: [v4("8.8.8.8"), v4("169.254.3.4"), v4("127.0.0.1", true)] }), "");
});

test("numeric family values (older Node) count as IPv4", () => {
  assert.equal(pickLanIp({ wlan0: [{ address: "192.168.0.9", family: 4, internal: false }] }), "192.168.0.9");
});
