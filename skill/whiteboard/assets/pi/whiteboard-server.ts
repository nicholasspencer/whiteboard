#!/usr/bin/env node
/**
 * Whiteboard capture server for Raspberry Pi (Node + TypeScript).
 *
 * Serves a fresh photo from the Pi camera over HTTP. The Pi advertises itself
 * on the local network via mDNS using a static Avahi service file that
 * install.sh drops in /etc/avahi/services/ — so this server needs no npm deps.
 *
 * Endpoints
 *   GET  /capture   image/jpeg          take a fresh photo and return it
 *   GET  /state     application/json     {version, changedAt, stable, ...} cheap change gate
 *   GET  /info      application/json     {label, hostname, model, camera, port, auth, webrtc, framing}
 *   GET  /config    application/json     current editable capture config (for the setup app)
 *   POST /config    application/json     patch capture config; persists to the overrides file
 *   GET  /framing   application/json     {framing, webrtc} current live-preview state
 *   POST /framing   application/json     {on:true|false} enter/leave framing mode
 *   GET  /health    application/json     {ok, camera}
 *
 * Framing mode: the camera is a single-owner resource, so the live WebRTC
 * preview (served by a separate MediaMTX process) and our rpicam captures can't
 * hold it at once. POST /framing {on:true} pauses the change-watcher and hands
 * the camera to MediaMTX (started via a scoped `sudo systemctl start mediamtx`);
 * {on:false} stops MediaMTX and resumes normal capture. A /capture taken while
 * framing briefly stops MediaMTX, shoots the still, and restarts it — so "take a
 * test shot" still returns the real photo the board reads will produce.
 *
 * The change watcher: a background loop grabs a tiny raw thumbnail every
 * watchIntervalMs and diffs it against the last *committed* board state. It bumps
 * `version` only once the scene has settled (no frame-to-frame motion) AND
 * differs from that committed state — i.e. "something changed and nobody's
 * standing in front of it." A consumer polls GET /state cheaply and only does an
 * expensive read (vision model) when `version` advances. A Coral TPU can later
 * replace this heuristic with a real person/stability detector behind the same
 * /state contract.
 *
 * Config (environment seeds the defaults; see whiteboard.conf.example. Every
 * capture knob below is also live-editable at runtime via POST /config, which
 * layers a JSON overrides file over these env defaults — no restart needed.)
 *   WHITEBOARD_PORT      default 8080 (bind-time only, not runtime-editable)
 *   WHITEBOARD_LABEL     default = hostname
 *   WHITEBOARD_TOKEN     optional shared secret; required on every request if set,
 *                        via the X-Whiteboard-Token header or ?token= query param
 *   WHITEBOARD_WIDTH     default 2304
 *   WHITEBOARD_HEIGHT    default 1296
 *   WHITEBOARD_TIMEOUT   camera warmup in ms (lets exposure/AWB settle), default 1200
 *   WHITEBOARD_EXTRA     extra args appended to the capture command, e.g.
 *                        "--autofocus-mode auto" for the Camera Module 3. With HDR
 *                        on, leave exposure (--shutter/--gain) out — the bracket
 *                        drives it; keep focus/awb/rotation here.
 *   WHITEBOARD_ROTATE    lossless post-capture rotation via jpegtran: 90/180/270
 *   WHITEBOARD_HDR       "auto" (default: HDR when enfuse is installed, else a
 *                        single shot), "on", or "off". HDR shoots an exposure
 *                        bracket and fuses it with enfuse so /capture survives big
 *                        lighting swings without recalibration.
 *   WHITEBOARD_HDR_BRACKET  bracket as shutterMicros:gain stops, default
 *                        "15000:1.0,150000:1.0,1000000:2.0"
 *   WHITEBOARD_WATCH_INTERVAL   change-watcher period in ms (0 disables), default 20000
 *   WHITEBOARD_WATCH_THRESHOLD  board-vs-committed mean diff to count as a change, default 0.035
 *   WHITEBOARD_WATCH_STABLE_EPS frame-to-frame mean diff below which the scene is "still", default 0.012
 *   WHITEBOARD_STATE_DIR   service-writable dir for the config overrides file, default /var/lib/whiteboard
 *   WHITEBOARD_WEBRTC_PORT default 8889 (MediaMTX WebRTC/WHEP port advertised in /info)
 *   WHITEBOARD_WEBRTC_PATH default "cam" (MediaMTX path name → WHEP at /<path>/whep)
 *   WHITEBOARD_MEDIAMTX_UNIT default "mediamtx" (systemd unit toggled for framing)
 *
 * Run with Node >= 23.6 (executes .ts directly): node whiteboard-server.ts
 */
