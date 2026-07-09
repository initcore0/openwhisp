# Changelog

The **source of truth** for what OpenWhisp has shipped, as structured data a site
build (or an agent) can render into a public changelog page.

## Files

- **`changelog.json`** — machine-readable, the canonical source. Read THIS, not the HTML.
- **`changelog.html`** — a committed reference render of the latest release, for
  humans and quick preview. Regenerated from the JSON; never hand-edit it to add
  content (edit the JSON, then re-render).
- **`README.md`** (this file) — the contract.

## Data shape

```
{
  "project": "OpenWhisp",
  "generated": "YYYY-MM-DD",
  "releases": [                      // newest first
    {
      "id": "2026-07",              // stable slug
      "title": "July 2026",
      "date": "YYYY-MM-DD",
      "summary": "one-line intro",
      "stats": {                     // headline numbers for the release
        "changesShipped": 14,
        "newFeatures": 5,
        "testsPassing": 757,
        "onDevicePercent": 100
      },
      "entries": [
        {
          "category": "feature" | "fix" | "improvement",
          "headline": "user-facing title — what they GET, not the commit subject",
          "body": "1–2 sentences, plain language, active voice",
          "tickets": ["MAK-35"],   // Linear issue IDs (the receipts)
          "prs": [121]              // merged GitHub PR numbers
        }
      ]
    }
  ]
}
```

## How to add a release (for an agent or a human)

When a batch of work merges to `main`:

1. **Gather the merged PRs** for the batch (e.g. `gh pr list --state merged --search "merged:>=<date>"`) and their Linear tickets. Each `MAK-*` ticket + its PR is one entry.
2. **Write user-facing copy.** The headline says what the user gets, not the
   commit subject — `fix(engines): path-scope subprocess identity` becomes
   *"OpenWhisp can't accidentally kill your other whisper servers."* Body is 1–2
   plain sentences, active voice, from the user's side of the screen.
3. **Categorize**: `feature` (new capability), `fix` (a bug corrected),
   `improvement` (under-the-hood / tech-debt the user benefits from indirectly).
4. **Fill `stats`** from the real batch — total changes, new features, the
   `swift test` count on merged `main`, and any true "% on-device" style claim.
   Don't invent numbers; verify them.
5. **Prepend the release** to `releases` (newest first) and update `generated`.
6. **Re-render `changelog.html`** from the JSON (the render is a straight mapping:
   header + stat strip + three grouped sections keyed on `category`, with the
   ticket/PR tags as mono "receipts"). Keep it self-contained, theme-aware
   (light/dark), and in the openwhisp.app palette (deep-teal ground, cyan "speak"
   accent — see the committed HTML for the exact tokens).

## Rendering it elsewhere (the website)

The public site consumes `changelog.json` and renders its own `/changelog` page.
Point the site build at this file; the committed `changelog.html` is a reference
implementation of the layout, not the site's copy of it. Keep the JSON the single
source so the site and the reference render never drift.

## Voice

The ticket/PR numbers are deliberate — OpenWhisp is local-first and hackable, and
the receipts are part of the point: every change traces to a public issue and a
reviewed PR you can read, run, and fork. Keep that transparency in the copy.
