# PDF Scripts Toolkit

A Windows toolkit for digitizing scanned book pages — from raw photos/scans all the way
to a searchable PDF, with an optional AI transcription step for Sanskrit.

Built for **Tamil / Hindi / Sanskrit** books, but works for any printed pages.
Each stage is a **self-contained `.bat` file** (embedded Python/PowerShell) — no project
to build, just double-click.


## Why the Sanskrit step exists

Tesseract is good at Latin script and much weaker on Devanagari. Ligatures,
conjunct consonants and the headline stroke running across a whole word defeat
engines trained mostly on English. Add material that is old, foxed and
photographed rather than flat-scanned, and standard OCR returns something
between unusable and actively misleading.

So Sanskrit gets two passes — a vision-language model and EasyOCR — and neither
is trusted alone. Where they disagree, that disagreement is information: it marks
the pages a human should look at, instead of silently guessing and burying the
error in a searchable PDF nobody proofreads.

---

## Quick start

1. **Install prerequisites** — see **[INSTALL.md](INSTALL.md)**, or just run
   `00_PRESETS\00_INSTALL_ALL.bat` once.
2. **Double-click `00_CONTROL_PANEL.bat`** — the control panel that ties everything together.
3. Put your scans in the **`work\`** folder (or point the control panel at any folder).
4. Expand a stage panel, tweak the sliders, hit **Save & Run**.

---

## The pipeline

```
Raw scans (in work\)
   │
   ▼
[01] Adjust ........ brightness / contrast / saturation
   │
   ▼
[02] Smart Crop .... detect page, split 2-page spreads, straighten, centre, enhance
   │
   ▼
[03] Images → PDF .. stitch cropped images into one lossless PDF
   │
   ▼
[04] OCR ........... add an invisible searchable text layer (Tamil/Hindi/Sanskrit/English…)
   │
   ▼
Searchable PDF

[05] Sanskrit OCR (optional add-on) — local Devanagari OCR via EasyOCR (no server, no Ollama)
```

| Stage | Script | Engine | Output |
|-------|--------|--------|--------|
| 01 | `01_Adjust-Images- BR-CONT-SAT.bat` | PowerShell | adjusted images |
| 02 | `02_Smart-Crop-Pages.bat` | Python + OpenCV | cropped images |
| 03 | `03_Images-to-PDF.bat` | Python + img2pdf | PDF |
| 04 | `04_OCR-PDF.bat` | Python + ocrmypdf + Tesseract | **searchable** PDF |
| 05 | `06_EasyOCR-Sanskrit.bat` | Python + EasyOCR (PyTorch, local) | **editable** `.txt` |

> **04 vs 05:** stage 04 makes the *existing PDF searchable* (invisible text layer over the
> scan). Stage 05 uses EasyOCR (a local PyTorch model, language `hi` = Devanagari) to *read
> the page and type out the text* — produces plain editable text, not a searchable PDF. Runs
> fully offline in-process (no server, no Ollama, no Docker). Use whichever fits the job.

---

## The control panel

`00_CONTROL_PANEL.bat` gives you one window with:

- A **collapsible panel per stage** in a **two-column layout** (Adjust + Smart Crop on the
  left; Images→PDF, OCR, EasyOCR (Sanskrit) on the right) — expand, adjust, run, collapse.
- **Preview / sample browser** on Adjust and Smart Crop — it opens on your **working folder**
  (the path in the top bar; if the images sit one level down, like `work\6047`, it finds them).
  Step through with **Prev/Next**, **Use working folder** to re-sync, or **Folder…/Load file…**
  to look elsewhere. Tick **Apply settings** to see this stage's Before/After before running.
- **Presets** per stage (saved in `00_PRESETS\`), editable live; **Save**, **Save As New**, **Reset**.
- A shared **working folder** at the top, plus a per-preset folder with **Browse**.
- A live **Environment** panel showing whether each dependency is installed.
- **Run Full Pipeline** (01 → 02 → 03 → 04) and a one-click **Install / Repair Deps**.

---

## Folder layout

```
PDF Scripts\
├─ 00_CONTROL_PANEL.bat        ← start here
├─ 01..05  *.bat               ← the pipeline stages
├─ 00_PRESETS\                 ← presets (.json) + one-click installer + bundled Tesseract
├─ work\                       ← YOUR scans / images / PDFs go here
├─ README.md                   ← this file
├─ INSTALL.md                  ← prerequisites to download & install
├─ _internal\                  ← auto-generated backups (_versions) — safe to ignore/delete
└─ _archive\                   ← old copies & big archives (not needed to run)
```

The `work\` folder ships with example scans (`01.pdf`, `02.pdf`, `03_old scanner`, …) so you
can try the pipeline immediately. Replace them with your own.

---

## Sharing this as a bundle (zip)

To hand the toolkit to someone else, zip the `PDF Scripts` folder. You can safely **exclude**:

- **`_archive\`** — your old copies / large archives (not part of the software).
- **`.claude\`** — editor settings, not needed to run.
- **`_internal\`** — auto-backups; the scripts recreate this folder on first launch.
- Optionally **`work\`** contents — if you don't want to ship the example scans (~230 MB).

Keep: the six `.bat` files, `00_PRESETS\`, `README.md`, `INSTALL.md`, and an (empty) `work\`.

On the new machine: extract → run `00_PRESETS\00_INSTALL_ALL.bat` → double-click
`00_CONTROL_PANEL.bat`.

---

## Notes

- Every script auto-backs-up a copy of itself to `_internal\_versions\` each time it runs,
  so you always have previous versions.
- Preset folder paths are remembered suggestions — on a new machine just pick your folder
  in the control panel (the saved absolute paths from another PC won't exist).