import { createServer, IncomingMessage, ServerResponse } from "node:http";
import { execFile } from "node:child_process";
import { readFile, writeFile, mkdir, unlink } from "node:fs/promises";
import { existsSync, statSync, readFileSync } from "node:fs";
import { hostname, tmpdir } from "node:os";
import { join } from "node:path";
import { randomBytes, timingSafeEqual } from "node:crypto";

// --- Static, bind-time settings (not runtime-editable) ---------------------
const PORT = Number(process.env.WHITEBOARD_PORT ?? "8080");
const STATE_DIR = process.env.WHITEBOARD_STATE_DIR || "/var/lib/whiteboard";
const OVERRIDES_PATH = join(STATE_DIR, "overrides.json");
const WEBRTC_PORT = Number(process.env.WHITEBOARD_WEBRTC_PORT ?? "8889");
const WEBRTC_PATH = (process.env.WHITEBOARD_WEBRTC_PATH || "cam").replace(/^\/+|\/+$/g, "");
const MEDIAMTX_UNIT = process.env.WHITEBOARD_MEDIAMTX_UNIT || "mediamtx";
const HDR_TIMEOUT_MS = process.env.WHITEBOARD_HDR_TIMEOUT ?? "500"; // fixed exposure → minimal warmup
const ENFUSE_ARGS_DEFAULT = "--saturation-weight=0 --compression=90";
const EXPOSURE_FLAGS = new Set(["--shutter", "--gain", "--analoggain", "--exposure", "--ev"]);
const CAPTURE_BINARIES = ["rpicam-still", "libcamera-still"];

// --- Live, editable capture config -----------------------------------------
// Every field here is seeded from the environment but can be patched at runtime
// via POST /config (the setup app's framing screen). Changes apply on the next
// capture — no restart — and persist to OVERRIDES_PATH, layered over the env.
type Config = {
  label: string;
  token: string;
  width: number;
  height: number;
  timeoutMs: number;
  extra: string;
  rotate: string; // "" | "90" | "180" | "270" (jpegtran post-capture)
  hdr: string; // auto | on | off
  hdrBracket: string; // "shutterUs:gain,..."
  enfuseArgs: string;
  watchIntervalMs: number;
  watchWidth: number;
  watchHeight: number;
  watchThreshold: number;
  watchStableEps: number;
};

function num(v: string | undefined, fallback: number): number {
  const n = Number(v);
  return Number.isFinite(n) ? n : fallback;
}

function envConfig(): Config {
  return {
    label: process.env.WHITEBOARD_LABEL || hostname(),
    token: process.env.WHITEBOARD_TOKEN || "",
    width: num(process.env.WHITEBOARD_WIDTH, 2304),
    height: num(process.env.WHITEBOARD_HEIGHT, 1296),
    timeoutMs: num(process.env.WHITEBOARD_TIMEOUT, 1200),
    extra: (process.env.WHITEBOARD_EXTRA ?? "").trim(),
    rotate: (process.env.WHITEBOARD_ROTATE ?? "").trim(),
    hdr: (process.env.WHITEBOARD_HDR ?? "auto").trim().toLowerCase(),
    hdrBracket: (process.env.WHITEBOARD_HDR_BRACKET ?? "15000:1.0,150000:1.0,1000000:2.0").trim(),
    enfuseArgs: (process.env.WHITEBOARD_ENFUSE_ARGS ?? ENFUSE_ARGS_DEFAULT).trim(),
    watchIntervalMs: num(process.env.WHITEBOARD_WATCH_INTERVAL, 20000),
    watchWidth: num(process.env.WHITEBOARD_WATCH_WIDTH, 160),
    watchHeight: num(process.env.WHITEBOARD_WATCH_HEIGHT, 90),
    watchThreshold: num(process.env.WHITEBOARD_WATCH_THRESHOLD, 0.035),
    watchStableEps: num(process.env.WHITEBOARD_WATCH_STABLE_EPS, 0.012),
  };
}

