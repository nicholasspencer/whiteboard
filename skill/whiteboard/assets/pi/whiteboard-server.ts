#!/usr/bin/env node
/**
 * Whiteboard capture server for Raspberry Pi (Node + TypeScript).
 *
 * Serves a fresh photo from the Pi camera over HTTP. The Pi advertises itself
 * on the local network via mDNS using a static Avahi service file that
 * install.sh drops in /etc/avahi/services/ — so this server needs no npm deps.
 *
 * Endpoints
 *   GET /capture   image/jpeg          take a fresh photo and return it
 *   GET /info      application/json     {label, hostname, model, camera, port, auth}
 *   GET /health    application/json     {ok, camera}
 *
 * Config (environment variables; see whiteboard.conf.example)
 *   WHITEBOARD_PORT      default 8080
 *   WHITEBOARD_LABEL     default = hostname
 *   WHITEBOARD_TOKEN     optional shared secret; required on every request if set,
 *                        via the X-Whiteboard-Token header or ?token= query param
 *   WHITEBOARD_WIDTH     default 2304
 *   WHITEBOARD_HEIGHT    default 1296
 *   WHITEBOARD_TIMEOUT   camera warmup in ms (lets exposure/AWB settle), default 1200
 *   WHITEBOARD_EXTRA     extra args appended to the capture command, e.g.
 *                        "--autofocus-mode auto" for the Camera Module 3
 *
 * Run with Node >= 23.6 (executes .ts directly): node whiteboard-server.ts
 */
import { createServer, IncomingMessage, ServerResponse } from "node:http";
import { execFile } from "node:child_process";
import { readFile, unlink } from "node:fs/promises";
import { existsSync, statSync, readFileSync } from "node:fs";
import { hostname, tmpdir } from "node:os";
import { join } from "node:path";
import { randomBytes, timingSafeEqual } from "node:crypto";

const PORT = Number(process.env.WHITEBOARD_PORT ?? "8080");
const LABEL = process.env.WHITEBOARD_LABEL || hostname();
const TOKEN = process.env.WHITEBOARD_TOKEN || "";
const WIDTH = process.env.WHITEBOARD_WIDTH ?? "2304";
const HEIGHT = process.env.WHITEBOARD_HEIGHT ?? "1296";
const TIMEOUT_MS = process.env.WHITEBOARD_TIMEOUT ?? "1200";
const EXTRA = (process.env.WHITEBOARD_EXTRA ?? "").trim();
// Optional lossless rotation applied after capture via jpegtran (90/180/270).
// rpicam-still can only flip 0/180, so 90/270 (e.g. a sideways-mounted camera)
// is corrected here instead. Requires the `jpegtran` binary (libjpeg-turbo-progs).
const ROTATE = (process.env.WHITEBOARD_ROTATE ?? "").trim();

const CAPTURE_BINARIES = ["rpicam-still", "libcamera-still"];

function whichCaptureBinary(): string | null {
  const dirs = (process.env.PATH ?? "").split(":").filter(Boolean);
  for (const bin of CAPTURE_BINARIES) {
    for (const dir of dirs) {
      const p = join(dir, bin);
      try {
        if (existsSync(p) && statSync(p).isFile()) return p;
      } catch { /* ignore */ }
    }
  }
  return null;
}

function piModel(): string {
  try {
    const raw = readFileSync("/proc/device-tree/model", "utf8");
    return raw.replace(/\0/g, "").trim() || "unknown";
  } catch {
    return "unknown";
  }
}

// The camera is a single exclusive resource — serialize captures.
let captureChain: Promise<unknown> = Promise.resolve();
function withCameraLock<T>(fn: () => Promise<T>): Promise<T> {
  const run = captureChain.then(fn, fn);
  captureChain = run.then(() => undefined, () => undefined);
  return run;
}

