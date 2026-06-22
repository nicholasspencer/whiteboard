#!/usr/bin/env node
/**
 * Download a fresh photo from a whiteboard server and save it locally.
 *
 * HTTP is done via `curl` (a system tool, like discover.ts uses `dns-sd`) rather
 * than Node's fetch/http. Reason: on real-world Macs/LANs — VPNs (Tailscale/utun),
 * cloned/reject routes, and mDNS `.local` names — Node's undici and node:http
 * intermittently fail with EHOSTUNREACH or can't resolve `.local`, while `curl`
 * uses the OS resolver and the kernel's working route and just works.
 *
 * Run discover.ts first to get a host/url, then call this.
 *
 * Usage:
 *   node capture.ts --url http://host.local:8080/capture [--output PATH] [--token TOK]
 *   node capture.ts --host 192.168.1.42 [--port 8080] [--token TOK] [--output PATH]
 *
 * Prints the saved file path to stdout on success.
 *
 * Requires Node >= 23.6 (runs .ts directly), or run with `bun` / `npx tsx`.
 */
import { spawnSync } from "node:child_process";
import { statSync } from "node:fs";

function parseArgs(argv: string[]) {
  const a: Record<string, string> = {};
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    if (k.startsWith("--")) a[k.slice(2)] = argv[++i];
  }
  return a;
}

function fail(msg: string): never {
  process.stderr.write(`error: ${msg}\n`);
  process.exit(1);
}

async function main() {
  const a = parseArgs(process.argv.slice(2));
  const port = a.port ? Number(a.port) : 8080;
  const path = a.path ?? "/capture";
  const url = a.url ?? (a.host ? `http://${a.host}:${port}${path.startsWith("/") ? path : "/" + path}` : undefined);
  if (!url) fail("provide --url or --host");

  const output = a.output ?? `/tmp/whiteboard-${Date.now()}.jpg`;
  const timeoutSec = a.timeout ? Number(a.timeout) : 45;

  const args = ["-fsS", "--max-time", String(timeoutSec), "-o", output];
  if (a.token) args.push("-H", `X-Whiteboard-Token: ${a.token}`);
  args.push(url!);

  const res = spawnSync("curl", args, { encoding: "utf8" });
  if (res.error) {
    if ((res.error as NodeJS.ErrnoException).code === "ENOENT") fail("curl not found on PATH");
    fail((res.error as Error).message);
  }
  if (res.status !== 0) {
    fail(`could not fetch ${url}: ${(res.stderr || "").trim() || `curl exit ${res.status}`}`);
  }

  let size = 0;
  try { size = statSync(output).size; } catch { fail("capture produced no file"); }
  if (size === 0) fail("server returned an empty image");

  process.stdout.write(output + "\n");
}

main();