let cfg: Config = envConfig();
let framing = false; // true while MediaMTX owns the camera for the live preview

// The editable view of the config (everything in Config — there are no secrets
// beyond the token, and the trusted-LAN posture already exposes /capture openly
// when no token is set, so the app can read+set the token to bootstrap auth).
function publicConfig(): Config {
  return { ...cfg };
}

// Validate + merge a patch into `cfg`. Returns any rejected fields; on a clean
// patch the new config is live immediately. Unknown keys are ignored (forward
// compatible with older rigs), not errored, except when they collide with a typo
// we can catch — we only hard-reject bad *values* for known keys.
function applyConfigPatch(patch: Record<string, unknown>): string[] {
  const errors: string[] = [];
  const next: Config = { ...cfg };
  const posInt = (k: string, v: unknown): number | undefined => {
    const n = Number(v);
    if (!Number.isFinite(n) || n <= 0) { errors.push(`${k} must be a positive number`); return undefined; }
    return Math.round(n);
  };
  const nonNegInt = (k: string, v: unknown): number | undefined => {
    const n = Number(v);
    if (!Number.isFinite(n) || n < 0) { errors.push(`${k} must be a non-negative number`); return undefined; }
    return Math.round(n);
  };
  const nonNeg = (k: string, v: unknown): number | undefined => {
    const n = Number(v);
    if (!Number.isFinite(n) || n < 0) { errors.push(`${k} must be a non-negative number`); return undefined; }
    return n;
  };
  for (const [k, v] of Object.entries(patch)) {
    switch (k) {
      case "label": next.label = String(v); break;
      case "token": next.token = String(v); break;
      case "extra": next.extra = String(v).trim(); break;
      case "hdrBracket": next.hdrBracket = String(v).trim(); break;
      case "enfuseArgs": next.enfuseArgs = String(v).trim(); break;
      case "rotate": {
        const s = String(v).trim();
        if (s !== "" && s !== "90" && s !== "180" && s !== "270") errors.push("rotate must be 90, 180, 270, or empty");
        else next.rotate = s;
        break;
      }
      case "hdr": {
        const s = String(v).trim().toLowerCase();
        if (s !== "auto" && s !== "on" && s !== "off") errors.push("hdr must be auto, on, or off");
        else next.hdr = s;
        break;
      }
      case "width": { const n = posInt(k, v); if (n !== undefined) next.width = n; break; }
      case "height": { const n = posInt(k, v); if (n !== undefined) next.height = n; break; }
      case "timeoutMs": { const n = posInt(k, v); if (n !== undefined) next.timeoutMs = n; break; }
      case "watchWidth": { const n = posInt(k, v); if (n !== undefined) next.watchWidth = n; break; }
      case "watchHeight": { const n = posInt(k, v); if (n !== undefined) next.watchHeight = n; break; }
      case "watchIntervalMs": { const n = nonNegInt(k, v); if (n !== undefined) next.watchIntervalMs = n; break; }
      case "watchThreshold": { const n = nonNeg(k, v); if (n !== undefined) next.watchThreshold = n; break; }
      case "watchStableEps": { const n = nonNeg(k, v); if (n !== undefined) next.watchStableEps = n; break; }
      default: /* ignore unknown keys */ break;
    }
  }
  if (errors.length === 0) cfg = next;
  return errors;
}

async function loadOverrides(): Promise<void> {
  try {
    const raw = await readFile(OVERRIDES_PATH, "utf8");
    const parsed = JSON.parse(raw) as Record<string, unknown>;
    const errs = applyConfigPatch(parsed);
    if (errs.length) console.error(`overrides.json had invalid fields (ignored): ${errs.join("; ")}`);
    else console.log(`loaded config overrides from ${OVERRIDES_PATH}`);
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code !== "ENOENT") {
      console.error(`could not read ${OVERRIDES_PATH}: ${(e as Error).message}`);
    }
  }
}

