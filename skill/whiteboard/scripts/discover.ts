#!/usr/bin/env node
/**
 * Discover whiteboard capture servers on the local network via mDNS.
 *
 * Prints a JSON array to stdout:
 *   [{ label, instance, host, address, port, path, auth, model, url }]
 *
 * Usage:
 *   node discover.ts [--timeout 3000] [--name LABEL] [--json]
 *
 * Backend: shells out to the OS mDNS browser (zero npm dependencies).
 *   - macOS: `dns-sd -Z`   (always present)
 *   - Linux: `avahi-browse -rtp`  (install `avahi-utils` if missing)
 *
 * Requires Node >= 23.6 (runs .ts directly), or run with `bun` / `npx tsx`.
 */
import { spawn } from "node:child_process";

interface Entry {
  label: string;
  instance: string;
  host?: string;
  address?: string;
  port?: number;
  path: string;
  auth: string;
  model?: string;
  url?: string;
}

const SERVICE = "_whiteboard._tcp";

function parseArgs(argv: string[]) {
  const out: { timeout: number; name?: string } = { timeout: 3000 };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--timeout") out.timeout = Number(argv[++i]);
    else if (argv[i] === "--name") out.name = argv[++i];
    else if (argv[i] === "--json") {/* default output is JSON */}
  }
  return out;
}

/** Decode DNS presentation-format escapes: \DDD (decimal) and \<char>. */
function decodeDnsName(s: string): string {
  let out = "";
  for (let i = 0; i < s.length; i++) {
    if (s[i] === "\\" && i + 1 < s.length) {
      const d = s.slice(i + 1, i + 4);
      if (/^\d{3}$/.test(d)) { out += String.fromCharCode(parseInt(d, 10)); i += 3; }
      else { out += s[i + 1]; i += 1; }
    } else {
      out += s[i];
    }
  }
  return out;
}

/** Parse a run of space-separated double-quoted TXT tokens into a k/v map. */
function parseQuotedTxt(s: string): Record<string, string> {
  const txt: Record<string, string> = {};
  const re = /"((?:[^"\\]|\\.)*)"/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(s)) !== null) {
    const kv = m[1];
    const eq = kv.indexOf("=");
    if (eq > 0) txt[kv.slice(0, eq)] = kv.slice(eq + 1);
  }
  return txt;
}

function labelFromInstance(instance: string): string {
  const decoded = decodeDnsName(instance);
  const idx = decoded.indexOf(`.${SERVICE}`);
  return idx > 0 ? decoded.slice(0, idx) : decoded;
}

function finalize(byInstance: Map<string, Partial<Entry>>): Entry[] {
  const entries: Entry[] = [];
  for (const [instance, p] of byInstance) {
    const path = p.path || "/capture";
    const host = p.host;
    const target = p.address || host;
    entries.push({
      label: p.label || labelFromInstance(instance),
      instance,
      host,
      address: p.address,
      port: p.port,
      path,
      auth: p.auth || "none",
      model: p.model,
      url: target && p.port ? `http://${target}:${p.port}${path}` : undefined,
    });
  }
  return entries.sort((a, b) => a.label.toLowerCase().localeCompare(b.label.toLowerCase()));
}

/** Run a streaming browser command for `timeout` ms, return its stdout. */
function runFor(cmd: string, args: string[], timeout: number): Promise<string> {
  return new Promise((resolve) => {
    let out = "";
    const child = spawn(cmd, args, { stdio: ["ignore", "pipe", "ignore"] });
    child.stdout.on("data", (d) => (out += d.toString()));
    const timer = setTimeout(() => child.kill("SIGTERM"), timeout);
    child.on("error", () => { clearTimeout(timer); resolve(out); });
    child.on("close", () => { clearTimeout(timer); resolve(out); });
  });
}

async function discoverMacOS(timeout: number): Promise<Entry[]> {
  const out = await runFor("dns-sd", ["-Z", SERVICE, "local"], timeout);
  const byInstance = new Map<string, Partial<Entry>>();
  const get = (name: string) => {
    const inst = name.replace(/\.local\.?$/, "");
    if (!byInstance.has(inst)) byInstance.set(inst, {});
    return byInstance.get(inst)!;
  };
  for (const line of out.split("\n")) {
    // <instance>\tSRV\t<prio> <weight> <port> <target>. ;...
    const srv = line.match(/^(\S+)\s+SRV\s+\d+\s+\d+\s+(\d+)\s+(\S+?)\.?\s*(?:;.*)?$/);
    if (srv && srv[1].includes(SERVICE)) {
      const e = get(srv[1]);
      e.port = Number(srv[2]);
      e.host = decodeDnsName(srv[3]);
      continue;
    }
    const txt = line.match(/^(\S+)\s+TXT\s+(.*)$/);
    if (txt && txt[1].includes(SERVICE)) {
      const e = get(txt[1]);
      const kv = parseQuotedTxt(txt[2]);
      if (kv.label) e.label = kv.label;
      if (kv.path) e.path = kv.path;
      if (kv.auth) e.auth = kv.auth;
      if (kv.model) e.model = kv.model;
    }
  }
  return finalize(byInstance);
}

async function discoverLinux(timeout: number): Promise<Entry[]> {
  // avahi-browse -rtp terminates on its own (-t), but cap it anyway.
  const out = await runFor("avahi-browse", ["-rtp", SERVICE], timeout);
  const byInstance = new Map<string, Partial<Entry>>();
  for (const line of out.split("\n")) {
    if (!line.startsWith("=")) continue; // resolved records only
    const f = line.split(";");
    // =;iface;proto;name;type;domain;host;address;port;txt...
    if (f.length < 9) continue;
    const instance = `${decodeDnsName(f[3])}.${SERVICE}`;
    const e: Partial<Entry> = byInstance.get(instance) || {};
    e.host = f[6].replace(/\.$/, "");
    e.address = f[7] || undefined;
    e.port = Number(f[8]);
    const kv = parseQuotedTxt(f.slice(9).join(";"));
    if (kv.label) e.label = kv.label;
    if (kv.path) e.path = kv.path;
    if (kv.auth) e.auth = kv.auth;
    if (kv.model) e.model = kv.model;
    byInstance.set(instance, e);
  }
  return finalize(byInstance);
}

async function which(cmd: string): Promise<boolean> {
  return new Promise((resolve) => {
    const c = spawn(process.platform === "win32" ? "where" : "which", [cmd], { stdio: "ignore" });
    c.on("error", () => resolve(false));
    c.on("close", (code) => resolve(code === 0));
  });
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  let entries: Entry[];

  if (await which("dns-sd")) entries = await discoverMacOS(args.timeout);
  else if (await which("avahi-browse")) entries = await discoverLinux(args.timeout);
  else {
    process.stderr.write(
      "No mDNS browser found. Install one:\n" +
      "  macOS:  dns-sd ships with the OS (should already be present)\n" +
      "  Linux:  sudo apt-get install avahi-utils\n",
    );
    process.exit(3);
  }

  if (args.name) {
    const needle = args.name.toLowerCase();
    entries = entries.filter((e) => e.label.toLowerCase().includes(needle));
  }
  process.stdout.write(JSON.stringify(entries, null, 2) + "\n");
}

main();
