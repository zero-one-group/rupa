# Rupa identity assets

*Rupa* is Javanese for *form* or *shape*. The identity is the letter ꦫ (ra, U+A9AB) as the mark
and the word ꦫꦸꦥ (ra‑suku‑pa, "rupa") beside the Latin name as the lockup — the same system as
[Latu](https://github.com/zero-one-group/latu)'s, in teal instead of purple, so the two read as
siblings. All text is outlined; nothing here needs a font installed.

Every file is drawn by `dev/logo/build.py`; edit the constants there, not the SVGs.

## Files

| File | Use |
|---|---|
| `rupa-lockup.svg` / `rupa-lockup-dark.svg` | **Primary lockup**, `Rupa \| ꦫꦸꦥ`, for light / dark grounds |
| `rupa-lockup@2x.png` / `rupa-lockup-dark@2x.png` | Same, 1200 px wide, for places that will not take SVG |
| `rupa-lockup-with-mark*.svg` | Avatar tile + lockup, for a docs header or social card |
| `rupa-lockup-stacked*.svg` | Latin over Javanese, for banners |
| `rupa-mark.svg`, `-ondark`, `-mono`, `-white` | ꦫ alone; gradient for light / dark, flat Deep, white |
| `rupa-avatar.svg`, `rupa-avatar-{512,256,128}.png` | ꦫ on a tile — GitHub org/repo avatar, hex.pm |
| `favicon.svg`, `favicon.ico`, `favicon-{16,32,48}.png` | Favicon set (the tile) |

The README header uses `<picture>` with absolute `raw.githubusercontent.com` URLs, because the
same README renders on hex.pm, where a relative `assets/...` path resolves to nothing. ExDoc
takes the tile as `logo:` and `favicon:` (`mix.exs`, `docs/0`).

## Rules of the system

- The Javanese and Latin share a **baseline**; the suku hangs below the line, as it does when
  Hanacaraka is set beside Latin. Do not centre the Javanese word on the Latin's x‑height.
- **Nothing goes above or below the letter ꦫ.** Those positions are vowel and consonant signs.
  Decoration, if any, goes to the side.
- The avatar is the letter, never the word: ꦫꦸꦥ on a tile is unreadable at 32 px.
- The lockup image is **centred on the middle of the x‑height** — the band both scripts share —
  and the descenders hang into the lower half. The tile beside a lockup is centred on the middle
  of the Latin cap height, so it reads as level with "Rupa".

## Palette

Latu's six roles at Latu's lightness and chroma in OKLCH, turned to hue 185 with the chroma
pulled in to three quarters.

| | Hex | Role |
|---|---|---|
| Ink | `#002C28` | tile base, darkest text |
| Deep | `#00443E` | flat mark, Latin wordmark on light |
| Mid | `#236760` | Javanese text on light |
| Bright | `#02887E` | gradient stop |
| Glow | `#2EADA0` | Javanese text on dark; gradient stop |
| Ember | `#6ECFC3` | glyph on the tile |

The mark's gradient runs Bright → Mid → Deep from the base up on light grounds ("lit from
below"), and Ember → Glow → Bright on dark grounds.

## Type

- Latin: [Outfit](https://fonts.google.com/specimen/Outfit) Medium (500), tracking −2/1000.
- Javanese: [Noto Sans Javanese](https://fonts.google.com/noto/specimen/Noto+Sans+Javanese)
  Bold (mark, so it holds at 16 px) and Regular (lockups). Both SIL Open Font License; the
  outlines are embedded in the SVGs.

## Why the script only appears as images

GitHub cannot load web fonts and macOS ships no Javanese font, so ꦫꦸꦥ typed into Markdown
renders as boxes for many readers. Every occurrence of the script in the README and the docs
is therefore an SVG with outlined text, never inline characters.