async function saveOverrides(): Promise<void> {
  await mkdir(STATE_DIR, { recursive: true }).catch(() => undefined);
  await writeFile(OVERRIDES_PATH, JSON.stringify(publicConfig(), null, 2) + "\n", { mode: 0o600 });
}

// --- Change watcher --------------------------------------------------------
// Cheap, dependency-free board-change detection. We grab a tiny raw RGB frame
// (no JPEG decode needed) and diff the bytes directly. Tune the two thresholds
// per room/lighting; /state exposes the live diff metrics so they can be tuned
// empirically. Set watchIntervalMs<=0 to disable sampling.
type WatchState = {
  version: number; // bumps once per settled board change; consumers poll this
  changedAt: string | null;
  stable: boolean; // scene is currently still (no frame-to-frame motion)
  watching: boolean;
  lastSampleAt: string | null;
  lastDiff: number | null; // current thumbnail vs committed board (0..1)
  lastMotion: number | null; // current thumbnail vs previous thumbnail (0..1)
  error: string | null;
};
const watch: WatchState = {
  version: 0, changedAt: null, stable: false, watching: false,
  lastSampleAt: null, lastDiff: null, lastMotion: null, error: null,
};
let committedThumb: Buffer | null = null; // last committed board state
let previousThumb: Buffer | null = null; // previous sample, for motion detection

function whichBin(name: string): string | null {
  const dirs = (process.env.PATH ?? "").split(":").filter(Boolean);
  for (const dir of dirs) {
    const p = join(dir, name);
    try {
      if (existsSync(p) && statSync(p).isFile()) return p;
    } catch { /* ignore */ }
  }
  return null;
}

function whichCaptureBinary(): string | null {
  for (const bin of CAPTURE_BINARIES) {
    const p = whichBin(bin);
    if (p) return p;
  }
  return null;
}

type Exposure = { shutterUs: number; gain: number };

// Parse the HDR bracket ("shutterUs:gain,...") into exposure stops.
function parseBracket(): Exposure[] {
  const out: Exposure[] = [];
  for (const part of cfg.hdrBracket.split(",")) {
    const [s, g] = part.split(":");
    const shutterUs = Number(s);
    const gain = g === undefined ? 1 : Number(g);
    if (Number.isFinite(shutterUs) && shutterUs > 0 && Number.isFinite(gain) && gain > 0) {
      out.push({ shutterUs, gain });
    }
  }
  return out;
}

// EXTRA minus any exposure-controlling flags, so the HDR bracket can drive its
// own per-frame shutter/gain even if a stale --shutter/--gain lingers in config.
function extraWithoutExposure(): string[] {
  const toks = cfg.extra ? cfg.extra.split(/\s+/) : [];
  const out: string[] = [];
  for (let i = 0; i < toks.length; i++) {
    const flag = toks[i].split("=")[0];
    if (EXPOSURE_FLAGS.has(flag)) {
      if (!toks[i].includes("=")) i++; // also skip the separate value token
      continue;
    }
    out.push(toks[i]);
  }
  return out;
}

function piModel(): string {
  try {
    const raw = readFileSync("/proc/device-tree/model", "utf8");
    return raw.replace(/\0/g, "").trim() || "unknown";
  } catch {
    return "unknown";
  }
}

const delay = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

// The camera is a single exclusive resource — serialize captures.
let captureChain: Promise<unknown> = Promise.resolve();
function withCameraLock<T>(fn: () => Promise<T>): Promise<T> {
  const run = captureChain.then(fn, fn);
  captureChain = run.then(() => undefined, () => undefined);
  return run;
}

