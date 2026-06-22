#!/usr/bin/env node
/**
 * OPTIONAL: analyze a whiteboard image with the Claude API (headless use).
 *
 * Inside Claude Code you usually DON'T need this — the running model is already
 * vision-capable, so just Read the captured image. Use this for headless
 * automation (cron, CI, a standalone pipeline) where no agent is in the loop.
 *
 * Usage:
 *   node process.ts IMAGE.jpg [--model claude-opus-4-8] [--prompt "..."]
 *
 * Setup (this is the ONLY script that needs an install):
 *   npm install @anthropic-ai/sdk
 *   export ANTHROPIC_API_KEY=sk-ant-...
 *
 * Model: defaults to claude-opus-4-8 (most capable vision model). Pass
 * --model claude-sonnet-4-6 for a cheaper option.
 *
 * Requires Node >= 23.6 (runs .ts directly), or run with `bun` / `npx tsx`.
 */
import { readFileSync } from "node:fs";

const DEFAULT_PROMPT =
  "This is a photo of a physical whiteboard. Transcribe everything on it into " +
  "clean Markdown. Preserve structure (headings, bullets, numbered lists, tables, " +
  "columns). Describe any diagrams, arrows, or sketches in words. List any boxed or " +
  "circled action items separately under an '## Action items' heading. Note anything " +
  "you cannot read clearly rather than guessing.";

const MEDIA_TYPES: Record<string, "image/jpeg" | "image/png" | "image/gif" | "image/webp"> = {
  jpg: "image/jpeg", jpeg: "image/jpeg", png: "image/png", gif: "image/gif", webp: "image/webp",
};

function parseArgs(argv: string[]) {
  const a: { image?: string; model: string; prompt: string; maxTokens: number } = {
    model: "claude-opus-4-8", prompt: DEFAULT_PROMPT, maxTokens: 8192,
  };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    if (k === "--model") a.model = argv[++i];
    else if (k === "--prompt") a.prompt = argv[++i];
    else if (k === "--max-tokens") a.maxTokens = Number(argv[++i]);
    else if (!k.startsWith("--")) a.image = k;
  }
  return a;
}

async function main() {
  const a = parseArgs(process.argv.slice(2));
  if (!a.image) { process.stderr.write("usage: node process.ts IMAGE.jpg [--model ...] [--prompt ...]\n"); process.exit(2); }

  const ext = a.image.split(".").pop()?.toLowerCase() ?? "";
  const mediaType = MEDIA_TYPES[ext];
  if (!mediaType) { process.stderr.write(`error: unsupported image type '.${ext}' (use jpg/png/gif/webp)\n`); process.exit(2); }

  let Anthropic: typeof import("@anthropic-ai/sdk").default;
  try {
    Anthropic = (await import("@anthropic-ai/sdk")).default;
  } catch {
    process.stderr.write("process.ts needs the Anthropic SDK: npm install @anthropic-ai/sdk\n");
    process.exit(1);
  }

  const data = readFileSync(a.image).toString("base64");
  const client = new Anthropic(); // reads ANTHROPIC_API_KEY from the environment

  const response = await client.messages.create({
    model: a.model,
    max_tokens: a.maxTokens,
    messages: [{
      role: "user",
      content: [
        { type: "image", source: { type: "base64", media_type: mediaType, data } },
        { type: "text", text: a.prompt },
      ],
    }],
  });

  for (const block of response.content) {
    if (block.type === "text") process.stdout.write(block.text + "\n");
  }
}

main().catch((err) => { process.stderr.write(`error: ${err?.message ?? err}\n`); process.exit(1); });
