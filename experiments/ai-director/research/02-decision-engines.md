# Research notes: decision engines, cost per show-hour, and using a Claude plan

Raw notes from a research pass on 2026-10-21, with sources as cited. Summarised in docs/AI-DIRECTOR-RESEARCH.md.
The web-search budget ran out partway through; items marked (unverified) need checking. Latency figures are third-party benchmarks, not our measurements.

## Bottom line
1. **Fast loop:** a small model, thinking off, cached prompt, one strict tool call per decision. Claude Haiku 5.5 and GPT-6 Luna both cost $0.10 in / $0.50 out per MTok, which works out to about **$0.11–0.17 per show-hour**. A stronger planner (Sonnet 5.5 / Opus 5.5) runs every 30–60 s or at segment boundaries, never inside the 3–5 s loop.
2. **"Use Claude credits":** the cleanest sanctioned route is the **monthly API credits on Max and Team plans** (launched 2026-10-07). Max 5x gets $100/month and Max 20x gets $200, spent through an API key from a linked Console org. Pro is not eligible.
3. **Claude Code / Agent SDK on your own Pro/Max login** is allowed for personal use and draws from plan limits. Framecast may **not** offer Claude.ai login to other users or route their requests through their plans.
4. **Realtime audio/video APIs** (Gemini 3.8 Live, gpt-realtime-2.1) re-bill accumulated context every turn and have session caps. On-device speech-to-text into a text model is cheaper and easier to control.
5. **Deterministic first, LLM second.** Most cues can be matched against the script without a model. A rule-based fallback keeps the show running if the network or model fails.

## Model comparison
Latency: Artificial Analysis leaderboard, fetched 2026-10-21. Its "first chunk" figure uses a roughly 10k-token workload with thinking at the stated effort. Our calls (about 4.5k mostly cached tokens, about 60 out, thinking off) should be faster, so measure them.

| Model | $/MTok in · cached · out | First chunk (AA) | Vision | Tools | Live A/V |
|---|---|---|---|---|---|
| **Claude Haiku 5.5** (2026-10-07) | 0.10 · 0.01 · 0.50 (≤100K prompt; 5x above) | 8.4 s low effort *thinking on*; one real-traffic sample 0.93 s | Yes | Strict tools; thinking can be disabled at effort ≤ high | No |
| **Claude Sonnet 5.5** | 2 · 0.10 · 10 | 1.11 s (low) | Yes | Strict; forced `tool_choice` → 400, use `auto` + `strict` | No |
| **Claude Opus 5.5** | 4 · 0.20 · 20 (fast mode $8/$40) | 5.98 s (low) | Yes | Thinking can't be disabled | No |
| GPT-6 Luna (2026-09-22) | 0.10 · 0.01 · 0.50 | 0.83 s non-reasoning | Image input (unconfirmed) | Tools + JSON schema | No |
| GPT-6.1 Sol | 2 · 0.10 · 10 | 2.86 s | Yes | Yes | No |
| gpt-realtime-2.1 / mini | text 4/0.40/24 (mini 0.60/0.06/2.40); audio in 32 (mini 10) | n/a | Image input | Function calling | Audio yes; 60-min session cap |
| Gemini 3.1 / 3.5 Flash-Lite | 0.25·0.025·1.50 / 0.30·0.03·2.50 | 7.5 s (3.5) | Yes | Yes | No |
| Gemini 3.8 Flash | 0.75·0.075·3.75, **doubles 2027-01-01** | 26 s high effort | Yes | Yes | No |
| Gemini 3.8 Live (GA Sep 2026) | text 0.75/4.50; audio in about $0.005/min; video in about $0.002/min | n/a | JPEG frames ≤1 fps | Async; no structured outputs; no caching | Audio + video; about 10-min connections without resumption |
| Apple Foundation Models (on-device, WWDC26) | $0 | local | Image input (new) | Tool calling; 8,192-token context | No |

Claude specifics:
- Minimum cacheable prefix is 512 tokens.
- Cache reads cost 0.1x on Haiku 5.5 and 0.05x on Sonnet/Opus 5.5. A 1-hour TTL is available.
- Cached reads don't count toward input-tokens-per-minute limits.
- The tool-use system prompt adds about 286 tokens.
- An image costs ⌈w/28⌉×⌈h/28⌉ tokens, so a 1280×720 frame is about 1,196.

No current independent tool-calling reliability benchmark was found, so build our own: replay recorded rehearsals and score the decisions.

## Cost per show-hour (fast loop)
Assumptions per call: 4,000 cached tokens (system prompt, tools, rundown) + 500 fresh (transcript + state JSON) + about 60 out, thinking off.