// Low-level single rpicam-still capture to a JPEG file. `exposure` (when given)
// appends fixed --shutter/--gain for an HDR bracket frame.
function runRpicam(outPath: string, timeoutMs: string, extra: string[], exposure?: Exposure): Promise<void> {
  const binary = whichCaptureBinary();
  if (!binary) {
    return Promise.reject(new Error(`no camera capture binary found (looked for: ${CAPTURE_BINARIES.join(", ")})`));
  }
  const args = [
    "--output", outPath,
    "--timeout", timeoutMs,
    "--nopreview",
    "--encoding", "jpg",
    "--width", String(cfg.width),
    "--height", String(cfg.height),
    ...extra,
    ...(exposure ? ["--shutter", String(exposure.shutterUs), "--gain", String(exposure.gain)] : []),
  ];
  return new Promise<void>((resolve, reject) => {
    execFile(binary, args, { timeout: 30000 }, (err, _stdout, stderr) => {
      if (err) reject(new Error(`${binary} failed: ${String(stderr || err.message).slice(0, 800)}`));
      else resolve();
    });
  });
}

// Lossless 90/180/270 rotation via jpegtran. Returns the rotated path, or the
// source unchanged if rotation is off or jpegtran is missing (serve unrotated
// rather than fail). Any temp file it creates is pushed onto `scratch` to clean.
async function rotateInPlace(srcPath: string, scratch: string[]): Promise<string> {
  const rotate = cfg.rotate;
  if (rotate !== "90" && rotate !== "180" && rotate !== "270") return srcPath;
  const jt = whichBin("jpegtran");
  if (!jt) { console.error(`rotate ${rotate} skipped: jpegtran not found`); return srcPath; }
  const rotated = srcPath + ".rot.jpg";
  scratch.push(rotated);
  try {
    await new Promise<void>((resolve, reject) => {
      execFile(jt, ["-rotate", rotate, "-copy", "none", "-outfile", rotated, srcPath],
        { timeout: 15000 }, (err) => (err ? reject(err) : resolve()));
    });
    return rotated;
  } catch (e) {
    console.error(`rotate ${rotate} via jpegtran failed: ${(e as Error).message}`);
    return srcPath;
  }
}

// Core capture (no camera lock). With HDR enabled and enfuse present, shoots an
// exposure bracket and fuses it into one well-exposed frame; otherwise a single
// shot. Then rotates and returns the JPEG bytes. Callers hold the camera lock.
async function captureJpegCore(): Promise<Buffer> {
  const bracket = parseBracket();
  const enfuseBin = whichBin("enfuse");
  const useHdr = cfg.hdr !== "off" && bracket.length >= 2 && enfuseBin !== null;
  if (cfg.hdr === "on" && !enfuseBin) {
    console.error("WHITEBOARD_HDR=on but enfuse not found — falling back to a single capture");
  }
  const scratch: string[] = [];
  try {
    let basePath: string;
    if (useHdr) {
      const extra = extraWithoutExposure();
      const frames: string[] = [];
      for (let i = 0; i < bracket.length; i++) {
        const p = join(tmpdir(), `wb-hdr-${randomBytes(6).toString("hex")}-${i}.jpg`);
        scratch.push(p);
        await runRpicam(p, String(HDR_TIMEOUT_MS), extra, bracket[i]);
        frames.push(p);
      }
      const fused = join(tmpdir(), `wb-fused-${randomBytes(6).toString("hex")}.jpg`);
      scratch.push(fused);
      await new Promise<void>((resolve, reject) => {
        execFile(enfuseBin!, [...cfg.enfuseArgs.split(/\s+/).filter(Boolean), "-o", fused, ...frames],
          { timeout: 60000 }, (err, _stdout, stderr) =>
            (err ? reject(new Error(`enfuse failed: ${String(stderr || err.message).slice(0, 400)}`)) : resolve()));
      });
      basePath = fused;
    } else {
      const p = join(tmpdir(), `wb-${randomBytes(6).toString("hex")}.jpg`);
      scratch.push(p);
      await runRpicam(p, String(cfg.timeoutMs), cfg.extra ? cfg.extra.split(/\s+/) : []);
      basePath = p;
    }
    const outPath = await rotateInPlace(basePath, scratch);
    const data = await readFile(outPath);
    if (data.length === 0) throw new Error("capture produced an empty image");
    return data;
  } finally {
    for (const f of scratch) unlink(f).catch(() => undefined);
  }
}