function captureJpeg(): Promise<Buffer> {
  return withCameraLock(async () => {
    const binary = whichCaptureBinary();
    if (!binary) {
      throw new Error(`no camera capture binary found (looked for: ${CAPTURE_BINARIES.join(", ")})`);
    }
    const path = join(tmpdir(), `whiteboard-${randomBytes(6).toString("hex")}.jpg`);
    const args = [
      "--output", path,
      "--timeout", String(TIMEOUT_MS),
      "--nopreview",
      "--encoding", "jpg",
      "--width", String(WIDTH),
      "--height", String(HEIGHT),
      ...(EXTRA ? EXTRA.split(/\s+/) : []),
    ];
    const rotated = path + ".rot.jpg";
    try {
      await new Promise<void>((resolve, reject) => {
        execFile(binary, args, { timeout: 30000 }, (err, _stdout, stderr) => {
          if (err) reject(new Error(`${binary} failed: ${String(stderr || err.message).slice(0, 800)}`));
          else resolve();
        });
      });
      let outPath = path;
      if (ROTATE === "90" || ROTATE === "180" || ROTATE === "270") {
        try {
          await new Promise<void>((resolve, reject) => {
            execFile("jpegtran", ["-rotate", ROTATE, "-copy", "none", "-outfile", rotated, path],
              { timeout: 15000 }, (err) => (err ? reject(err) : resolve()));
          });
          outPath = rotated;
        } catch (e) {
          // jpegtran missing or failed — serve the unrotated image rather than error out
          console.error(`rotate ${ROTATE} via jpegtran failed: ${(e as Error).message}`);
        }
      }
      const data = await readFile(outPath);
      if (data.length === 0) throw new Error(`${binary} produced an empty image`);
      return data;
    } finally {
      unlink(path).catch(() => undefined);
      unlink(rotated).catch(() => undefined);
    }
  });
}

function tokenOk(req: IncomingMessage, query: URLSearchParams): boolean {
  if (!TOKEN) return true;
  const provided = req.headers["x-whiteboard-token"];
  const headerVal = Array.isArray(provided) ? provided[0] : provided ?? "";
  const candidate = headerVal || query.get("token") || "";
  // constant-time compare on equal-length buffers
  const a = Buffer.from(candidate);
  const b = Buffer.from(TOKEN);
  return a.length === b.length && timingSafeEqual(a, b);
}

function sendJson(res: ServerResponse, code: number, payload: unknown): void {
  const body = Buffer.from(JSON.stringify(payload));
  res.writeHead(code, { "Content-Type": "application/json", "Content-Length": body.length });
  res.end(body);
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url ?? "/", `http://localhost:${PORT}`);
  const query = url.searchParams;

  if (!tokenOk(req, query)) {
    sendJson(res, 401, { error: "missing or invalid token" });
    return;
  }

  if (url.pathname === "/health" || url.pathname === "/healthz") {
    sendJson(res, 200, { ok: true, camera: whichCaptureBinary() });
    return;
  }

  if (url.pathname === "/info") {
    sendJson(res, 200, {
      label: LABEL,
      hostname: hostname(),
      model: piModel(),
      camera: whichCaptureBinary(),
      port: PORT,
      auth: TOKEN ? "token" : "none",
    });
    return;
  }

  if (url.pathname === "/capture") {
    try {
      const image = await captureJpeg();
      res.writeHead(200, {
        "Content-Type": "image/jpeg",
        "Content-Length": image.length,
        "Cache-Control": "no-store",
        "X-Whiteboard-Label": LABEL,
      });
      res.end(image);
    } catch (err) {
      sendJson(res, 500, { error: (err as Error).message });
    }
    return;
  }

  sendJson(res, 404, { error: "not found", paths: ["/capture", "/info", "/health"] });
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(
    `whiteboard server listening on :${PORT} ` +
    `(label=${JSON.stringify(LABEL)}, camera=${whichCaptureBinary()}, auth=${TOKEN ? "token" : "none"})`,
  );
});