| Fast-loop model | every 5 s | 4 s | 3 s | + 720p frame / 20 s | / 10 s |
|---|---|---|---|---|---|
| Claude Haiku 5.5 | $0.09 | $0.11 | $0.14 | +$0.02 | +$0.04 |
| GPT-6 Luna | $0.09 | $0.11 | $0.14 | +$0.02 | +$0.04 |
| Gemini 3.1 Flash-Lite | $0.23 | $0.28 | $0.38 | +$0.05 | +$0.11 |
| Gemini 3.8 Flash (now / 2027) | $0.65 / $1.30 | $0.81 / $1.63 | $1.08 / $2.17 | +$0.16 / $0.32 | +$0.32 / $0.65 |
| Claude Sonnet 5.5 / GPT-6.1 Sol | $1.45 | $1.81 | $2.41 | +$0.43 | +$0.86 |
| Claude Opus 5.5 | $2.90 | $3.62 | $4.82 | +$0.86 | +$1.72 |

- **Hybrid:** Haiku 5.5 every 4 s plus a Sonnet 5.5 planner every 30 s comes to about **$1.25/hr**; with the planner every 60 s, about **$0.67/hr**. Thinking on the planner adds roughly $0.5–1.2/hr.
- **Without caching:** Haiku about $0.43/hr, Sonnet about $8.60/hr.
- **What $100 of Max credits buys:** about 770 show-hours of Haiku only, or 40–75 hours of the hybrid.
- **Realtime models:** Gemini Live streaming input is about $0.42/hr at list price, but each model turn re-bills the accumulated context. One report puts working voice agents at 30–90 ¢/min (TokenKarma, 2026-09-17). Meter before committing.