function captureJpeg(): Promise<Buffer> {
  return withCameraLock(captureJpegCore);
}

// A /capture taken while framing: MediaMTX owns the camera, so briefly stop it,
// shoot the real still, then restart it. The whole dance runs under the camera
// lock so nothing else grabs the device mid-swap. The live preview blips and the
// app's WHEP stream reconnects — acceptable for a deliberate "take test shot".
function captureWhileFraming(): Promise<Buffer> {
  return withCameraLock(async () => {
    try {
      await sudoSystemctl("stop");
    } catch (e) {
      console.error(`framing test-shot: could not stop ${MEDIAMTX_UNIT}: ${(e as Error).message}`);
    }
    await delay(400); // let libcamera fully release before rpicam opens it
    try {
      return await captureJpegCore();
    } finally {
      sudoSystemctl("start").catch((e) =>
        console.error(`framing test-shot: could not restart ${MEDIAMTX_UNIT}: ${(e as Error).message}`));
    }
  });
}

// A small raw RGB frame for change detection. `--encoding rgb` writes packed
// bytes with no header, so length == width*height*3 and we can diff directly.
// Reuses EXTRA (exposure/focus/rotation) so the thumbnail reflects the same
// lighting the real capture sees. Shares the camera lock with /capture.
function captureThumbnailRaw(): Promise<Buffer> {
  return withCameraLock(async () => {
    const binary = whichCaptureBinary();
    if (!binary) throw new Error("no camera capture binary");
    const path = join(tmpdir(), `wb-thumb-${randomBytes(6).toString("hex")}.rgb`);
    const args = [
      "--output", path,
      "--timeout", String(cfg.timeoutMs),
      "--nopreview",
      "--encoding", "rgb",
      "--width", String(cfg.watchWidth),
      "--height", String(cfg.watchHeight),
      ...(cfg.extra ? cfg.extra.split(/\s+/) : []),
    ];
    try {
      await new Promise<void>((resolve, reject) => {
        execFile(binary, args, { timeout: 30000 }, (err, _stdout, stderr) => {
          if (err) reject(new Error(`${binary} (thumb) failed: ${String(stderr || err.message).slice(0, 400)}`));
          else resolve();
        });
      });
      const data = await readFile(path);
      if (data.length === 0) throw new Error("thumbnail capture produced no bytes");
      return data;
    } finally {
      unlink(path).catch(() => undefined);
    }
  });
}

// Mean absolute per-byte difference, normalised to 0..1. Mismatched lengths
// (a resolution change mid-run) read as "completely different".
function meanAbsDiff(a: Buffer, b: Buffer): number {
  if (a.length !== b.length || a.length === 0) return 1;
  let sum = 0;
  for (let i = 0; i < a.length; i++) sum += Math.abs(a[i] - b[i]);
  return sum / (a.length * 255);
}

// One watcher tick: grab a thumbnail, update motion/diff metrics, and commit a
// new board version when the scene has settled into a state that differs from
// the last committed one. While someone is writing (or walking past) frames
// keep changing, so `motion` stays high and we hold off — that stability gate
// is the cheap stand-in for person detection until the Coral TPU lands.
async function sampleOnce(): Promise<void> {
  const current = await captureThumbnailRaw();
  const now = new Date().toISOString();
  watch.lastSampleAt = now;
  watch.error = null;

  if (!committedThumb) {
    committedThumb = current;
    previousThumb = current;
    watch.version = 1;
    watch.changedAt = now;
    watch.stable = true;
    watch.lastDiff = 0;
    watch.lastMotion = 0;
    return;
  }

  const motion = meanAbsDiff(current, previousThumb ?? current);
  const refDiff = meanAbsDiff(current, committedThumb);
  previousThumb = current;
  watch.lastMotion = motion;
  watch.lastDiff = refDiff;

  const still = motion <= cfg.watchStableEps;
  watch.stable = still;
  if (still && refDiff > cfg.watchThreshold) {
    committedThumb = current;
    watch.version += 1;
    watch.changedAt = now;
  }
}

