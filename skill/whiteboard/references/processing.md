# Reading a whiteboard image

How to turn a captured whiteboard photo into useful output. The running model
reads the image directly (via the Read tool) — these are conventions, not code.

## Default output (no specific instruction from the user)

Produce a faithful Markdown transcription:

- Preserve structure: headings, bullet lists, numbered lists, tables, and
  left/right or column splits on the board.
- Keep the author's wording. Don't paraphrase or "clean up" content.
- Render diagrams, flowcharts, and arrows as a short prose description (or a
  Mermaid block if it's clearly a graph/flowchart and the user would benefit).
- Pull boxed, starred, or circled items into a separate `## Action items` section —
  these are almost always TODOs or decisions.
- Mark anything illegible as `[illegible]` rather than guessing. Note low
  confidence explicitly instead of inventing text.

## Tailor to the request

The skill argument is the user's intent. Examples:

- "what are the action items" → list only the action items.
- "summarize" → a few-sentence summary, then the transcription.
- "is there anything about the Q3 launch" → answer from the board; quote the
  relevant text.
- "turn the diagram into mermaid" → emit a Mermaid diagram.

## Image-quality tips

- **Glare / hotspots:** reflections from windows or lights can wipe out strokes.
  If a region is washed out, say so; suggest the user recapture or reposition the
  Pi. Diffuse, even lighting reads best.
- **Skew / angle:** the model can read moderately skewed boards. For a badly
  angled shot, note it and recapture.
- **Faint markers:** light blue/green/yellow markers photograph poorly. Flag
  uncertain colors.
- **Resolution:** the server captures ~2304×1296 by default — fine for normal
  handwriting. For very dense or small text, raise `WHITEBOARD_WIDTH/HEIGHT` in
  the Pi config (see hardware-setup.md) or move the camera closer.
- **Multiple boards in frame:** transcribe each separately with a heading.

## Recapture loop

If the first photo is unusable, just run `node scripts/capture.ts` again — every
call takes a fresh photo. Suggest a fix (lighting, angle, focus) before retrying.
