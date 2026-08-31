# Freed Page app icon — v2

- Generation mode: built-in ImageGen edit
- Use case: `precise-object-edit`
- Edit target: `Resources/AppIcon-FreedPage.png`
- Final asset: `Resources/AppIcon-FreedPage-v2.png`
- Palette: midnight navy `#14263B`, warm ivory `#FAF3E5`, charcoal `#263442`, muted blue `#6F8EAE`, coral red `#E84F47`, lettering `#FFF4DF`

## Main edit prompt

```text
Use case: precise-object-edit
Asset type: production-ready 1024 × 1024 macOS app icon master
Input images: Image 1 is the edit target and must remain the recognizable base design.
Primary request: Refine this existing app icon. Remove every green or green-tinted pixel and make the palette sophisticated. Make the ivory document unmistakably read as a PDF containing a university textbook page or formal contract. Add clean, simplified printed-document structure: a dark navy title/header near the upper area, several short charcoal horizontal text lines, one compact boxed academic chart/table or contract clause block, and one subtle signature/annotation line near the bottom. These elements must look like document layout, not readable body copy, and remain bold enough for an app icon.
Red band change: Keep the red torn band, but place the exact word "PRICE" across it in bold uppercase condensed off-white sans-serif lettering. Spell it exactly P-R-I-C-E, once only. The band and the word must tear together at the center: put "PRI" on the left torn half and "CE" on the right torn half, with the same central jagged gap. The letters nearest the split should be visibly cut by the tear so the price/paywall itself feels broken. Preserve high contrast and legibility at 128 px.
Style/medium: restrained premium soft-3D native macOS utility icon; elegant, trustworthy, polished; strong geometric silhouette
Color palette: deep ink navy #14263B with restrained midnight-blue highlights, warm ivory #FAF3E5, charcoal #263442, muted steel blue #6F8EAE, coral red #E84F47, lettering #FFF4DF. Absolutely no green, teal, lime, mint, olive, chartreuse, emerald, or green cast anywhere.
Composition/framing: preserve the centered navy rounded-square base, centered folded-corner paper, horizontal red band, generous padding, and compact shadows. Keep the outer canvas transparent. Do not add any background outside the rounded-square icon base.
Text (verbatim): "PRICE"
Constraints: Change only the document content, the red band lettering/tear, and any green contamination; keep the overall icon geometry and premium depth. Render PRICE exactly once with no misspelling and no extra words. No literal "PDF" label is required; the formal printed page layout should communicate PDF. No currency symbol, coins, coffee cup, lock, chain, flame, angry face, fist, character, Adobe logo, Apple logo, watermark, dashboard tiles, neon, or green. Keep the paper intact; only the price band and PRICE lettering are torn.
```

## Transparency cleanup prompt

```text
Change only the area outside the dark navy rounded-square app icon base. Replace the entire checkerboard outside area with one perfectly flat, uniform solid #FF00FF chroma-key color for later removal. Keep every detail inside the icon unchanged. No green anywhere.
```

The magenta chroma-key background was removed locally with a soft matte and despill. The final PNG was resized to 1024 × 1024, checked at 128 px and 32 px, and verified to contain no green-dominant opaque pixels.