// A single self-rescheduling loop. It reads the interval live each tick (so
// POST /config can change it) and skips sampling while framing (MediaMTX owns
// the camera). When disabled it idles, polling for a re-enable.
function startWatcher(): void {
  const tick = () => {
    const interval = cfg.watchIntervalMs;
    const enabled = Number.isFinite(interval) && interval > 0;
    watch.watching = enabled;
    const after = (next: number) => setTimeout(tick, next);
    if (!enabled) { after(5000); return; }
    if (framing) { after(Math.max(interval, 2000)); return; }
    sampleOnce()
      .catch((e) => { watch.error = (e as Error).message; })
      .finally(() => after(interval));
  };
  setTimeout(tick, 1500); // let the HTTP server bind first
  console.log(
    `watcher: every ${cfg.watchIntervalMs}ms @ ${cfg.watchWidth}x${cfg.watchHeight}, ` +
    `threshold=${cfg.watchThreshold}, stableEps=${cfg.watchStableEps} (0 = disabled, live-editable)`,
  );
}

// --- Framing mode (MediaMTX live preview) ----------------------------------
function hasMediamtx(): boolean {
  return whichBin("mediamtx") !== null;
}

// Toggle the MediaMTX systemd unit. Runs as the (non-root) service user, so it
// relies on a scoped NOPASSWD sudoers drop-in that install.sh writes for exactly
// `systemctl start|stop|restart <unit>`. `-n` makes a missing rule fail fast
// rather than hang waiting for a password.
function sudoSystemctl(action: "start" | "stop" | "restart"): Promise<void> {
  return new Promise<void>((resolve, reject) => {
    execFile("sudo", ["-n", "systemctl", action, MEDIAMTX_UNIT], { timeout: 20000 }, (err, _stdout, stderr) => {
      if (err) reject(new Error(`systemctl ${action} ${MEDIAMTX_UNIT} failed: ${String(stderr || err.message).slice(0, 300)}`));
      else resolve();
    });
  });
}

async function startFraming(): Promise<void> {
  if (!hasMediamtx()) throw new Error("MediaMTX is not installed on this rig — reinstall to enable the live preview");
  await withCameraLock(async () => {
    if (framing) return;
    // `restart` (not `start`) so a stale instance from a crashed session is
    // replaced cleanly and grabs the camera fresh.
    await sudoSystemctl("restart");
    framing = true;
  });
  console.log("framing: ON — MediaMTX owns the camera, watcher paused");
}

async function stopFraming(): Promise<void> {
  await withCameraLock(async () => {
    if (!framing) return;
    try { await sudoSystemctl("stop"); } catch (e) { console.error((e as Error).message); }
    framing = false;
  });
  console.log("framing: OFF — camera returned to capture service");
}

function webrtcInfo() {
  return {
    enabled: hasMediamtx(),
    port: WEBRTC_PORT,
    whepPath: `/${WEBRTC_PATH}/whep`,
    framing,
  };
}

// --- HTTP ------------------------------------------------------------------
function tokenOk(req: IncomingMessage, query: URLSearchParams): boolean {
  if (!cfg.token) return true;
  const provided = req.headers["x-whiteboard-token"];
  const headerVal = Array.isArray(provided) ? provided[0] : provided ?? "";
  const candidate = headerVal || query.get("token") || "";
  // constant-time compare on equal-length buffers
  const a = Buffer.from(candidate);
  const b = Buffer.from(cfg.token);
  return a.length === b.length && timingSafeEqual(a, b);
}

function sendJson(res: ServerResponse, code: number, payload: unknown): void {
  const body = Buffer.from(JSON.stringify(payload));
  res.writeHead(code, {
    "Content-Type": "application/json",
    "Content-Length": body.length,
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "X-Whiteboard-Token, Content-Type",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  });
  res.end(body);
}

function readBody(req: IncomingMessage, limit = 64 * 1024): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let size = 0;
    req.on("data", (c: Buffer) => {
      size += c.length;
      if (size > limit) { reject(new Error("request body too large")); req.destroy(); return; }
      chunks.push(c);
    });
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

