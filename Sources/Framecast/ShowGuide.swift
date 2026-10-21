import Foundation

/// The guide each show folder carries for AI coding apps (CLAUDE.md for Claude Code, AGENTS.md for others), so a
/// session opened in the folder knows how to turn the presenter's brief into topics and assets Framecast can use.
/// Written when missing; a guide the presenter edited (without the first-line marker) is left alone.
enum ShowGuide {
    static let marker = "<!-- framecast show guide v2 -->"

    static func write(in folder: URL) {
        for name in ["CLAUDE.md", "AGENTS.md"] {
            let url = folder.appendingPathComponent(name)
            // Rewrite guides Framecast wrote (any version); leave ones the presenter edited.
            if let old = try? String(contentsOf: url, encoding: .utf8), !old.hasPrefix("<!-- framecast show guide") || old == text { continue }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static let text = """
    \(marker)
    # This folder is a Framecast show

    Framecast is the presenter's live-streaming app. This folder holds one show. During the show Framecast listens to
    the presenter (on their Mac), follows which topic they're on, ticks off the points they've covered, and puts the
    assets below on screen when they talk about them, changing the camera look as it goes. Your job is to prepare it.

    ## What to do with a brief

    The presenter describes the show in `brief.md` or in chat: the topics, what they want to say, maybe a few lines.
    It is not a script, and they won't read one. From it:

    1. Write the outline: `topics` in `show.json`. Each topic has a short `title`, three to six `points` (short
       phrases the presenter will cover, in their words), an optional `look` and the `assets` that belong to it.
    2. Make the assets in `assets/` and describe each one in the `assets` list of `show.json` (`file` and `about`:
       one line on what it shows, which is how Framecast knows when it fits).
    3. Keep everything else in `show.json` as it is. Framecast notices changes to `show.json` and `assets/` within a
       couple of seconds; don't touch other files.

    ```json
    {
      "title": "Opus vs Sonnet",
      "topics": [
        { "title": "Price", "points": ["Opus costs $4 per million input tokens", "Sonnet costs $2"],
          "look": "", "assets": ["price-chart.png"] }
      ],
      "assets": [ { "file": "price-chart.png", "about": "Bar chart: input price per million tokens, Opus $4 vs Sonnet $2" } ]
    }
    ```

    `look` is optional: the name of one of the presenter's scenes (ask Framecast with `get_show_state`), for
    example a camera look for the intro. Leave it empty and Framecast picks.

    ## Assets

    - 1920×1080 PNG or JPG for pictures and cards. MP4 or MOV for video (HEVC with alpha is fine). Lower-case file
      names with hyphens.
    - Framecast animates assets in and out itself. It doesn't play HTML, so render any animation to MP4/MOV
      yourself first.
    - Think like a video editor: show, don't write. Prefer motion graphics to text. If the `framecast` MCP server is
      connected, use it:
      - `make_motion`: animated title, roadmap, stick-figure scenes (juggle, relax, compare), bar chart, gauge,
        data pipeline and checklist, from data, in the show's style. The juggle, relax and pipeline templates loop.
      - `make_card`: still or animated cards (title, bullets, chart, quote, number, flow, reference) when nothing
        visual fits.
      - `save_image`: a picture from a web address.
      - `set_outline`: write the topics without editing `show.json`.
    - Pictures from the web: only from sources that allow reuse (Wikimedia Commons, Openverse, the presenter's own
      material). Put the credit in `about`.
    - Never draw or generate a company's logo; use its name as text.
    - Numbers on screen must come from a source. Put the source on the card.

    ## Costs

    The presenter prepares shows on their own Claude or ChatGPT plan, so do the preparation here. The live show
    uses a small model on the presenter's API key; nothing else needs one.
    """
}