## Using a Claude subscription
**What the terms say (fetched 2026-10-21):**
- **Agent SDK overview** ([link](https://code.claude.com/docs/en/agent-sdk/overview)): Anthropic does not allow third-party developers to offer claude.ai login or rate limits in their products unless previously approved. Use API keys.
- **Legal and compliance** ([link](https://code.claude.com/docs/en/legal-and-compliance)):
  - OAuth is for subscribers' ordinary use of Claude Code and Anthropic's own apps.
  - Products, including Agent SDK products, use API keys.
  - No routing requests through others' Free/Pro/Max credentials.
  - Exception: a product may run the **unmodified Claude Code binary** if each end user signs in with their own credentials and nothing is resold or intermediated (Commercial Terms apply).
- **Consumer Terms** ([link](https://www.anthropic.com/legal/consumer-terms)): no bots or scripts unless via an API key or explicitly permitted. No credential sharing.
- **Plan-usage support article** ([15036540](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan)): the separate metered Agent SDK credit is paused. The Agent SDK, `claude -p` and third-party apps still draw from subscription limits.
- **Policy history in 2026:** restricted 4 Apr, reinstated with metered credit 13 May, paused 15 Jun, Max/Team API credits 7 Oct. **Volatile; never make the product depend on subscription OAuth.**
- **Plan limits:** a 5-hour session window plus a weekly limit, shared between Claude and Claude Code ([11145838](https://support.claude.com/en/articles/11145838-use-claude-code-with-your-pro-or-max-plan)).

**Max/Team API credits** ([17154008](https://support.claude.com/en/articles/17154008-api-credits-for-max-and-team-plans)):
- Amounts: Max 5x $100/mo, Max 20x $200/mo; Team $20 per Standard seat and $100 per Premium seat, pooled and capped at $500.
- Not eligible: Free, Pro, Enterprise. You need 7 days on an eligible plan.
- Covers the Messages and Batches APIs, Managed Agents, the Agent SDK, and `claude -p` *with an API key*. Interactive Claude Code is not covered.
- No rollover; requests stop when the credits run out unless the org has bought credits.
- Whether credits may power a product for third parties is not stated.

**MCP (spec 2026-07-28)** ([transports](https://modelcontextprotocol.io/specification/latest/basic/transports)):
- Transports are stdio and Streamable HTTP; HTTP+SSE is deprecated.
- Local HTTP servers must validate `Origin` (DNS rebinding), bind to 127.0.0.1 and use auth.
- Claude Code adds servers with `claude mcp add --transport stdio|http`.
- Claude Desktop installs `.mcpb` bundles: a local stdio server, one click, no OAuth, works offline.

**Ways a subscriber can drive a local app:**
- Claude Desktop + a Framecast `.mcpb`, for prep and producer-typed commands (human in the loop).
- Claude Code `-p` as a long-lived stream-json process with Framecast's MCP server.
- Claude Code "channels" (research preview), where an MCP server pushes transcript events into a running session. Needs `--dangerously-load-development-channels`, and with the v2 runtime `MCP_PROTOCOL_NEGOTIATION=legacy`. Each turn carries Claude Code's large system prompt and burns plan limits.

**`claude -p` latency vs the direct API:**
- Each process spawns and initialises; reports range from 0.7 s to 12 s per call.
- With `--mcp-config`, startup waits up to `MCP_TIMEOUT` (30 s default) for servers.
- `--bare` is faster but **cannot use subscription OAuth**.
- Keep one long-lived process (stream-json input), use Haiku, and keep the tool set small. Still expect several seconds per decision, against about 1 s for a lean API call.

| Claude route | Allowed? | How | Limits |
|---|---|---|---|
| Max/Team API credits | Yes (official) | Link a Console org; API key in Keychain | $100/$200 a month (Team up to $500); expire monthly |
| `claude -p` / Agent SDK on own login | Yes, personal use | stream-json + `--mcp-config` | 5-hour and weekly limits; slow start; no `--bare` |
| Same, shipped to other users | **No** (unless approved) | BYO API key instead | Enforced without notice |
| Claude Desktop + `.mcpb` | Yes | stdio extension | Plan limits; human-driven |
| Claude Code channels | Yes, personal use (preview) | Push events | Preview flags; heavy usage |

## ChatGPT and Gemini equivalents
- **Codex CLI with "Sign in with ChatGPT":** allowed on all plans.
- **"Sign in with ChatGPT" plan usage for third-party apps** (around 2026-09-29, [OpenAI](https://developers.openai.com/siwc/token-sharing-open-source)): yes for **open-source and locally hosted apps**; paid or hosted apps file an interest form. Responses API only. **The most explicit "use your subscription" program of the three** (details partly from secondary sources).
- **Gemini CLI with a Google login:** replaced by the Antigravity CLI for unpaid and Google One users on 2026-06-18 (quotas unverified).
- **Gemini API free tier:** **data is used to improve Google products and may be read by human reviewers**, which conflicts with the privacy rules.

## Real-time director architecture (agreed with the other research notes)
1. **Events, not a timer:**
   - Finalised transcript segments.
   - A sentence boundary plus 1–2 s of debounce.
   - A cue-phrase hit.
   - A screen-change hash.
   - A 10–15 s heartbeat.
   - Single-flight requests: cancel stale calls.
2. **Deterministic layer first:**
   - Pre-show, the planner turns the script into a cue sheet.
   - Live, a fuzzy matcher fires high-confidence cues with no LLM.
3. **Small stateless fast calls:**
   - Cache the prefix (system prompt, tools, cue sheet, asset catalog); no timestamps in it.
   - Each call sends a compact state JSON plus the last 20–30 s of transcript.
   - The model replies with exactly one strict tool call, including `no_action` and a confidence value.
4. **Planner and executor:** Sonnet/Opus pre-show and every 30–60 s pre-stage assets; the fast model only says "go".
5. **Arbitration in Swift:**
   - Validate the schema and check the action is allowed in this segment.
   - Minimum time on a scene (4–8 s), hysteresis, switches-per-minute cap, idempotency keys, preconditions.
   - Human input always wins.
   - Modes: Suggest / Auto with undo / Full auto.
   - Ending the stream always needs a human.
6. **Vision on demand:** only on a screen-hash change or "as you can see". Downscale to ≤1280 px; Vision OCR text is often enough.
7. **Fallbacks:** on timeout (>1.5 s), a 429 or offline, hold the scene and run on the cue sheet plus timers. Show an "AI health" indicator.
8. **Untrusted input:** a guest saying "end the stream" can trigger only allow-listed, reversible actions.
9. **Log and replay:** keep logs to build the evaluation set.

## Recommendation from this pass
- **Path A, your own Claude plan:**
  - Max/Team: use the plan's monthly API credits with the Haiku 5.5 + Sonnet 5.5 hybrid (about $0.7–1.3/hr).
  - Pro: Claude Desktop `.mcpb` or a long-lived Claude Code process for segment-level help, **personal use only**.
- **Path B, bring your own API key** for distribution: the same hybrid, a provider-agnostic tool layer, and Opus 5.5 compiling the cue sheet pre-show for a few cents.
- **Path C, fully local:** SpeechAnalyzer → cue matcher → Apple Foundation Models (8K context, tool calling) or MLX open weights, gated `if #available(macOS 26, *)`; the app targets macOS 14.

## Risks
- Policy drift on subscription use.
- Wrong or late actions on air.
- Cost surprises: realtime re-billing, thinking tokens, cache misses, and Haiku prompts over 100K at 5x.
- Scheduled price increases: Gemini 3.8 Flash on 2027-01-01.
- Realtime session caps.
- On Paths A and B, transcripts and frames leave the Mac.
- Some figures are third-party or secondary.