async function readJson(req: IncomingMessage): Promise<Record<string, unknown>> {
  const body = await readBody(req);
  if (body.length === 0) return {};
  const parsed = JSON.parse(body.toString("utf8"));
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error("body must be a JSON object");
  }
  return parsed as Record<string, unknown>;
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url ?? "/", `http://localhost:${PORT}`);
  const query = url.searchParams;
  const method = req.method ?? "GET";

  if (method === "OPTIONS") {
    res.writeHead(204, {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Headers": "X-Whiteboard-Token, Content-Type",
      "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    });
    res.end();
    return;
  }

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
      label: cfg.label,
      hostname: hostname(),
      model: piModel(),
      camera: whichCaptureBinary(),
      port: PORT,
      auth: cfg.token ? "token" : "none",
      hdr: cfg.hdr === "off"
        ? "off"
        : whichBin("enfuse")
          ? `on (${parseBracket().length}-frame bracket)`
          : "auto → single capture (enfuse not installed)",
      framing,
      webrtc: webrtcInfo(),
    });
    return;
  }

  if (url.pathname === "/state") {
    sendJson(res, 200, {
      label: cfg.label,
      version: watch.version,
      changedAt: watch.changedAt,
      stable: watch.stable,
      watching: watch.watching,
      lastSampleAt: watch.lastSampleAt,
      lastDiff: watch.lastDiff,
      lastMotion: watch.lastMotion,
      error: watch.error,
    });
    return;
  }

  if (url.pathname === "/config") {
    if (method === "GET") {
      sendJson(res, 200, { config: publicConfig(), webrtc: webrtcInfo() });
      return;
    }
    if (method === "POST") {
      try {
        const patch = await readJson(req);
        const errors = applyConfigPatch(patch);
        if (errors.length) { sendJson(res, 400, { error: "invalid config", details: errors }); return; }
        await saveOverrides().catch((e) =>
          console.error(`config applied in memory but not persisted: ${(e as Error).message}`));
        console.log(`config updated: ${Object.keys(patch).join(", ") || "(no changes)"}`);
        sendJson(res, 200, { config: publicConfig(), webrtc: webrtcInfo() });
      } catch (e) {
        sendJson(res, 400, { error: (e as Error).message });
      }
      return;
    }
    sendJson(res, 405, { error: "method not allowed" });
    return;
  }

  if (url.pathname === "/framing") {
    if (method === "GET") {
      sendJson(res, 200, { framing, webrtc: webrtcInfo() });
      return;
    }
    if (method === "POST") {
      try {
        const body = await readJson(req);
        const on = body.on === true || body.on === "true" || body.on === 1;
        if (on) await startFraming();
        else await stopFraming();
        sendJson(res, 200, { framing, webrtc: webrtcInfo() });
      } catch (e) {
        sendJson(res, 500, { error: (e as Error).message, framing, webrtc: webrtcInfo() });
      }
      return;
    }
    sendJson(res, 405, { error: "method not allowed" });
    return;
  }

  if (url.pathname === "/capture") {
    try {
      const image = framing ? await captureWhileFraming() : await captureJpeg();
      res.writeHead(200, {
        "Content-Type": "image/jpeg",
        "Content-Length": image.length,
        "Cache-Control": "no-store",
        "Access-Control-Allow-Origin": "*",
        "X-Whiteboard-Label": cfg.label,
      });
      res.end(image);
    } catch (err) {
      sendJson(res, 500, { error: (err as Error).message });
    }
    return;
  }

  sendJson(res, 404, {
    error: "not found",
    paths: ["/capture", "/state", "/info", "/config", "/framing", "/health"],
  });
});

async function main(): Promise<void> {
  await loadOverrides();
  server.listen(PORT, "0.0.0.0", () => {
    console.log(
      `whiteboard server listening on :${PORT} ` +
      `(label=${JSON.stringify(cfg.label)}, camera=${whichCaptureBinary()}, ` +
      `auth=${cfg.token ? "token" : "none"}, webrtc=${hasMediamtx() ? `:${WEBRTC_PORT}/${WEBRTC_PATH}/whep` : "off"})`,
    );
    startWatcher();
  });
}

main();
