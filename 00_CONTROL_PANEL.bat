@echo off
rem ============================================================
rem  00_CONTROL_PANEL.bat  -  Unified GUI for PDF Scripts Toolkit
rem  Single window launcher: 01 Adjust -> 02 Crop -> 03 PDF -> 04 OCR
rem  Preset management, dependency status, full-pipeline runner.
rem
rem  VERSION HISTORY
rem  v1.0  2026-05-03  Initial release  -  Tkinter dark control panel
rem  v1.1  2026-06-02  Schema-driven slider/toggle preset editor per stage
rem  v1.2  2026-06-02  Inline collapsible stage panels (no more pop-ups)
rem  v1.3  2026-06-02  Light off-white theme, visible sliders, OCR links
rem  v1.4  2026-06-02  Add stage 05 Sanskrit VLM OCR (Ollama + Qwen2.5-VL)
rem  v1.5  2026-06-02  Housekeeping: backups -> _internal\_versions
rem  v1.6  2026-06-02  Live Before/After preview for Adjust & Smart Crop
rem  v1.7  2026-06-03  Preview = folder browser (Prev/Next, Apply-settings toggle)
rem  v1.8  2026-06-03  Preview defaults to the working folder (top bar)
rem  v1.9  2026-06-03  Two-column layout; compact rows; single-line sliders
rem  v2.1  2026-06-03  Replace Stage 05 VLM OCR with IndicOCR (ihdia/sanskrit-ocr)
rem  v2.2  2026-06-03  Stage 05 -> EasyOCR (local, in-process); fix schema crash
rem  v2.3  2026-06-03  Panel: drop per-stage folder row, group preset buttons,
rem                    add single-file picker to stage 04 (OCR)
rem  v2.4  2026-06-03  Balanced 3/3 columns; re-add IndicOCR panel (experimental,
rem                    TF-vs-EasyOCR conflict guarded so it can't break stage 05)
rem  v2.5  2026-06-03  Per-stage Folder field for 01/02/03; file picker for OCR 04/05/06
rem  v2.6  2026-06-03  Remove global folder bar; every module has its own Work folder
rem  v2.7  2026-06-03  IndicOCR runs in its own isolated venv (TF+numpy<2)
rem  v2.8  2026-06-05  Remove IndicOCR entirely (garbage output); 5 stages
rem  v2.9  2026-06-05  EasyOCR: combined SEARCHABLE PDF output (text underlay)
rem  v3.0  2026-06-05  EasyOCR: PDF/A option + GPU/CPU device selector
rem  v3.1  2026-06-09  EasyOCR: per-GPU checkboxes + PDF size controls (quality/maxdim)
rem  v3.2  2026-06-09  EasyOCR: PDF normalised by DPI (output DPI + OCR DPI + quality)
rem ============================================================
setlocal
set "BATFILE=%~f0"
set "PATH=%PATH%;C:\Program Files\Tesseract-OCR;C:\Program Files (x86)\Tesseract-OCR"

rem -- Auto-backup this script to _versions\ -------------------
if not exist "%~dp0_internal\_versions\" mkdir "%~dp0_internal\_versions\"
for /f "tokens=*" %%T in ('powershell -NoProfile -Command "Get-Date -Format 'yyyy-MM-dd_HHmmss'"') do set "_BKTS=%%T"
copy /y "%~f0" "%~dp0_internal\_versions\%~n0_%_BKTS%.bat" >nul 2>&1

rem -- Check Python --------------------------------------------
python --version >nul 2>&1
if errorlevel 1 (
    echo.
    echo  ERROR: Python is not installed.
    echo  Please install Python 3.x from https://python.org
    echo  Make sure to check "Add Python to PATH" during install.
    echo.
    pause & exit /b 1
)

rem -- tkinter ships with Python; Pillow optional for thumbs ---
python -c "import tkinter" >nul 2>&1
if errorlevel 1 (
    echo  ERROR: Python tkinter is missing. Reinstall Python with the
    echo  "tcl/tk and IDLE" option enabled.
    pause & exit /b 1
)

rem -- Extract Python section and run --------------------------
set "TMPPY=%TEMP%\pdf_control_panel_00.pyw"
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$f=$env:BATFILE;$l=[IO.File]::ReadAllLines($f);$s=0;for($i=0;$i-lt$l.Count;$i++){if($l[$i]-eq'#PY_BEGIN'){$s=$i+1;break}};[IO.File]::WriteAllLines($env:TMPPY,$l[$s..($l.Count-1)],[Text.Encoding]::UTF8)"

rem  pythonw -> no console window flashes behind the GUI
where pythonw >nul 2>&1
if errorlevel 1 (
    python "%TMPPY%"
) else (
    start "" pythonw "%TMPPY%"
)

exit /b
#PY_BEGIN
#!/usr/bin/env python3
"""
00 Control Panel  v3.2  -  Unified GUI for the PDF Scripts toolkit.

A single window ties together the pipeline scripts:
    01 Adjust  ->  02 Crop  ->  03 Images-to-PDF  ->  04 OCR
    + 05 Sanskrit VLM OCR (optional add-on, Ollama + Qwen2.5-VL)

Features
--------
- Pick a working folder once; share it across all 4 stages
- Per-stage preset dropdowns (auto-discovered from 00_PRESETS/)
- Live dependency status (Python pkgs, Tesseract + languages)
- One-click "Run Full Pipeline" chains every stage in sequence
- Each stage is an inline collapsible panel (expand, tweak, run, collapse)
- Live sliders / toggles / dropdowns per stage (no separate pop-up windows)
- Set the folder path per preset (Browse, or sync to the working folder)
- Edit / duplicate / delete presets, open folder shortcuts, log pane
- Crash log written to %TEMP%\pdf_control_panel_crash.log
"""

import os, sys, json, glob, shutil, subprocess, threading, traceback, time, tempfile, re, webbrowser, queue
import tkinter as tk
from tkinter import ttk, filedialog, messagebox, scrolledtext
from pathlib import Path
from datetime import datetime

# Suppress the Windows "Application Error" pop-up when a child process (e.g. a
# broken Ghostscript install) fails to initialize - we already handle the
# error code in code, we just don't want the modal OS crash dialog. Child
# processes inherit this error mode.
if os.name == "nt":
    try:
        import ctypes
        # SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX
        ctypes.windll.kernel32.SetErrorMode(0x0001 | 0x0002 | 0x8000)
    except Exception:
        pass

VERSION = "3.16"  # Images->PDF batch mode: each subfolder -> its own <folder>.pdf

# ============================================================
#  Paths + script registry
# ============================================================

def script_folder():
    if os.environ.get("BATFILE"):
        return os.path.dirname(os.environ["BATFILE"])
    return os.path.dirname(os.path.abspath(sys.argv[0]))

ROOT       = script_folder()
PRESETS    = os.path.join(ROOT, "00_PRESETS")
VERSIONS   = os.path.join(ROOT, "_internal", "_versions")
SAMPLE_IMG = os.path.join(PRESETS, "_sample_scan.jpg")   # default preview image
HISTORY_FN = os.path.join(PRESETS, ".control_panel_history.json")

os.makedirs(PRESETS, exist_ok=True)

# Each pipeline stage. `bat` is the .bat to launch, `prefix` is the
# preset filename prefix, `out` is the kind of output the stage produces.
STAGES = [
    {
        "id":     "01",
        "title":  "Adjust",
        "tag":    "Brightness / Contrast / Saturation",
        "bat":    "01_Adjust-Images- BR-CONT-SAT.bat",
        "prefix": "preset_",
        "out":    "images",
        "color":  "#4FC3F7",
        "icon":   "[01]",
    },
    {
        "id":     "02",
        "title":  "Smart Crop",
        "tag":    "Detect, split, straighten, centre",
        "bat":    "02_Smart-Crop-Pages.bat",
        "prefix": "sc_preset_",
        "out":    "images",
        "color":  "#81C784",
        "icon":   "[02]",
    },
    {
        "id":     "03",
        "title":  "Images -> PDF",
        "tag":    "Lossless JPEG stitching",
        "bat":    "03_Images-to-PDF.bat",
        "prefix": "i2p_preset_",
        "out":    "pdf",
        "color":  "#FFB74D",
        "icon":   "[03]",
    },
    {
        "id":     "04",
        "title":  "OCR",
        "tag":    "Searchable text layer",
        "bat":    "04_OCR-PDF.bat",
        "prefix": "ocr_preset_",
        "out":    "pdf",
        "color":  "#BA68C8",
        "icon":   "[04]",
        "extras": [("Advanced...", "_open_ocr_advanced")],
        # Sanskrit OCR engines/resources surfaced in the OCR panel.
        # The pipeline itself OCRs Sanskrit via Tesseract's 'san' model;
        # the GitHub projects are research code (CNN / CNN-RNN), linked
        # here for reference - they are not drop-in engines.
        "resources": [
            ("Tesseract 'san' model - used by this pipeline (tessdata_best)", None),
            ("avadesh02/SanskritOCR - research, CNN (TensorFlow/Keras)",
             "https://github.com/avadesh02/SanskritOCR"),
            ("ihdia/sanskrit-ocr - research, CNN-RNN + pretrained models",
             "https://github.com/ihdia/sanskrit-ocr"),
        ],
    },
    {
        "id":     "05",
        "title":  "EasyOCR (Sanskrit)",
        "tag":    "Local Devanagari OCR via EasyOCR (no Ollama / server)",
        "bat":    "06_EasyOCR-Sanskrit.bat",
        "prefix": "eocr_preset_",
        "out":    "text",
        "color":  "#E0934D",
        "icon":   "[05]",
        "pipeline": False,   # optional add-on, not part of Run Full Pipeline
        "hasFileSelector": True,   # OCR a single image or PDF file
        "fileFilter": [("Images & PDFs", "*.jpg *.jpeg *.png *.bmp *.tif *.tiff *.webp *.pdf"),
                       ("All files", "*.*")],
        "resources": [
            ("Makes a combined SEARCHABLE PDF (image + invisible text underlay).", None),
            ("Input: a folder of images, a single image, or a PDF (auto-rasterised).", None),
            ("Local in-process via PyTorch - no server/Ollama. 'hi' = Devanagari.", None),
            ("EasyOCR - JaidedAI",
             "https://github.com/JaidedAI/EasyOCR"),
        ],
    },
]

# OCR languages exposed in the Advanced dialog
OCR_LANGS = [
    ("eng", "English"),  ("tam", "Tamil"),    ("hin", "Hindi"),
    ("san", "Sanskrit"), ("tel", "Telugu"),   ("kan", "Kannada"),
    ("mal", "Malayalam"), ("ben", "Bengali"), ("guj", "Gujarati"),
    ("mar", "Marathi"),  ("pan", "Punjabi"),  ("ori", "Odia"),
    ("urd", "Urdu"),     ("nep", "Nepali"),
]

# ============================================================
#  Preset field schemas  -  drive the slider/toggle editor
# ============================================================
#  Each stage id maps to an ordered list of field specs. Field
#  "kind" decides which widget the editor renders, and the "key"
#  is the exact JSON key each pipeline script reads. Ranges and
#  defaults mirror the prompts inside 01-04 so the GUI and the
#  console menus stay in lock-step.
#
#  kinds:
#    slider      numeric tk.Scale            (min, max, step, default, float)
#    toggle      checkbox  -> bool           (default)
#    choice      dropdown  -> str            (values, default)
#    multichoice checkbox grid -> list[str]  (values=[(code,label)], default)
#    text        single-line entry -> str    (default)
#    adjust      toggle + slider for one 01 adjustment (type, min, max, ...)
#    meta        text field nested under "metadata" (key like meta_<name>)
# ============================================================

SCHEMAS = {
    # 01 Adjust  ->  preset_NN_*.json
    "01": [
        {"kind": "adjust", "type": "Brightness", "min": -1.0, "max": 1.0,
         "step": 0.05, "default": 0.2, "on": True},
        {"kind": "adjust", "type": "Contrast",   "min": 0.0,  "max": 4.0,
         "step": 0.05, "default": 1.2, "on": True},
        {"kind": "adjust", "type": "Saturation", "min": 0.0,  "max": 4.0,
         "step": 0.05, "default": 1.3, "on": True},
        {"kind": "choice", "key": "outputFormat", "label": "Output format",
         "values": ["original", "jpg", "png"], "default": "original"},
        {"kind": "slider", "key": "jpegQuality", "label": "JPEG quality",
         "min": 1, "max": 100, "step": 1, "default": 95},
        {"kind": "radio", "key": "processing", "label": "Processing mode",
         "values": ["parallel", "sequential"],
         "labels": ["Parallel (fast - uses all CPU cores)",
                    "Sequential (original - one image at a time)"],
         "default": "parallel"},
        {"kind": "radio", "key": "inputSource", "label": "Input source",
         "values": ["folder", "batch"],
         "labels": ["This folder (adjust the Work folder's images)",
                    "Batch: each subfolder -> its own adjusted_ folder"],
         "default": "folder"},
    ],
    # 02 Smart Crop  ->  sc_preset_NN_*.json
    "02": [
        {"kind": "radio", "key": "inputSource", "label": "Input source",
         "values": ["folder", "batch"],
         "labels": ["This folder (crop the Work folder's images)",
                    "Batch: each subfolder -> its own cropped_ folder"],
         "default": "folder"},
        {"kind": "choice", "key": "step",
         "label": "Step (crop first, fix by hand, then canvas)",
         "values": ["crop", "canvas", "crop + canvas"], "default": "crop"},
        {"kind": "slider", "key": "cropAllowance",
         "label": "Crop allowance (px kept around page edge)",
         "min": 0, "max": 50, "step": 1, "default": 2},
        {"kind": "choice", "key": "fitMode", "label": "Uniform size mode",
         "values": ["pad-to-largest", "scale-to-height", "per-page"],
         "default": "pad-to-largest"},
        {"kind": "slider", "key": "canvasWidth",
         "label": "Fixed canvas width px (0 = auto from largest)",
         "min": 0, "max": 12000, "step": 10, "default": 0},
        {"kind": "slider", "key": "canvasHeight",
         "label": "Fixed canvas height px (0 = auto from largest)",
         "min": 0, "max": 12000, "step": 10, "default": 0},
        {"kind": "slider", "key": "padding",
         "label": "Margin / white border (px, auto-canvas only)",
         "min": 0, "max": 200, "step": 1, "default": 10},
        {"kind": "choice", "key": "rotate",
         "label": "Rotate (only if scanned sideways; OSD may misfire)",
         "values": ["none", "90cw", "90ccw", "180", "auto-osd"],
         "default": "none"},
        {"kind": "slider", "key": "targetHeight",
         "label": "Target height (scale-to-height mode; 0=auto median)",
         "min": 0, "max": 5000, "step": 50, "default": 0},
        {"kind": "choice", "key": "enhance", "label": "Enhance",
         "values": ["none", "auto", "strong"], "default": "auto"},
        {"kind": "choice", "key": "canvasBg",
         "label": "Padding colour",
         "values": ["white", "black", "sampled"], "default": "white"},
        {"kind": "choice", "key": "outputFormat", "label": "Output format",
         "values": ["jpg", "png"], "default": "jpg"},
        {"kind": "slider", "key": "jpegQuality", "label": "JPEG quality",
         "min": 1, "max": 100, "step": 1, "default": 85},
    ],
    # 03 Images -> PDF  ->  i2p_preset_NN_*.json
    "03": [
        {"kind": "radio", "key": "inputSource", "label": "Input source",
         "values": ["folder", "batch"],
         "labels": ["This folder (one PDF from the Work folder's images)",
                    "Batch: each subfolder -> its own <folder>.pdf"],
         "default": "folder"},
        {"kind": "choice", "key": "pageSizeMode", "label": "Page size mode",
         "values": ["fit-to-image", "fixed"], "default": "fit-to-image"},
        {"kind": "choice", "key": "fixedPageSize",
         "label": "Fixed page size (used when mode = fixed)",
         "values": ["A4", "A5", "Letter", "Legal", "B5"], "default": "A4"},
        {"kind": "choice", "key": "fixedOrientation", "label": "Orientation",
         "values": ["portrait", "landscape"], "default": "portrait"},
        {"kind": "slider", "key": "dpi", "label": "DPI",
         "min": 72, "max": 2400, "step": 1, "default": 300},
        {"kind": "radio", "key": "sortOrder", "label": "Page / sort order",
         "values": ["name-asc", "name-desc", "date-asc", "date-desc"],
         "labels": ["Name A->Z (ascending - normal)",
                    "Name Z->A (descending)",
                    "Date oldest first", "Date newest first"],
         "default": "name-asc"},
        {"kind": "text", "key": "outputFilename",
         "label": "Output filename (blank = auto)", "default": ""},
    ],
    # 04 OCR  ->  ocr_preset_NN_*.json
    "04": [
        {"kind": "file", "key": "inputFile",
         "label": "Single PDF (optional - blank = newest PDF in folder)", "default": "",
         "filter": [("PDF files", "*.pdf"), ("All files", "*.*")]},
        {"kind": "multichoice", "key": "languages", "label": "Languages",
         "values": OCR_LANGS, "default": ["tam", "eng"]},
        {"kind": "slider", "key": "optimizeLevel", "label": "Optimize level",
         "min": 0, "max": 3, "step": 1, "default": 1},
        {"kind": "toggle", "key": "skipText",
         "label": "Skip pages that already have text", "default": True},
        {"kind": "toggle", "key": "deskew",
         "label": "Deskew (straighten crooked pages)", "default": True},
        {"kind": "toggle", "key": "cleanFinal",
         "label": "Clean final (unpaper, included in output)", "default": False},
        {"kind": "toggle", "key": "pdfaGeneration",
         "label": "Generate PDF/A", "default": True},
        {"kind": "text", "key": "outputSuffix", "label": "Output suffix",
         "default": "_ocr"},
        {"kind": "meta", "key": "meta_title",    "label": "Title",    "default": ""},
        {"kind": "meta", "key": "meta_author",   "label": "Author",   "default": ""},
        {"kind": "meta", "key": "meta_subject",  "label": "Subject",  "default": ""},
        {"kind": "meta", "key": "meta_language", "label": "Metadata language",
         "default": "ta"},
    ],
    # 05 EasyOCR (Sanskrit/Devanagari)  ->  eocr_preset_NN_*.json
    "05": [
        {"kind": "radio", "key": "inputSource", "label": "Input source",
         "values": ["images", "batch", "pdf"],
         "labels": ["Images folder (use the Work folder images - fast)",
                    "Batch: each subfolder -> its own <folder>_searchable.pdf",
                    "PDF file (rasterize the file below - slower)"],
         "default": "images"},
        {"kind": "file", "key": "inputFile",
         "label": "PDF / image file (only used when source = PDF)", "default": "",
         "filter": [("Images & PDFs", "*.jpg *.jpeg *.png *.bmp *.tif *.tiff *.webp *.pdf"),
                    ("All files", "*.*")]},
        {"kind": "choice", "key": "language", "label": "Language (EasyOCR code)",
         "values": ["hi", "hi,en", "mr", "ne", "en"], "default": "hi"},
        {"kind": "toggle", "key": "useGpu",
         "label": "Use GPU (needs CUDA PyTorch; falls back to CPU)", "default": True},
        {"kind": "toggle", "key": "searchablePdf",
         "label": "Make combined searchable PDF (image + invisible text)",
         "default": True},
        {"kind": "text", "key": "pdfFilename",
         "label": "Searchable PDF filename", "default": "searchable.pdf"},
        {"kind": "choice", "key": "pdfMaxDim",
         "label": "Max page resolution px (main size control; 0 = original)",
         "values": ["1600", "2000", "2600", "3500", "0"], "default": "2000"},
        {"kind": "slider", "key": "pdfQuality",
         "label": "PDF image quality (lower = smaller)",
         "min": 30, "max": 95, "step": 5, "default": 55},
        {"kind": "choice", "key": "pdfPageDpi",
         "label": "Page DPI (page physical size)",
         "values": ["96", "120", "150", "200"], "default": "150"},
        {"kind": "choice", "key": "ocrDpi",
         "label": "OCR scan DPI (higher = sharper text, slower)",
         "values": ["200", "300", "400"], "default": "300"},
        {"kind": "toggle", "key": "pdfa",
         "label": "Also make PDF/A (archival; needs Ghostscript)", "default": False},
        {"kind": "choice", "key": "outputMode", "label": "Also write .txt",
         "values": ["none", "per-page", "combined", "both"], "default": "none"},
        {"kind": "toggle", "key": "paragraph",
         "label": "Group words into paragraphs", "default": False},
        {"kind": "toggle", "key": "skipExisting",
         "label": "Skip .txt if it already exists (.txt mode only)", "default": True},
        {"kind": "choice", "key": "sortOrder", "label": "Page order",
         "values": ["name-asc", "name-desc", "date-asc", "date-desc"],
         "default": "name-asc"},
        {"kind": "text", "key": "outputSuffix",
         "label": "Per-page .txt suffix (blank = <name>.txt)", "default": ""},
    ],
}

def detect_gpus():
    """Return [(index, "Name (memGB)", mem_MiB), ...] from nvidia-smi, or []."""
    try:
        out = subprocess.run(
            ["nvidia-smi", "--query-gpu=index,name,memory.total",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=8).stdout
        gpus = []
        for line in out.strip().splitlines():
            parts = [x.strip() for x in line.split(",")]
            if len(parts) >= 3 and parts[2].isdigit():
                idx, name, mem = parts[0], parts[1], int(parts[2])
                gpus.append((idx, f"{name} ({mem / 1024:.0f} GB)", mem))
        return gpus
    except Exception:
        return []

# Build the GPU multi-select for stage 05 from the machine's actual GPUs.
_DETECTED_GPUS = detect_gpus()
if _DETECTED_GPUS:
    _best_gpu = max(_DETECTED_GPUS, key=lambda g: g[2])[0]   # highest-memory index
    SCHEMAS["05"].insert(3, {
        "kind": "multichoice", "key": "gpuDevices", "label": "GPU(s) to use",
        "values": [(g[0], g[1]) for g in _DETECTED_GPUS],
        "default": [_best_gpu],
    })

def safe_desc(desc):
    """Sanitize a description into a filename-safe slug."""
    slug = re.sub(r"[^A-Za-z0-9]+", "_", (desc or "").strip().lower()).strip("_")
    return slug or "preset"

def next_preset_number(prefix):
    """Next NN for <prefix>NN_<slug>.json, mirroring the pipeline scripts."""
    highest = 0
    for bare, _ in list_presets(prefix):
        m = re.match(re.escape(prefix) + r"(\d+)", bare)
        if m:
            highest = max(highest, int(m.group(1)))
    return highest + 1

# ============================================================
#  Preview helpers  (apply a stage's processing to one image)
# ============================================================

_STAGE_MODULES = {}   # bat filename -> imported module (cached)

def stage_module(bat_name):
    """Import the Python embedded in a stage .bat so we can reuse its exact
    functions for a live preview (no logic duplication)."""
    if bat_name in _STAGE_MODULES:
        return _STAGE_MODULES[bat_name]
    import types
    path = os.path.join(ROOT, bat_name)
    lines = open(path, encoding="utf-8").read().splitlines()
    src = "\n".join(lines[lines.index("#PY_BEGIN") + 1:])
    mod = types.ModuleType("stage_" + re.sub(r"\W", "_", bat_name))
    mod.__file__ = path
    # __name__ != '__main__', so the script's main() guard won't fire on import.
    exec(compile(src, path, "exec"), mod.__dict__)
    _STAGE_MODULES[bat_name] = mod
    return mod

def apply_adjustments(pil_img, adjustments):
    """Replicate stage 01's .NET ColorMatrix math (Brightness/Contrast/
    Saturation) on a PIL image, clamping after each step like the real
    per-step 8-bit file writes. Returns a new PIL image."""
    import numpy as np
    from PIL import Image
    arr = np.asarray(pil_img.convert("RGB"), dtype=np.float32)
    for adj in adjustments:
        t, v = adj.get("Type"), float(adj.get("Value", 0))
        if t == "Brightness":
            arr = arr + v * 255.0
        elif t == "Contrast":
            c = max(0.0, v)
            arr = c * arr + (1.0 - c) / 2.0 * 255.0
        elif t == "Saturation":
            s = max(0.0, v)
            rw, gw, bw = 0.2126, 0.7152, 0.0722
            R, G, B = arr[..., 0], arr[..., 1], arr[..., 2]
            rr, rg = rw + (1 - rw) * s, rw * (1 - s)
            gg, gr = gw + (1 - gw) * s, gw * (1 - s)
            bb, br = bw + (1 - bw) * s, bw * (1 - s)
            arr = np.stack([
                R * rr + G * gr + B * br,
                R * rg + G * gg + B * br,
                R * rg + G * gr + B * bb,
            ], axis=-1)
        arr = np.clip(arr, 0, 255)
    return Image.fromarray(arr.astype(np.uint8), "RGB")

# ============================================================
#  Theme  -  modern dark, single source of truth
# ============================================================

THEME = {
    "bg":         "#EFEBE2",   # warm off-white canvas (paper)
    "panel":      "#FBF9F4",   # cards / panels (near white)
    "panel_hi":   "#E7E1D4",   # header / hover (clearly darker than panel)
    "border":     "#D6CFBE",
    "text":       "#2B2A28",   # warm near-black
    "text_dim":   "#6E665B",
    "text_mute":  "#9C9384",
    "accent":     "#3A7CA5",   # calm blue
    "ok":         "#2E8B57",
    "warn":       "#B7791F",
    "err":        "#C0392B",
    "shadow":     "#000000",
    "btn":        "#E4DECF",   # light button
    "btn_hi":     "#D6CEBB",   # button hover
    "btn_run":    "#3C9A5F",   # green run button
    "btn_run_hi": "#46AE6C",
    "slider_trough": "#A9C5D6",  # visible groove behind the slider knob
    "slider_knob":   "#3A7CA5",  # slider knob (accent) for contrast
}

FONT_HEAD  = ("Segoe UI", 18, "bold")
FONT_SUB   = ("Segoe UI", 10)
FONT_CARD  = ("Segoe UI", 12, "bold")
FONT_TAG   = ("Segoe UI", 9)
FONT_BODY  = ("Segoe UI", 10)
FONT_MONO  = ("Consolas", 9)
FONT_BTN   = ("Segoe UI", 10, "bold")

# ============================================================
#  Helpers
# ============================================================

def load_json(path, default=None):
    # utf-8-sig so presets written by PowerShell (which prepend a BOM) load too.
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            return json.load(f)
    except Exception:
        return default if default is not None else {}

def save_json(path, data):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)

def list_presets(prefix):
    """Return list of (display_name, full_path) for preset files."""
    out = []
    for fn in sorted(os.listdir(PRESETS)):
        if not fn.startswith(prefix) or not fn.endswith(".json"):
            continue
        # Skip presets that would match a longer prefix as well.
        # (e.g. preset_  must not gobble  sc_preset_  /  i2p_preset_  / ocr_preset_)
        bare = fn[:-5]   # strip .json
        if prefix == "preset_":
            if any(bare.startswith(p) for p in
                   ("sc_preset_", "i2p_preset_", "ocr_preset_", "eocr_preset_")):
                continue
        out.append((bare, os.path.join(PRESETS, fn)))
    return out

def count_images(folder):
    if not folder or not os.path.isdir(folder):
        return 0
    exts = (".jpg", ".jpeg", ".png", ".bmp", ".tif", ".tiff")
    n = 0
    try:
        for fn in os.listdir(folder):
            if fn.lower().endswith(exts):
                n += 1
    except Exception:
        pass
    return n

def count_pdfs(folder):
    if not folder or not os.path.isdir(folder):
        return 0
    n = 0
    try:
        for fn in os.listdir(folder):
            if fn.lower().endswith(".pdf"):
                n += 1
    except Exception:
        pass
    return n

def open_in_explorer(path):
    if not path:
        return
    if os.path.isfile(path):
        subprocess.Popen(["explorer", "/select,", path])
    elif os.path.isdir(path):
        subprocess.Popen(["explorer", path])

def run_bat(bat_path):
    """Open the .bat in its own console window (preserves its menus)."""
    if not os.path.isfile(bat_path):
        messagebox.showerror("Missing script", f"Cannot find:\n{bat_path}")
        return False
    subprocess.Popen(
        ["cmd", "/c", "start", "", "cmd", "/k", bat_path],
        cwd=ROOT,
        shell=False,
    )
    return True

# ============================================================
#  Dependency probe
# ============================================================

def probe_deps():
    """Returns dict { name: (ok: bool, detail: str) }."""
    res = {}
    # Python
    res["Python"] = (True, sys.version.split()[0])
    # Pip packages
    for mod, label in [
        ("cv2",     "opencv"),
        ("numpy",   "numpy"),
        ("img2pdf", "img2pdf"),
        ("PIL",     "Pillow"),
        ("ocrmypdf","ocrmypdf"),
    ]:
        try:
            m = __import__(mod)
            ver = getattr(m, "__version__", "")
            res[label] = (True, ver)
        except Exception:
            res[label] = (False, "missing")
    # Tesseract
    try:
        out = subprocess.run(["tesseract", "--version"],
                             capture_output=True, text=True, timeout=5)
        first = (out.stdout or out.stderr).splitlines()[0].strip()
        # Languages
        try:
            langs_out = subprocess.run(["tesseract", "--list-langs"],
                                       capture_output=True, text=True, timeout=5)
            langs = [l.strip() for l in langs_out.stdout.splitlines()[1:] if l.strip()]
            key = [l for l in ("tam", "hin", "san", "eng") if l in langs]
            res["Tesseract"] = (True, f"{first}  ({len(langs)} langs: {', '.join(key)})")
        except Exception:
            res["Tesseract"] = (True, first)
    except Exception:
        res["Tesseract"] = (False, "not installed")
    # Ghostscript (optional). A broken install (e.g. error 0xc0000142 / missing
    # VC++ runtime) returns a non-zero exit code rather than raising, so require
    # returncode 0 AND a version string - otherwise report it as broken.
    res["Ghostscript"] = (False, "not installed (optional)")
    for cmd in ("gswin64c", "gswin32c"):
        try:
            out = subprocess.run([cmd, "--version"],
                                 capture_output=True, text=True, timeout=5)
            ver = (out.stdout or "").strip()
            if out.returncode == 0 and ver:
                res["Ghostscript"] = (True, f"{cmd} {ver} (optional)")
                break
            else:
                res["Ghostscript"] = (
                    False, f"{cmd} found but failed to run (broken install; "
                           f"reinstall Ghostscript) (optional)")
        except Exception:
            continue
    return res

# ============================================================
#  Tk UI building blocks
# ============================================================

class CollapsibleSection(tk.Frame):
    """Generic expand/collapse section with a clickable header and a .body."""

    def __init__(self, master, app, title, expanded=True):
        super().__init__(master, bg=THEME["bg"])
        self.app = app
        self._expanded = expanded
        outer = tk.Frame(self, bg=THEME["border"])
        outer.pack(fill="x", pady=4)
        inner = tk.Frame(outer, bg=THEME["panel"])
        inner.pack(fill="x", padx=1, pady=1)

        self.header = tk.Frame(inner, bg=THEME["panel_hi"], cursor="hand2")
        self.header.pack(fill="x")
        self.chevron = tk.Label(self.header, text="▼" if expanded else "▶",
                                bg=THEME["panel_hi"], fg=THEME["text_dim"],
                                font=("Segoe UI", 11), width=2)
        self.chevron.pack(side="left", padx=(8, 0), pady=8)
        tk.Label(self.header, text=title, bg=THEME["panel_hi"], fg=THEME["text"],
                 font=FONT_CARD).pack(side="left")
        for w in [self.header, self.chevron] + list(self.header.winfo_children()):
            w.bind("<Button-1>", lambda e: self.toggle())

        self.body = tk.Frame(inner, bg=THEME["panel"])
        if expanded:
            self.body.pack(fill="both", expand=True)

    def toggle(self):
        self._expanded = not self._expanded
        if self._expanded:
            self.body.pack(fill="both", expand=True)
            self.chevron.config(text="▼")
        else:
            self.body.pack_forget()
            self.chevron.config(text="▶")
        self.app._refresh_panel_scroll()


class StagePanel(tk.Frame):
    """Collapsible inline panel: preset picker + live settings + Run.

    Replaces the old pop-up editor. Each stage owns one of these; the
    header toggles the body, the body holds the schema-driven controls,
    and Save / Save & Run write a preset the console scripts can read.
    """

    def __init__(self, master, app, stage):
        super().__init__(master, bg=THEME["bg"])
        self.app = app
        self.stage = stage
        self.schema = SCHEMAS.get(stage["id"], [])
        self.preset_var = tk.StringVar(value="(none)")
        self.desc_var   = tk.StringVar(value="")
        self.info_var   = tk.StringVar(value="")
        # Every module has its own Work folder field. OCR stages (04/05/06)
        # additionally have a single-file picker (defined in their schema).
        self.file_based = any(f.get("kind") == "file" for f in self.schema)
        self.has_folder = True
        self.folder_var = tk.StringVar(value=app.folder_var.get())
        self.vars = {}            # key -> tk var (or dict for multichoice)
        self.value_labels = {}    # key -> (Label, is_float)
        self.choice_maps = {}     # key -> (label->value, value->label) for choices
        self.path = None          # current preset file (None => unsaved/new)
        self.presets = []
        self._expanded = False
        self._build()
        self.refresh_presets()
        want = self.app.history.get("expanded", {}).get(stage["id"], False)
        self._set_expanded(bool(want))

    # ---------- build ----------
    def _build(self):
        s = self.stage
        outer = tk.Frame(self, bg=THEME["border"])
        outer.pack(fill="x", pady=4)
        inner = tk.Frame(outer, bg=THEME["panel"])
        inner.pack(fill="x", padx=1, pady=1)

        # header (click anywhere to toggle)
        self.header = tk.Frame(inner, bg=THEME["panel_hi"], cursor="hand2")
        self.header.pack(fill="x")
        tk.Frame(self.header, bg=s["color"], width=4).pack(side="left", fill="y")
        self.chevron = tk.Label(self.header, text="▶", bg=THEME["panel_hi"],
                                fg=THEME["text_dim"], font=("Segoe UI", 11), width=2)
        self.chevron.pack(side="left", padx=(8, 0), pady=8)
        tk.Label(self.header, text=s["icon"], bg=THEME["panel_hi"],
                 fg=s["color"], font=("Consolas", 11, "bold")).pack(side="left")
        tk.Label(self.header, text=s["title"], bg=THEME["panel_hi"],
                 fg=THEME["text"], font=FONT_CARD).pack(side="left", padx=(8, 0))
        tk.Label(self.header, text=s["tag"], bg=THEME["panel_hi"],
                 fg=THEME["text_dim"], font=FONT_TAG).pack(side="left", padx=(12, 0))
        self.status_dot = tk.Label(self.header, text="⬤", fg=THEME["text_mute"],
                                   bg=THEME["panel_hi"], font=("Segoe UI", 11))
        self.status_dot.pack(side="right", padx=12)
        tk.Label(self.header, textvariable=self.preset_var, bg=THEME["panel_hi"],
                 fg=THEME["text_dim"], font=FONT_TAG).pack(side="right", padx=(0, 8))
        for w in list(self.header.winfo_children()):
            w.bind("<Button-1>", lambda e: self.toggle())
        self.header.bind("<Button-1>", lambda e: self.toggle())

        # body (hidden when collapsed)
        self.body = tk.Frame(inner, bg=THEME["panel"])

        # Line 1: Preset [combo]   Name [entry]
        prow = tk.Frame(self.body, bg=THEME["panel"])
        prow.pack(fill="x", padx=12, pady=(10, 2))
        prow.columnconfigure(1, weight=1)
        prow.columnconfigure(3, weight=1)
        tk.Label(prow, text="Preset", bg=THEME["panel"], fg=THEME["text_dim"],
                 font=FONT_BODY, anchor="w").grid(row=0, column=0, sticky="w")
        self.preset_combo = ttk.Combobox(prow, textvariable=self.preset_var,
                                          state="readonly", font=FONT_BODY, height=12)
        self.preset_combo.grid(row=0, column=1, sticky="ew", padx=(6, 10))
        self.preset_combo.bind("<<ComboboxSelected>>", self._on_preset_change)
        tk.Label(prow, text="Name", bg=THEME["panel"], fg=THEME["text_dim"],
                 font=FONT_BODY, anchor="w").grid(row=0, column=2, sticky="w")
        tk.Entry(prow, textvariable=self.desc_var, bg=THEME["btn"], fg=THEME["text"],
                 insertbackground=THEME["text"], relief="flat",
                 font=FONT_BODY).grid(row=0, column=3, sticky="ew", padx=(6, 0), ipady=2)

        # Line 2: preset management, grouped with the preset
        prow2 = tk.Frame(self.body, bg=THEME["panel"])
        prow2.pack(fill="x", padx=12, pady=(0, 6))
        for txt, cmd in (("Save", self._save),
                         ("Save As", self._save_as),
                         ("Reset", lambda: self._load_values({}))):
            tk.Button(prow2, text=txt, font=FONT_BTN, bg=THEME["btn"], fg=THEME["text"],
                      activebackground=THEME["btn_hi"], activeforeground=THEME["text"],
                      bd=0, relief="flat", padx=12, pady=5, cursor="hand2",
                      command=cmd).pack(side="left", padx=(0, 6))
        tk.Button(prow2, text="JSON", font=FONT_BTN, bg=THEME["btn"],
                  fg=THEME["text_dim"], activebackground=THEME["btn_hi"],
                  activeforeground=THEME["text"], bd=0, relief="flat",
                  padx=10, pady=5, cursor="hand2",
                  command=self._edit_raw).pack(side="right")

        # Work folder field (every module)
        if self.has_folder:
            frow = tk.Frame(self.body, bg=THEME["panel"])
            frow.pack(fill="x", padx=12, pady=(2, 4))
            tk.Label(frow, text="Work folder", bg=THEME["panel"], fg=THEME["text_dim"],
                     font=FONT_BODY, width=10, anchor="w").pack(side="left")
            tk.Entry(frow, textvariable=self.folder_var, bg=THEME["btn"],
                     fg=THEME["text"], insertbackground=THEME["text"], relief="flat",
                     font=FONT_BODY).pack(side="left", fill="x", expand=True,
                                          ipady=3, padx=(0, 6))
            tk.Button(frow, text="Browse...", font=FONT_BTN, bg=THEME["btn"],
                      fg=THEME["text"], activebackground=THEME["btn_hi"],
                      activeforeground=THEME["text"], bd=0, relief="flat",
                      padx=10, pady=2, cursor="hand2",
                      command=self._browse_folder).pack(side="left")

        ttk.Separator(self.body, orient="horizontal").pack(fill="x", padx=12, pady=(6, 4))
        fields = tk.Frame(self.body, bg=THEME["panel"])
        fields.pack(fill="x", padx=4)
        for f in self.schema:
            self._build_field(fields, f)

        # optional stage-specific reference links (e.g. Sanskrit OCR projects)
        res = self.stage.get("resources")
        if res:
            ttk.Separator(self.body, orient="horizontal").pack(
                fill="x", padx=12, pady=(8, 4))
            rblock = tk.Frame(self.body, bg=THEME["panel"])
            rblock.pack(fill="x", padx=12)
            tk.Label(rblock, text="Resources & notes", bg=THEME["panel"],
                     fg=THEME["text_dim"], font=("Segoe UI", 9, "bold")
                     ).pack(anchor="w")
            for label, url in res:
                if url:
                    lnk = tk.Label(rblock, text="• " + label, bg=THEME["panel"],
                                   fg=THEME["accent"],
                                   font=("Segoe UI", 9, "underline"), cursor="hand2")
                    lnk.pack(anchor="w")
                    lnk.bind("<Button-1>", lambda e, u=url: webbrowser.open(u))
                else:
                    tk.Label(rblock, text="• " + label, bg=THEME["panel"],
                             fg=THEME["text_mute"], font=("Segoe UI", 9)
                             ).pack(anchor="w")

        # Action row: the primary Run, plus Preview / Advanced
        arow = tk.Frame(self.body, bg=THEME["panel"])
        arow.pack(fill="x", padx=12, pady=(10, 4))
        self.btn_run = tk.Button(arow, text="▶  Save & Run",
                                 font=("Segoe UI", 11, "bold"),
                                 bg=THEME["btn_run"], fg="white",
                                 activebackground=THEME["btn_run_hi"],
                                 activeforeground="white", bd=0, relief="flat",
                                 padx=16, pady=7, cursor="hand2", command=self._run)
        self.btn_run.pack(side="left")
        # Live preview (Adjust + Smart Crop only)
        if self.stage["id"] in ("01", "02"):
            tk.Button(arow, text="Preview", font=FONT_BTN, bg=THEME["btn"],
                      fg=THEME["text"], activebackground=THEME["btn_hi"],
                      activeforeground=THEME["text"], bd=0, relief="flat",
                      padx=12, pady=7, cursor="hand2",
                      command=self._preview).pack(side="left", padx=(8, 0))
        for label, methodname in self.stage.get("extras", []):
            cb = getattr(self.app, methodname, None)
            if cb:
                tk.Button(arow, text=label, font=FONT_BTN, bg=THEME["btn"],
                          fg=THEME["text"], activebackground=THEME["btn_hi"],
                          activeforeground=THEME["text"], bd=0, relief="flat",
                          padx=10, pady=7, cursor="hand2",
                          command=cb).pack(side="left", padx=(8, 0))

        tk.Label(self.body, textvariable=self.info_var, bg=THEME["panel"],
                 fg=THEME["text_mute"], font=("Segoe UI", 8)
                 ).pack(anchor="w", padx=12, pady=(0, 10))

    # ---------- collapse ----------
    def toggle(self):
        self._set_expanded(not self._expanded)

    def _set_expanded(self, on):
        self._expanded = on
        if on:
            self.body.pack(fill="x")
            self.chevron.config(text="▼")
        else:
            self.body.pack_forget()
            self.chevron.config(text="▶")
        self.app.history.setdefault("expanded", {})[self.stage["id"]] = on
        self.app.save_history()
        self.app._refresh_panel_scroll()

    # ---------- field rendering ----------
    def _build_field(self, parent, f):
        kind = f["kind"]
        row = tk.Frame(parent, bg=THEME["panel"])
        row.pack(fill="x", padx=8, pady=4)

        if kind in ("slider", "adjust"):
            is_float = (f.get("step", 1) != int(f.get("step", 1))) \
                       or isinstance(f.get("default"), float)
            if kind == "slider":
                f["float"] = is_float
            label = f.get("label", f.get("type", ""))
            # Single compact line:  [label / checkbox]  [slider ....]  [value]
            if kind == "adjust":
                onvar = tk.BooleanVar(value=f.get("on", True))
                self.vars[f"adj_on_{f['type']}"] = onvar
                tk.Checkbutton(row, text=label, variable=onvar, width=11,
                               bg=THEME["panel"], fg=THEME["text"],
                               activebackground=THEME["panel"],
                               activeforeground=THEME["text"],
                               selectcolor=THEME["bg"], bd=0, font=FONT_BODY,
                               anchor="w").pack(side="left")
                var = tk.DoubleVar(value=f["default"])
                self.vars[f"adj_val_{f['type']}"] = var
                vlabel_key = f"adj_val_{f['type']}"
            else:
                tk.Label(row, text=label, bg=THEME["panel"], fg=THEME["text"],
                         font=FONT_BODY, width=14, anchor="w").pack(side="left")
                var = (tk.DoubleVar if is_float else tk.IntVar)(value=f["default"])
                self.vars[f["key"]] = var
                vlabel_key = f["key"]
            vlabel = tk.Label(row, text="", bg=THEME["panel"], fg=THEME["accent"],
                              font=("Consolas", 10, "bold"), width=6, anchor="e")
            vlabel.pack(side="right")
            self.value_labels[vlabel_key] = (vlabel, is_float)
            scale = tk.Scale(row, from_=f["min"], to=f["max"],
                             resolution=f.get("step", 1), orient="horizontal",
                             variable=var, showvalue=False,
                             bg=THEME["panel"], fg=THEME["text"],
                             troughcolor=THEME["slider_trough"],
                             highlightthickness=0, bd=1, relief="flat",
                             sliderrelief="raised", sliderlength=20, width=12,
                             activebackground=THEME["accent"])
            scale.pack(side="left", fill="x", expand=True, padx=(8, 6))
            var.trace_add("write", lambda *_: self._sync_slider_labels())

        elif kind == "toggle":
            var = tk.BooleanVar(value=f["default"])
            self.vars[f["key"]] = var
            tk.Checkbutton(row, text=f["label"], variable=var,
                           bg=THEME["panel"], fg=THEME["text"],
                           activebackground=THEME["panel"],
                           activeforeground=THEME["text"],
                           selectcolor=THEME["bg"], bd=0, font=FONT_BODY,
                           anchor="w").pack(anchor="w")

        elif kind == "choice":
            tk.Label(row, text=f["label"], bg=THEME["panel"], fg=THEME["text"],
                     font=FONT_BODY, anchor="w").pack(anchor="w")
            # Optional friendly labels (display) mapped to the saved values.
            labels = f.get("labels") or list(f["values"])
            lab2val = dict(zip(labels, f["values"]))
            val2lab = dict(zip(f["values"], labels))
            self.choice_maps[f["key"]] = (lab2val, val2lab)
            var = tk.StringVar(value=val2lab.get(f["default"], f["default"]))
            self.vars[f["key"]] = var
            cb = ttk.Combobox(row, textvariable=var, state="readonly",
                              values=labels, font=FONT_BODY)
            cb.pack(fill="x", pady=(2, 0))
            # Don't let the mouse wheel change the selection while the user is
            # just scrolling the panel - it scrolls the panel instead.
            cb.bind("<MouseWheel>", lambda e: "break")
            cb.bind("<Button-4>", lambda e: "break")
            cb.bind("<Button-5>", lambda e: "break")

        elif kind == "radio":
            tk.Label(row, text=f["label"], bg=THEME["panel"], fg=THEME["text"],
                     font=FONT_BODY, anchor="w").pack(anchor="w")
            # Radio stores the saved VALUE directly; the friendly label is the
            # button text. No wheel hijack, all options visible at once.
            labels = f.get("labels") or list(f["values"])
            var = tk.StringVar(value=f["default"])
            self.vars[f["key"]] = var
            rframe = tk.Frame(row, bg=THEME["panel"])
            rframe.pack(fill="x", pady=(2, 0))
            for val, lab in zip(f["values"], labels):
                tk.Radiobutton(rframe, text=lab, value=val, variable=var,
                               bg=THEME["panel"], fg=THEME["text"],
                               activebackground=THEME["panel"],
                               activeforeground=THEME["text"],
                               selectcolor=THEME["bg"], bd=0, font=FONT_BODY,
                               anchor="w").pack(anchor="w")

        elif kind == "multichoice":
            tk.Label(row, text=f["label"], bg=THEME["panel"], fg=THEME["text"],
                     font=FONT_BODY, anchor="w").pack(anchor="w")
            grid = tk.Frame(row, bg=THEME["panel"])
            grid.pack(fill="x", pady=(2, 0))
            self.vars[f["key"]] = {}
            for i, (code, name) in enumerate(f["values"]):
                bv = tk.BooleanVar(value=code in f["default"])
                self.vars[f["key"]][code] = bv
                tk.Checkbutton(grid, text=f"{name} ({code})", variable=bv,
                               bg=THEME["panel"], fg=THEME["text"],
                               activebackground=THEME["panel"],
                               activeforeground=THEME["text"],
                               selectcolor=THEME["bg"], bd=0, font=FONT_BODY,
                               anchor="w").grid(row=i // 2, column=i % 2, sticky="w")

        else:  # text / meta / file
            if kind == "file":
                tk.Label(row, text=f["label"], bg=THEME["panel"], fg=THEME["text"],
                         font=FONT_BODY, anchor="w").pack(anchor="w")
                entry_frame = tk.Frame(row, bg=THEME["panel"])
                entry_frame.pack(fill="x")
                var = tk.StringVar(value=f.get("default", ""))
                self.vars[f["key"]] = var
                entry = tk.Entry(entry_frame, textvariable=var, bg=THEME["btn"],
                                 fg=THEME["text"], insertbackground=THEME["text"],
                                 relief="flat", font=FONT_BODY)
                entry.pack(side="left", fill="x", expand=True, ipady=3, padx=(0, 6))
                flt = f.get("filter", [("All files", "*.*")])
                tk.Button(entry_frame, text="Browse...", font=FONT_BTN,
                          bg=THEME["btn"], fg=THEME["text"],
                          activebackground=THEME["btn_hi"],
                          activeforeground=THEME["text"],
                          bd=0, relief="flat", padx=10, pady=2, cursor="hand2",
                          command=lambda v=var, ft=flt: self._browse_file(v, ft)
                          ).pack(side="left")
            else:
                tk.Label(row, text=f["label"], bg=THEME["panel"], fg=THEME["text"],
                         font=FONT_BODY, anchor="w").pack(anchor="w")
                var = tk.StringVar(value=f["default"])
                self.vars[f["key"]] = var
                tk.Entry(row, textvariable=var, bg=THEME["btn"], fg=THEME["text"],
                         insertbackground=THEME["text"], relief="flat",
                         font=FONT_BODY).pack(fill="x", ipady=3, pady=(2, 0))

    def _sync_slider_labels(self):
        for key, (lbl, is_float) in self.value_labels.items():
            try:
                v = self.vars[key].get()
            except Exception:
                continue
            lbl.config(text=(f"{v:.2f}" if is_float else f"{int(round(v))}"))

    # ---------- value <-> json ----------
    def _load_values(self, data):
        adjustments = {a.get("Type"): a.get("Value")
                       for a in data.get("adjustments", [])} if data else {}
        meta = data.get("metadata", {}) if data else {}
        for f in self.schema:
            kind = f["kind"]
            if kind == "adjust":
                t = f["type"]
                on = t in adjustments if data else f.get("on", True)
                val = adjustments.get(t, f.get("default", 0.0))
                self.vars[f"adj_on_{t}"].set(on)
                self.vars[f"adj_val_{t}"].set(float(val))
            elif kind == "meta":
                name = f["key"][len("meta_"):]
                dflt = f.get("default", "")
                self.vars[f["key"]].set(meta.get(name, dflt) if data else dflt)
            elif kind == "multichoice":
                dflt = f.get("default", [])
                chosen = data.get(f["key"], dflt) if data else dflt
                for code, _ in f["values"]:
                    self.vars[f["key"]][code].set(code in chosen)
            elif kind == "choice":
                dflt = f.get("default", "")
                val = data.get(f["key"], dflt) if data else dflt
                val2lab = self.choice_maps.get(f["key"], ({}, {}))[1]
                self.vars[f["key"]].set(val2lab.get(val, val))   # value -> label
            else:   # slider / toggle / text / file
                dflt = f.get("default", "")
                self.vars[f["key"]].set(data.get(f["key"], dflt) if data else dflt)
        self._sync_slider_labels()

    def _folder(self):
        """The folder this stage works on: its own field if folder-based,
        else the shared working folder (top bar)."""
        return (self.folder_var.get() if self.has_folder
                else self.app.folder_var.get())

    def _collect(self):
        out = {"description": self.desc_var.get().strip() or "untitled",
               "folderPath": self._folder().strip()}
        adjustments, meta = [], {}
        for f in self.schema:
            kind = f["kind"]
            if kind == "adjust":
                t = f["type"]
                if self.vars[f"adj_on_{t}"].get():
                    adjustments.append({"Type": t,
                                        "Value": round(float(self.vars[f"adj_val_{t}"].get()), 3)})
            elif kind == "meta":
                meta[f["key"][len("meta_"):]] = self.vars[f["key"]].get().strip()
            elif kind == "multichoice":
                sel = [code for code, _ in f["values"]
                       if self.vars[f["key"]][code].get()]
                if not sel and f["key"] == "languages":
                    sel = ["eng"]          # OCR needs at least one language
                out[f["key"]] = sel
            elif kind == "slider":
                v = self.vars[f["key"]].get()
                out[f["key"]] = float(round(v, 3)) if f.get("float") else int(round(v))
            elif kind == "toggle":
                out[f["key"]] = bool(self.vars[f["key"]].get())
            elif kind == "choice":
                disp = self.vars[f["key"]].get()
                lab2val = self.choice_maps.get(f["key"], ({}, {}))[0]
                out[f["key"]] = lab2val.get(disp, disp)   # display label -> value
            else:  # text
                out[f["key"]] = self.vars[f["key"]].get()
        if self.stage["id"] == "01":
            out["adjustments"] = adjustments
        if self.stage["id"] == "04":
            out["metadata"] = meta
        return out

    # ---------- presets ----------
    def refresh_presets(self):
        self.presets = list_presets(self.stage["prefix"])
        names = [name for name, _ in self.presets]
        self.preset_combo["values"] = names if names else ["(no presets yet)"]
        cur = self.preset_var.get()
        if cur in names:
            self._on_preset_change()
            return
        hist = self.app.history.get("presets", {}).get(self.stage["id"])
        if hist and hist in names:
            self.preset_var.set(hist)
        elif names:
            self.preset_var.set(names[0])
        else:
            self.preset_var.set("(no presets yet)")
        self._on_preset_change()

    def current_preset_path(self):
        name = self.preset_var.get()
        for n, p in self.presets:
            if n == name:
                return p
        return None

    def _on_preset_change(self, _=None):
        name = self.preset_var.get()
        if name and not name.startswith("("):
            self.app.history.setdefault("presets", {})[self.stage["id"]] = name
            self.app.save_history()
        path = self.current_preset_path()
        self.path = path
        if path and os.path.isfile(path):
            data = load_json(path)
            self.desc_var.set(data.get("description", name))
            if self.has_folder and data.get("folderPath"):
                self.folder_var.set(data["folderPath"])
            self._load_values(data)
            self._update_info()
        else:
            self.desc_var.set("")
            self._load_values({})
            self.info_var.set("(new preset - set values, then Save As New)")

    def _browse_folder(self):
        cur = self.folder_var.get()
        start = cur if os.path.isdir(cur) else (self.app.folder_var.get() or ROOT)
        chosen = filedialog.askdirectory(initialdir=start,
                                         title=f"Folder for {self.stage['title']}")
        if chosen:
            self.folder_var.set(chosen.replace("/", "\\"))
            self._update_info()

    def _update_info(self):
        folder = self._folder()
        short = os.path.basename(folder.rstrip("\\/")) if folder else "(no folder)"
        self.info_var.set(f"{self.desc_var.get()}  -  {short}")

    def _browse_file(self, var, filters):
        cur = var.get()
        wf = self.app.folder_var.get()
        start = os.path.dirname(cur) if cur and os.path.isdir(os.path.dirname(cur)) \
                else wf if os.path.isdir(wf) else ROOT
        chosen = filedialog.askopenfilename(initialdir=start,
                                            filetypes=filters,
                                            title="Pick a file")
        if chosen:
            var.set(chosen.replace("/", "\\"))

    # ---------- save / run ----------
    def _write(self, path, announce=True):
        save_json(path, self._collect())
        self.path = path
        name = os.path.basename(path)[:-5]
        self.presets = list_presets(self.stage["prefix"])
        self.preset_combo["values"] = [n for n, _ in self.presets] or ["(no presets yet)"]
        self.preset_var.set(name)
        self.app.history.setdefault("presets", {})[self.stage["id"]] = name
        self.app.save_history()
        self._update_info()
        if announce:
            self.app.log(f"Saved preset: {os.path.basename(path)}")

    def _save(self):
        if self.path:
            self._write(self.path)
            self.set_status("done")
        else:
            self._save_as()

    def _save_as(self):
        desc = self.desc_var.get().strip()
        if not desc:
            messagebox.showwarning("Name needed", "Enter a preset name first.")
            return False
        prefix = self.stage["prefix"]
        fname = f"{prefix}{next_preset_number(prefix):02d}_{safe_desc(desc)}.json"
        path = os.path.join(PRESETS, fname)
        if os.path.exists(path) and not messagebox.askyesno(
                "Overwrite?", f"{fname} already exists. Overwrite?"):
            return False
        self._write(path)
        self.app.log(f"Created {fname}")
        return True

    def _edit_raw(self):
        if not self.path:
            messagebox.showinfo("Save first",
                                "Save the preset before editing the raw JSON.")
            return
        try:
            os.startfile(self.path)
        except Exception:
            subprocess.Popen(["notepad.exe", self.path])

    def _preview(self):
        try:
            import PIL  # noqa: F401
        except Exception:
            messagebox.showerror("Pillow needed",
                                 "Preview needs Pillow.\n\n"
                                 "Click 'Install / Repair Deps' on the main window.")
            return
        PreviewDialog(self.app, self)
        self.app.log(f"Preview opened for {self.stage['title']}.")

    def _run(self):
        # Persist current settings, then run the stage non-interactively
        # against the working folder (or selected file), with progress in
        # the status bar.
        if self.path:
            self._write(self.path, announce=False)
        elif not self._save_as():
            return
        extra_env = {}
        folder = self.folder_var.get()
        # OCR stages: a picked single file is OPTIONAL (blank = batch the folder).
        if self.file_based:
            v = self.vars.get("inputFile")
            input_file = v.get().strip() if v is not None else ""
            if input_file:
                if not os.path.isfile(input_file):
                    messagebox.showerror("File not found", f"Not a file:\n{input_file}")
                    return
                extra_env["PDF_RUN_INPUT_FILE"] = input_file
        if not os.path.isdir(folder):
            messagebox.showerror("No work folder",
                                 f"Set a valid Work folder for this stage first.\n\n{folder}")
            return
        bat = os.path.join(ROOT, self.stage["bat"])
        if not os.path.isfile(bat):
            messagebox.showerror("Missing script", bat)
            return
        self.app.begin_run(self, folder, bat, extra_env)

    def set_status(self, state):
        colors = {
            "idle":    THEME["text_mute"],
            "running": THEME["warn"],
            "done":    THEME["ok"],
            "err":     THEME["err"],
        }
        self.status_dot.config(fg=colors.get(state, THEME["text_mute"]))


# ============================================================
#  Advanced OCR dialog  (ocrmypdf surface area)
# ============================================================
#  Surfaces ocrmypdf's most useful command-line options without
#  needing to launch 04_OCR-PDF.bat. Runs ocrmypdf as a subprocess
#  inline and streams its stdout/stderr into the dialog's log box.
# ============================================================

class OcrAdvancedDialog(tk.Toplevel):

    def __init__(self, app):
        super().__init__(app)
        self.app = app
        self.title("Advanced OCR  -  ocrmypdf options")
        self.geometry("880x720")
        self.configure(bg=THEME["bg"])
        self.transient(app)

        self.in_path  = tk.StringVar()
        self.out_path = tk.StringVar()
        self.mode     = tk.StringVar(value="skip")    # skip | force | redo
        self.optimize = tk.IntVar(value=1)            # 0..3
        self.output_type = tk.StringVar(value="pdf")  # pdf | pdfa | pdfa-1 | pdfa-2 | pdfa-3
        self.deskew          = tk.BooleanVar(value=False)
        self.rotate_pages    = tk.BooleanVar(value=False)
        self.clean           = tk.BooleanVar(value=False)
        self.clean_final     = tk.BooleanVar(value=False)
        self.remove_bg       = tk.BooleanVar(value=False)
        self.invalidate_sigs = tk.BooleanVar(value=False)
        self.sidecar         = tk.BooleanVar(value=False)
        self.jobs            = tk.IntVar(value=max(1, (os.cpu_count() or 4) // 2))
        self.pages           = tk.StringVar(value="")
        self.title_meta      = tk.StringVar(value="")
        self.author_meta     = tk.StringVar(value="")
        self.subject_meta    = tk.StringVar(value="")
        self.lang_vars = {code: tk.BooleanVar(value=(code in ("tam", "eng")))
                          for code, _ in OCR_LANGS}

        self._proc = None
        self._build()

    def _row(self, parent, label):
        f = ttk.Frame(parent, style="Card.TFrame")
        f.pack(fill="x", pady=2)
        ttk.Label(f, text=label, style="Card.TLabel", width=18,
                  anchor="w").pack(side="left")
        return f

    def _build(self):
        wrap = ttk.Frame(self, style="TFrame", padding=14)
        wrap.pack(fill="both", expand=True)

        # ---- header ----
        head = ttk.Frame(wrap, style="TFrame")
        head.pack(fill="x")
        ttk.Label(head, text="Advanced OCR", style="Header.TLabel").pack(side="left")
        ttk.Label(head, text="   ocrmypdf  -  full option set",
                  style="SubHead.TLabel").pack(side="left")

        # ---- file pickers ----
        files_card = ttk.Frame(wrap, style="Card.TFrame", padding=12)
        files_card.pack(fill="x", pady=(10, 0))
        ttk.Label(files_card, text="FILES", style="Section.TLabel"
                  ).pack(anchor="w")

        for label, var, save in (("Input PDF", self.in_path, False),
                                 ("Output PDF", self.out_path, True)):
            row = self._row(files_card, label)
            tk.Entry(row, textvariable=var, bg=THEME["btn"], fg=THEME["text"],
                     insertbackground=THEME["text"], relief="flat",
                     font=FONT_BODY).pack(side="left", fill="x", expand=True,
                                          ipady=4, padx=(0, 6))
            tk.Button(row, text="Browse...", font=FONT_BTN,
                      bg=THEME["btn"], fg=THEME["text"],
                      activebackground=THEME["btn_hi"], activeforeground=THEME["text"],
                      bd=0, relief="flat", padx=10, pady=3, cursor="hand2",
                      command=lambda v=var, s=save: self._pick_pdf(v, s)
                      ).pack(side="left")

        # ---- 2-column body ----
        body = ttk.Frame(wrap, style="TFrame")
        body.pack(fill="both", expand=True, pady=(10, 0))
        body.columnconfigure(0, weight=1, uniform="b")
        body.columnconfigure(1, weight=1, uniform="b")

        # left - languages + mode + optimize + output
        left = ttk.Frame(body, style="Card.TFrame", padding=12)
        left.grid(row=0, column=0, sticky="nsew", padx=(0, 6))

        ttk.Label(left, text="LANGUAGES", style="Section.TLabel"
                  ).pack(anchor="w")
        lg = ttk.Frame(left, style="Card.TFrame")
        lg.pack(fill="x", pady=(4, 8))
        for i, (code, name) in enumerate(OCR_LANGS):
            cb = tk.Checkbutton(
                lg, text=f"{name}  ({code})", variable=self.lang_vars[code],
                bg=THEME["panel"], fg=THEME["text"],
                activebackground=THEME["panel"], activeforeground=THEME["text"],
                selectcolor=THEME["bg"], bd=0, font=FONT_BODY,
                anchor="w", padx=4)
            cb.grid(row=i // 2, column=i % 2, sticky="w")

        ttk.Label(left, text="MODE", style="Section.TLabel"
                  ).pack(anchor="w", pady=(8, 0))
        for val, txt in (("skip",  "Skip  -  pages that already have text"),
                         ("force", "Force  -  rasterize and OCR everything"),
                         ("redo",  "Redo  -  replace existing OCR layer")):
            tk.Radiobutton(left, text=txt, variable=self.mode, value=val,
                           bg=THEME["panel"], fg=THEME["text"],
                           activebackground=THEME["panel"],
                           activeforeground=THEME["text"],
                           selectcolor=THEME["bg"], bd=0, font=FONT_BODY,
                           anchor="w").pack(anchor="w")

        ttk.Label(left, text="OPTIMIZE  /  OUTPUT", style="Section.TLabel"
                  ).pack(anchor="w", pady=(8, 0))
        opt_row = ttk.Frame(left, style="Card.TFrame")
        opt_row.pack(fill="x", pady=(4, 0))
        ttk.Label(opt_row, text="Optimize 0-3:", style="Card.TLabel"
                  ).pack(side="left")
        tk.Spinbox(opt_row, from_=0, to=3, width=4, textvariable=self.optimize,
                   bg=THEME["btn"], fg=THEME["text"],
                   buttonbackground=THEME["btn"],
                   insertbackground=THEME["text"], relief="flat",
                   font=FONT_BODY).pack(side="left", padx=(6, 16))
        ttk.Label(opt_row, text="Output:", style="Card.TLabel"
                  ).pack(side="left")
        ttk.Combobox(opt_row, textvariable=self.output_type, state="readonly",
                     width=10, font=FONT_BODY,
                     values=["pdf", "pdfa", "pdfa-1", "pdfa-2", "pdfa-3"]
                     ).pack(side="left", padx=6)

        jr = ttk.Frame(left, style="Card.TFrame")
        jr.pack(fill="x", pady=(4, 0))
        ttk.Label(jr, text="Parallel jobs:", style="Card.TLabel").pack(side="left")
        tk.Spinbox(jr, from_=1, to=64, width=4, textvariable=self.jobs,
                   bg=THEME["btn"], fg=THEME["text"],
                   buttonbackground=THEME["btn"],
                   insertbackground=THEME["text"], relief="flat",
                   font=FONT_BODY).pack(side="left", padx=(6, 16))
        ttk.Label(jr, text="Pages (e.g. 1,3-7):", style="Card.TLabel"
                  ).pack(side="left")
        tk.Entry(jr, textvariable=self.pages, width=14,
                 bg=THEME["btn"], fg=THEME["text"],
                 insertbackground=THEME["text"], relief="flat",
                 font=FONT_BODY).pack(side="left", padx=6, ipady=2)

        # right - preprocessing + metadata + sidecar
        right = ttk.Frame(body, style="Card.TFrame", padding=12)
        right.grid(row=0, column=1, sticky="nsew", padx=(6, 0))

        ttk.Label(right, text="PREPROCESSING", style="Section.TLabel"
                  ).pack(anchor="w")
        for var, txt in (
            (self.deskew,          "Deskew  -  straighten crooked pages"),
            (self.rotate_pages,    "Rotate pages  -  auto-correct orientation"),
            (self.clean,           "Clean  -  unpaper preprocessing (OCR only)"),
            (self.clean_final,     "Clean final  -  unpaper, included in output"),
            (self.remove_bg,       "Remove background  -  noisy scan cleanup"),
            (self.invalidate_sigs, "Invalidate digital signatures"),
            (self.sidecar,         "Export sidecar text  (.txt next to output)"),
        ):
            tk.Checkbutton(right, text=txt, variable=var,
                           bg=THEME["panel"], fg=THEME["text"],
                           activebackground=THEME["panel"],
                           activeforeground=THEME["text"],
                           selectcolor=THEME["bg"], bd=0, font=FONT_BODY,
                           anchor="w").pack(anchor="w")

        ttk.Label(right, text="METADATA", style="Section.TLabel"
                  ).pack(anchor="w", pady=(8, 0))
        for label, var in (("Title:",   self.title_meta),
                           ("Author:",  self.author_meta),
                           ("Subject:", self.subject_meta)):
            row = self._row(right, label)
            tk.Entry(row, textvariable=var, bg=THEME["btn"], fg=THEME["text"],
                     insertbackground=THEME["text"], relief="flat",
                     font=FONT_BODY).pack(side="left", fill="x", expand=True,
                                          ipady=3)

        # ---- preview command ----
        cmd_card = ttk.Frame(wrap, style="Card.TFrame", padding=10)
        cmd_card.pack(fill="x", pady=(10, 0))
        ttk.Label(cmd_card, text="COMMAND PREVIEW", style="Section.TLabel"
                  ).pack(anchor="w")
        self.cmd_preview = tk.Text(cmd_card, bg=THEME["panel"], fg=THEME["accent"],
                                   font=FONT_MONO, bd=0, height=3, wrap="word")
        self.cmd_preview.pack(fill="x", pady=(4, 0))
        self.cmd_preview.config(state="disabled")

        # ---- log + buttons ----
        log_card = ttk.Frame(wrap, style="Card.TFrame", padding=10)
        log_card.pack(fill="both", expand=True, pady=(10, 0))
        ttk.Label(log_card, text="OUTPUT", style="Section.TLabel"
                  ).pack(anchor="w")
        self.log_box = scrolledtext.ScrolledText(
            log_card, bg=THEME["panel"], fg=THEME["text"],
            font=FONT_MONO, bd=0, relief="flat", wrap="word", height=10)
        self.log_box.pack(fill="both", expand=True, pady=(4, 0))
        self.log_box.config(state="disabled")

        btn_row = ttk.Frame(wrap, style="TFrame")
        btn_row.pack(fill="x", pady=(10, 0))
        self.btn_run = tk.Button(
            btn_row, text="▶  Run OCR", font=("Segoe UI", 11, "bold"),
            bg=THEME["btn_run"], fg="white",
            activebackground=THEME["btn_run_hi"], activeforeground="white",
            bd=0, relief="flat", padx=18, pady=8, cursor="hand2",
            command=self._run)
        self.btn_run.pack(side="left")

        tk.Button(btn_row, text="Preview cmd", font=FONT_BTN,
                  bg=THEME["btn"], fg=THEME["text"],
                  activebackground=THEME["btn_hi"], activeforeground=THEME["text"],
                  bd=0, relief="flat", padx=12, pady=8, cursor="hand2",
                  command=self._update_preview).pack(side="left", padx=(8, 0))

        tk.Button(btn_row, text="Cancel", font=FONT_BTN,
                  bg=THEME["btn"], fg=THEME["text"],
                  activebackground=THEME["btn_hi"], activeforeground=THEME["text"],
                  bd=0, relief="flat", padx=12, pady=8, cursor="hand2",
                  command=self._cancel).pack(side="left", padx=(8, 0))

        tk.Button(btn_row, text="Close", font=FONT_BTN,
                  bg=THEME["btn"], fg=THEME["text"],
                  activebackground=THEME["btn_hi"], activeforeground=THEME["text"],
                  bd=0, relief="flat", padx=12, pady=8, cursor="hand2",
                  command=self.destroy).pack(side="right")

        self._update_preview()
        # Auto-refresh preview when any field changes
        for var in (self.in_path, self.out_path, self.mode, self.optimize,
                    self.output_type, self.deskew, self.rotate_pages,
                    self.clean, self.clean_final, self.remove_bg,
                    self.invalidate_sigs, self.sidecar, self.jobs, self.pages,
                    self.title_meta, self.author_meta, self.subject_meta,
                    *self.lang_vars.values()):
            var.trace_add("write", lambda *_: self._update_preview())

    # ---------- file pickers ----------
    def _pick_pdf(self, var, save):
        cur = var.get()
        start = os.path.dirname(cur) if cur and os.path.isdir(os.path.dirname(cur)) \
                else self.app.folder_var.get() or ROOT
        if save:
            p = filedialog.asksaveasfilename(
                initialdir=start, defaultextension=".pdf",
                filetypes=[("PDF files", "*.pdf"), ("All files", "*.*")])
        else:
            p = filedialog.askopenfilename(
                initialdir=start,
                filetypes=[("PDF files", "*.pdf"), ("All files", "*.*")])
        if p:
            var.set(p.replace("/", "\\"))
            # auto-fill output if empty
            if not save and not self.out_path.get():
                base, ext = os.path.splitext(p)
                self.out_path.set((base + "_ocr" + ext).replace("/", "\\"))

    # ---------- command building ----------
    def _build_cmd(self):
        langs = "+".join(c for c, _ in OCR_LANGS if self.lang_vars[c].get())
        if not langs:
            langs = "eng"
        cmd = ["ocrmypdf", "-l", langs, "--output-type", self.output_type.get(),
               "--optimize", str(self.optimize.get()),
               "--jobs", str(self.jobs.get())]
        m = self.mode.get()
        if m == "skip":
            cmd.append("--skip-text")
        elif m == "force":
            cmd.append("--force-ocr")
        elif m == "redo":
            cmd.append("--redo-ocr")
        if self.deskew.get():          cmd.append("--deskew")
        if self.rotate_pages.get():    cmd.append("--rotate-pages")
        if self.clean.get():           cmd.append("--clean")
        if self.clean_final.get():     cmd.append("--clean-final")
        if self.remove_bg.get():       cmd.append("--remove-background")
        if self.invalidate_sigs.get(): cmd.append("--invalidate-digital-signatures")
        if self.pages.get().strip():
            cmd += ["--pages", self.pages.get().strip()]
        if self.title_meta.get():   cmd += ["--title",   self.title_meta.get()]
        if self.author_meta.get():  cmd += ["--author",  self.author_meta.get()]
        if self.subject_meta.get(): cmd += ["--subject", self.subject_meta.get()]
        in_p, out_p = self.in_path.get(), self.out_path.get()
        if self.sidecar.get() and out_p:
            base, _ = os.path.splitext(out_p)
            cmd += ["--sidecar", base + ".txt"]
        cmd += [in_p or "<input.pdf>", out_p or "<output.pdf>"]
        return cmd

    def _update_preview(self):
        cmd = self._build_cmd()
        # Quote any args with spaces
        pretty = " ".join(f'"{c}"' if " " in c else c for c in cmd)
        self.cmd_preview.config(state="normal")
        self.cmd_preview.delete("1.0", "end")
        self.cmd_preview.insert("end", pretty)
        self.cmd_preview.config(state="disabled")

    # ---------- runner ----------
    def _log(self, msg):
        self.log_box.config(state="normal")
        self.log_box.insert("end", msg)
        self.log_box.see("end")
        self.log_box.config(state="disabled")

    def _run(self):
        in_p, out_p = self.in_path.get(), self.out_path.get()
        if not in_p or not os.path.isfile(in_p):
            messagebox.showerror("Missing input", "Pick an input PDF first.")
            return
        if not out_p:
            messagebox.showerror("Missing output", "Pick an output PDF path.")
            return
        # Try ocrmypdf import sanity
        try:
            subprocess.run(["ocrmypdf", "--version"],
                           capture_output=True, check=True, timeout=5)
        except Exception:
            messagebox.showerror("ocrmypdf missing",
                "ocrmypdf is not on PATH.\n\n"
                "Click 'Install / Repair Deps' on the main window.")
            return
        cmd = self._build_cmd()
        self._log(f"\n{'=' * 60}\n$ {' '.join(cmd)}\n{'=' * 60}\n")
        self.btn_run.config(state="disabled")
        threading.Thread(target=self._run_worker, args=(cmd,), daemon=True).start()

    def _run_worker(self, cmd):
        # Make sure Tesseract is on PATH
        env = os.environ.copy()
        for p in (r"C:\Program Files\Tesseract-OCR",
                  r"C:\Program Files (x86)\Tesseract-OCR"):
            if os.path.isdir(p) and p not in env.get("PATH", ""):
                env["PATH"] = env.get("PATH", "") + ";" + p
        try:
            self._proc = subprocess.Popen(
                cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, encoding="utf-8", errors="replace",
                bufsize=1, env=env,
                creationflags=subprocess.CREATE_NO_WINDOW
                  if hasattr(subprocess, "CREATE_NO_WINDOW") else 0,
            )
            for line in self._proc.stdout:
                self.after(0, self._log, line)
            rc = self._proc.wait()
            self.after(0, self._log, f"\n[exit code {rc}]\n")
            if rc == 0:
                self.after(0, self.app.log,
                           f"OCR ok: {os.path.basename(self.out_path.get())}")
        except Exception as e:
            self.after(0, self._log, f"\nFAILED: {e}\n")
        finally:
            self._proc = None
            self.after(0, lambda: self.btn_run.config(state="normal"))

    def _cancel(self):
        if self._proc and self._proc.poll() is None:
            try:
                self._proc.terminate()
                self._log("\n[cancelled]\n")
            except Exception:
                pass
        else:
            self._log("(nothing running)\n")


# ============================================================
#  Live preview / sample browser  (Adjust / Smart Crop)
# ============================================================
#  Point it at a folder of images, step through with Prev/Next, and
#  tick "Apply settings" to preview this stage using the panel's
#  CURRENT values (Before vs After). With the box unchecked it's just
#  a fast image browser. Adjust replicates stage 01's colour math;
#  Smart Crop calls stage 02's real functions for a faithful result.
# ============================================================

PREVIEW_EXTS = (".jpg", ".jpeg", ".png", ".bmp", ".tif", ".tiff", ".webp")

class PreviewDialog(tk.Toplevel):

    MAXW, MAXH = 420, 560   # per-image display box

    def __init__(self, app, panel):
        super().__init__(app)
        self.app = app
        self.panel = panel
        self.stage = panel.stage
        self._imgs = {}   # keep PhotoImage refs alive
        self._result = None
        self._err = None
        self.folder = ""
        self.files = []
        self.index = 0
        self.apply_var = tk.BooleanVar(value=False)   # preview OFF by default
        self.title(f"Preview / Samples  -  {self.stage['title']}")
        self.geometry("900x700")
        self.minsize(720, 560)
        self.configure(bg=THEME["bg"])
        self.transient(app)
        self._build()
        self.bind("<Left>",  lambda e: self._step(-1))
        self.bind("<Right>", lambda e: self._step(1))
        self.set_folder(self._default_folder(), remember=False)

    # ---------- folder / file list ----------
    def _resolve_images_dir(self, folder):
        """Return `folder` if it holds images directly; else the first
        immediate subfolder that does (handles e.g. work\\ -> work\\6047);
        else None."""
        if not folder or not os.path.isdir(folder):
            return None
        if self._scan(folder):
            return folder
        try:
            for name in sorted(os.listdir(folder)):
                sub = os.path.join(folder, name)
                if os.path.isdir(sub) and self._scan(sub):
                    return sub
        except Exception:
            pass
        return None

    def _default_folder(self):
        # The working folder at the top of the control panel takes priority.
        d = self._resolve_images_dir(self.app.folder_var.get())
        if d:
            return d
        for c in (os.path.join(ROOT, "work", "6047"),
                  os.path.join(ROOT, "work"),
                  os.path.dirname(SAMPLE_IMG)):
            d = self._resolve_images_dir(c)
            if d:
                return d
        return os.path.dirname(SAMPLE_IMG)

    def _scan(self, folder):
        try:
            return sorted(os.path.join(folder, fn) for fn in os.listdir(folder)
                          if fn.lower().endswith(PREVIEW_EXTS))
        except Exception:
            return []

    def set_folder(self, folder, remember=True, select=None):
        self.folder = folder
        self.files = self._scan(folder)
        self.index = self.files.index(select) if (select and select in self.files) else 0
        if remember and folder:
            self.app.history["preview_folder"] = folder
            self.app.save_history()
        self.folder_lbl.config(text=folder or "(no folder)")
        self.render()

    def current_file(self):
        if self.files and 0 <= self.index < len(self.files):
            return self.files[self.index]
        return ""

    # ---------- build ----------
    def _build(self):
        wrap = ttk.Frame(self, style="TFrame", padding=12)
        wrap.pack(fill="both", expand=True)

        ttk.Label(wrap, text=f"{self.stage['icon']}  {self.stage['title']} preview / samples",
                  style="Header.TLabel").pack(anchor="w")
        ttk.Label(wrap, text="Browse a folder of images; tick 'Apply settings' to preview this stage.",
                  style="SubHead.TLabel").pack(anchor="w", pady=(0, 8))

        frow = tk.Frame(wrap, bg=THEME["bg"])
        frow.pack(fill="x", pady=(0, 6))
        for txt, cmd in (("Use working folder", self._use_working),
                         ("Folder...", self._pick_folder),
                         ("Load file...", self._load_file)):
            tk.Button(frow, text=txt, font=FONT_BTN, bg=THEME["btn"], fg=THEME["text"],
                      activebackground=THEME["btn_hi"], activeforeground=THEME["text"],
                      bd=0, relief="flat", padx=12, pady=5, cursor="hand2",
                      command=cmd).pack(side="left", padx=(0, 8))
        self.folder_lbl = tk.Label(frow, text="", bg=THEME["bg"], fg=THEME["text_dim"],
                                   font=FONT_TAG)
        self.folder_lbl.pack(side="left")

        nrow = tk.Frame(wrap, bg=THEME["bg"])
        nrow.pack(fill="x", pady=(0, 8))
        tk.Button(nrow, text="◀ Prev", font=FONT_BTN, bg=THEME["btn"], fg=THEME["text"],
                  activebackground=THEME["btn_hi"], activeforeground=THEME["text"],
                  bd=0, relief="flat", padx=14, pady=5, cursor="hand2",
                  command=lambda: self._step(-1)).pack(side="left")
        tk.Button(nrow, text="Next ▶", font=FONT_BTN, bg=THEME["btn"], fg=THEME["text"],
                  activebackground=THEME["btn_hi"], activeforeground=THEME["text"],
                  bd=0, relief="flat", padx=14, pady=5, cursor="hand2",
                  command=lambda: self._step(1)).pack(side="left", padx=(8, 0))
        self.idx_lbl = tk.Label(nrow, text="", bg=THEME["bg"], fg=THEME["text"],
                                font=FONT_BODY)
        self.idx_lbl.pack(side="left", padx=(12, 0))
        tk.Checkbutton(nrow, text="Apply settings (preview this stage)",
                       variable=self.apply_var, command=self.render,
                       bg=THEME["bg"], fg=THEME["text"],
                       activebackground=THEME["bg"], activeforeground=THEME["text"],
                       selectcolor=THEME["panel"], bd=0, font=FONT_BODY).pack(side="right")

        imgs = tk.Frame(wrap, bg=THEME["bg"])
        imgs.pack(fill="both", expand=True)
        imgs.columnconfigure(0, weight=1, uniform="img")
        imgs.columnconfigure(1, weight=1, uniform="img")
        self.before_lbl = self._pane(imgs, "IMAGE", 0)
        self.after_lbl  = self._pane(imgs, "AFTER (settings applied)", 1)

        self.status = tk.Label(wrap, text="", bg=THEME["bg"], fg=THEME["text_mute"],
                               font=FONT_TAG)
        self.status.pack(anchor="w", pady=(6, 0))

    def _pane(self, parent, title, col):
        card = ttk.Frame(parent, style="Card.TFrame", padding=8)
        card.grid(row=0, column=col, sticky="nsew", padx=(0, 6) if col == 0 else (6, 0))
        ttk.Label(card, text=title, style="Section.TLabel").pack(anchor="w")
        lbl = tk.Label(card, bg=THEME["panel"], fg=THEME["text_mute"], text="(no image)")
        lbl.pack(fill="both", expand=True, pady=(6, 0))
        return lbl

    # ---------- actions ----------
    def _use_working(self):
        wf = self.app.folder_var.get()
        d = self._resolve_images_dir(wf)
        if d:
            self.set_folder(d, remember=False)
        else:
            messagebox.showinfo(
                "No images", "The working folder has no images (and no "
                f"subfolder with images):\n{wf}", parent=self)

    def _pick_folder(self):
        start = self.folder if os.path.isdir(self.folder) else ROOT
        d = filedialog.askdirectory(initialdir=start, title="Pick a folder of images")
        if d:
            self.set_folder(d.replace("/", "\\"))
            if not self.files:
                self.status.config(text="No images found in that folder.")

    def _load_file(self):
        start = self.folder if os.path.isdir(self.folder) else ROOT
        p = filedialog.askopenfilename(
            initialdir=start, title="Pick an image",
            filetypes=[("Images", "*.jpg *.jpeg *.png *.bmp *.tif *.tiff *.webp"),
                       ("All files", "*.*")])
        if p:
            p = p.replace("/", "\\")
            self.set_folder(os.path.dirname(p), select=p)

    def _step(self, d):
        if self.files:
            self.index = (self.index + d) % len(self.files)
            self.render()

    def _show(self, label, pil_img):
        from PIL import ImageTk
        photo = ImageTk.PhotoImage(pil_img)
        self._imgs[id(label)] = photo   # keep a ref
        label.config(image=photo, text="")

    def _clear(self, label, text):
        self._imgs.pop(id(label), None)
        label.config(image="", text=text)

    def _fit(self, pil_img):
        from PIL import Image
        im = pil_img.copy()
        im.thumbnail((self.MAXW, self.MAXH), Image.LANCZOS)
        return im

    def render(self):
        total = len(self.files)
        self.idx_lbl.config(text=(f"{self.index + 1} / {total}" if total else "0 / 0"))
        path = self.current_file()
        if not path:
            self._clear(self.before_lbl, "(no image)")
            self._clear(self.after_lbl, "")
            self.status.config(text="No images. Use 'Folder...' or 'Load file...'.")
            return
        self.status.config(text="Rendering..." if self.apply_var.get() else "Loading...")
        self._result = None
        self._err = None
        settings = self.panel._collect()
        # Worker does pure PIL/numpy/cv2 only - NO Tk calls (not thread-safe).
        threading.Thread(target=self._worker, args=(path, settings, self.apply_var.get()),
                         daemon=True).start()
        self.after(80, self._poll)

    def _poll(self):
        if self._result is None and self._err is None:
            self.after(80, self._poll)
            return
        if self._err:
            self.status.config(text=f"Preview failed: {self._err}")
            return
        before, after, note = self._result
        self._show(self.before_lbl, before)   # ImageTk on the main thread
        if after is not None:
            self._show(self.after_lbl, after)
        else:
            self._clear(self.after_lbl, "(tick 'Apply settings' to preview)")
        self.status.config(text=note)

    def _worker(self, path, settings, apply):
        import io, contextlib
        try:
            from PIL import Image
            before = Image.open(path).convert("RGB")
            base = os.path.basename(path)
            if not apply:
                self._result = (self._fit(before), None,
                                f"{base}    {before.width}x{before.height}")
                return
            if self.stage["id"] == "01":
                after = apply_adjustments(before, settings.get("adjustments", []))
                adj = "  ".join(f"{a['Type'][0]}={a['Value']}"
                                for a in settings.get("adjustments", [])) or "(no adjustments)"
                note = f"{base}    {adj}"
            else:  # 02 Smart Crop - reuse the real script functions (v4 API)
                import cv2
                mod = stage_module("02_Smart-Crop-Pages.bat")
                allow = int(settings.get("cropAllowance", 2))
                cwid = int(settings.get("canvasWidth", 0))
                chgt = int(settings.get("canvasHeight", 0))
                fitm = settings.get("fitMode", "pad-to-largest")
                # The script may print (incl. non-cp1252 chars); a console-less
                # pythonw process would crash on that, so swallow it.
                sink = io.StringIO()
                with contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
                    img = cv2.imread(path)
                    if img is None:
                        raise RuntimeError("could not read image")
                    rects, _dims = mod.detect_pages(path, min_area_frac=0.04)
                    npages = len(rects)
                    if rects:
                        # preview the largest detected page
                        r = max(rects, key=lambda rr: rr[1][0] * rr[1][1])
                        r = mod.expand_rect(r, allow)
                        page = mod.extract_page(img, r)
                        detected = (f"{npages} page(s) found"
                                    + (f" - showing largest" if npages > 1 else ""))
                    else:
                        page = None
                    if page is None:
                        page = mod.full_frame_crop(img)
                        detected = "full frame (no page found)"
                    page = mod.apply_rotation(page, settings.get("rotate", "none"))
                    page = mod.enhance_page(page, settings.get("enhance", "auto"))
                    th = int(settings.get("targetHeight", 0))
                    if fitm == "scale-to-height" and th > 0 and page.shape[0] > 0:
                        tw = max(1, int(page.shape[1] * th / page.shape[0]))
                        page = cv2.resize(page, (tw, th), interpolation=cv2.INTER_AREA)
                    # If a fixed canvas is set, show the EXACT final framing so
                    # the user can dial it in from the preview.
                    canvas_note = ""
                    if cwid > 0 and chgt > 0:
                        bg = mod._bg_color(settings.get("canvasBg", "white"), page)
                        page = mod.place_on_canvas(page, cwid, chgt, bg)
                        canvas_note = f"  canvas {cwid}x{chgt}"
                    crop_wh = f"{page.shape[1]}x{page.shape[0]}"
                    rgb = cv2.cvtColor(page, cv2.COLOR_BGR2RGB)
                after = Image.fromarray(rgb)
                note = (f"{base}    {detected}  {crop_wh}  fit={fitm}{canvas_note}"
                        + ("" if (cwid > 0 and chgt > 0)
                           else "  (set fixed canvas W/H to preview final size)"))
            self._result = (self._fit(before), self._fit(after), note)
        except Exception as e:
            self._err = str(e) or e.__class__.__name__


# ============================================================
#  Main app
# ============================================================

class ControlPanel(tk.Tk):

    def __init__(self):
        super().__init__()
        self.title(f"PDF Scripts  -  Control Panel  v{VERSION}")
        self.geometry("1180x780")
        self.minsize(1000, 680)
        self.configure(bg=THEME["bg"])

        # Try a Windows icon-friendly default
        try:
            self.iconbitmap(default="")
        except Exception:
            pass

        self.history = load_json(HISTORY_FN, default={})
        self.cards = []

        self._setup_styles()
        self._build_ui()
        self._refresh_deps_async()
        self._refresh_folder_stats()

        self.protocol("WM_DELETE_WINDOW", self._on_close)

    # ---------- styling ----------
    def _setup_styles(self):
        s = ttk.Style(self)
        s.theme_use("clam")

        s.configure(".",
                    background=THEME["bg"], foreground=THEME["text"],
                    fieldbackground=THEME["panel"], borderwidth=0)

        s.configure("TFrame", background=THEME["bg"])
        s.configure("Card.TFrame", background=THEME["panel"])
        s.configure("Panel.TFrame", background=THEME["panel"])
        s.configure("TLabel", background=THEME["bg"], foreground=THEME["text"], font=FONT_BODY)
        s.configure("Card.TLabel", background=THEME["panel"], foreground=THEME["text"], font=FONT_BODY)
        s.configure("Header.TLabel",   background=THEME["bg"],   foreground=THEME["text"], font=FONT_HEAD)
        s.configure("SubHead.TLabel",  background=THEME["bg"],   foreground=THEME["text_dim"], font=FONT_SUB)
        s.configure("Section.TLabel",  background=THEME["bg"],   foreground=THEME["text_dim"], font=("Segoe UI", 10, "bold"))
        s.configure("StageIcon.TLabel",  background=THEME["panel"], font=("Consolas", 11, "bold"))
        s.configure("StageTitle.TLabel", background=THEME["panel"], foreground=THEME["text"], font=FONT_CARD)
        s.configure("StageTag.TLabel",   background=THEME["panel"], foreground=THEME["text_dim"], font=FONT_TAG)
        s.configure("StageInfo.TLabel",  background=THEME["panel"], foreground=THEME["text_mute"], font=("Segoe UI", 8))
        s.configure("Stat.TLabel",       background=THEME["panel"], foreground=THEME["text"],    font=FONT_BODY)
        s.configure("StatDim.TLabel",    background=THEME["panel"], foreground=THEME["text_dim"], font=FONT_TAG)

        # Combobox dark
        s.configure("TCombobox",
            fieldbackground=THEME["btn"],
            background=THEME["btn"],
            foreground=THEME["text"],
            arrowcolor=THEME["text"],
            bordercolor=THEME["border"],
            lightcolor=THEME["border"],
            darkcolor=THEME["border"],
            selectbackground=THEME["btn"],
            selectforeground=THEME["text"],
        )
        s.map("TCombobox",
            fieldbackground=[("readonly", THEME["btn"])],
            foreground=[("readonly", THEME["text"])],
            selectbackground=[("readonly", THEME["btn"])],
            selectforeground=[("readonly", THEME["text"])],
        )
        # Dropdown listbox colours via option_add (Tk classic widget under combobox)
        self.option_add("*TCombobox*Listbox.background",       THEME["panel"])
        self.option_add("*TCombobox*Listbox.foreground",       THEME["text"])
        self.option_add("*TCombobox*Listbox.selectBackground", THEME["accent"])
        self.option_add("*TCombobox*Listbox.selectForeground", "white")
        self.option_add("*TCombobox*Listbox.font",             FONT_BODY)

        s.configure("Horizontal.TProgressbar",
            background=THEME["accent"], troughcolor=THEME["panel"],
            bordercolor=THEME["border"], lightcolor=THEME["accent"], darkcolor=THEME["accent"])

    # ---------- layout ----------
    def _build_ui(self):
        # Top header bar
        header = ttk.Frame(self, style="TFrame", padding=(20, 16, 20, 8))
        header.pack(fill="x")
        ttk.Label(header, text="PDF Scripts  -  Control Panel",
                  style="Header.TLabel").pack(side="left")
        ttk.Label(header, text="   Tamil / Hindi / Sanskrit book digitization pipeline",
                  style="SubHead.TLabel").pack(side="left")

        # No global working-folder bar anymore - each module has its own
        # Work folder field. Keep a hidden default (seeded from history) that
        # new stage panels and the preview dialog use as a starting point.
        self.folder_var = tk.StringVar(value=self.history.get("folder", ROOT))

        # ---- action row (full pipeline + utilities) ----
        act = ttk.Frame(self, style="TFrame", padding=(20, 6, 20, 6))
        act.pack(fill="x")

        tk.Button(act, text="▶▶  Run Full Pipeline  (01 → 02 → 03 → 04)",
                  font=("Segoe UI", 11, "bold"),
                  bg=THEME["accent"], fg="white",
                  activebackground="#79B8FF", activeforeground="white",
                  bd=0, relief="flat", padx=18, pady=10, cursor="hand2",
                  command=self._run_pipeline).pack(side="left")

        for txt, cmd in (
            ("Expand all",  lambda: self._set_all_panels(True)),
            ("Collapse all", lambda: self._set_all_panels(False)),
            ("Open Presets Folder", lambda: open_in_explorer(PRESETS)),
            ("Install / Repair Deps", self._run_install_all),
            ("View Crash Log", self._view_crash_log),
        ):
            tk.Button(act, text=txt, font=FONT_BTN,
                      bg=THEME["btn"], fg=THEME["text"],
                      activebackground=THEME["btn_hi"], activeforeground=THEME["text"],
                      bd=0, relief="flat", padx=12, pady=8, cursor="hand2",
                      command=cmd).pack(side="left", padx=(8, 0))

        # ---- scrollable stack of collapsible panels ----
        scroll_wrap = ttk.Frame(self, style="TFrame", padding=(20, 6, 20, 0))
        scroll_wrap.pack(fill="both", expand=True)
        canvas = tk.Canvas(scroll_wrap, bg=THEME["bg"], highlightthickness=0)
        vsb = ttk.Scrollbar(scroll_wrap, orient="vertical", command=canvas.yview)
        self._panel_canvas = canvas
        self.stack = tk.Frame(canvas, bg=THEME["bg"])
        self.stack.bind("<Configure>",
                        lambda e: canvas.configure(scrollregion=canvas.bbox("all")))
        win = canvas.create_window((0, 0), window=self.stack, anchor="nw")
        canvas.bind("<Configure>", lambda e: canvas.itemconfig(win, width=e.width))
        canvas.configure(yscrollcommand=vsb.set)
        canvas.pack(side="left", fill="both", expand=True)
        vsb.pack(side="right", fill="y")

        def _wheel(e):
            canvas.yview_scroll(int(-e.delta / 120), "units")
        canvas.bind("<Enter>", lambda e: canvas.bind_all("<MouseWheel>", _wheel))
        canvas.bind("<Leave>", lambda e: canvas.unbind_all("<MouseWheel>"))

        # two-column layout:
        #   left  = Adjust + Smart Crop + Images->PDF
        #   right = OCR + EasyOCR
        cols = tk.Frame(self.stack, bg=THEME["bg"])
        cols.pack(fill="x")
        cols.columnconfigure(0, weight=1, uniform="cols")
        cols.columnconfigure(1, weight=1, uniform="cols")
        left = tk.Frame(cols, bg=THEME["bg"])
        right = tk.Frame(cols, bg=THEME["bg"])
        left.grid(row=0, column=0, sticky="new", padx=(0, 6))
        right.grid(row=0, column=1, sticky="new", padx=(6, 0))
        column_for = {"01": left, "02": left, "03": left,
                      "04": right, "05": right}
        for stg in STAGES:
            parent = column_for.get(stg["id"], left)
            panel = StagePanel(parent, self, stg)
            panel.pack(fill="x")
            self.cards.append(panel)

        # environment section (collapsible)
        env = CollapsibleSection(self.stack, self, "Environment", expanded=True)
        env.pack(fill="x")
        self.deps_box = tk.Text(env.body, bg=THEME["panel"], fg=THEME["text"],
                                font=FONT_MONO, bd=0, height=8, relief="flat",
                                wrap="none")
        self.deps_box.pack(fill="x", padx=12, pady=(10, 10))
        self.deps_box.tag_configure("ok",   foreground=THEME["ok"])
        self.deps_box.tag_configure("err",  foreground=THEME["err"])
        self.deps_box.tag_configure("warn", foreground=THEME["warn"])
        self.deps_box.tag_configure("dim",  foreground=THEME["text_dim"])
        self.deps_box.config(state="disabled")

        # ---- fixed activity log at the bottom ----
        log_card = ttk.Frame(self, style="Card.TFrame", padding=(14, 8, 14, 10))
        log_card.pack(fill="x", padx=20, pady=(6, 4))
        head_row = ttk.Frame(log_card, style="Card.TFrame")
        head_row.pack(fill="x")
        ttk.Label(head_row, text="ACTIVITY", style="Section.TLabel").pack(side="left")
        tk.Button(head_row, text="Clear", font=FONT_TAG,
                  bg=THEME["btn"], fg=THEME["text_dim"],
                  activebackground=THEME["btn_hi"], activeforeground=THEME["text"],
                  bd=0, relief="flat", padx=10, pady=2, cursor="hand2",
                  command=self._clear_log).pack(side="right")
        self.log_box = scrolledtext.ScrolledText(
            log_card, bg=THEME["panel"], fg=THEME["text"],
            font=FONT_MONO, bd=0, relief="flat", wrap="word", height=6,
            insertbackground=THEME["text"],
        )
        self.log_box.pack(fill="x", pady=(8, 0))
        self.log_box.config(state="disabled")

        # ---- status bar (progress + completion indicator) ----
        status_bar = ttk.Frame(self, style="TFrame", padding=(20, 0, 20, 12))
        status_bar.pack(fill="x")
        self.run_status = tk.Label(status_bar, text="Ready", bg=THEME["bg"],
                                   fg=THEME["text_dim"], font=FONT_BODY, anchor="w")
        self.run_status.pack(side="left")
        self.btn_stop = tk.Button(status_bar, text="Stop", font=FONT_BTN,
                                  bg=THEME["btn"], fg=THEME["text"],
                                  activebackground=THEME["btn_hi"],
                                  activeforeground=THEME["text"], bd=0, relief="flat",
                                  padx=12, pady=4, cursor="hand2", command=self._stop_run,
                                  state="disabled")
        self.btn_stop.pack(side="right")
        self.progress = ttk.Progressbar(status_bar, mode="determinate", length=260)
        self.progress.pack(side="right", padx=(0, 10))

        # run state
        self._run_active = False
        self._run_proc = None
        self._run_panel = None
        self._run_q = None

        self.log(f"Control Panel v{VERSION} ready.")
        self.log(f"Root: {ROOT}")

    def _refresh_panel_scroll(self):
        # Recompute the scroll region after a panel expands/collapses.
        c = getattr(self, "_panel_canvas", None)
        if c is not None:
            c.after_idle(lambda: c.configure(scrollregion=c.bbox("all")))

    def _set_all_panels(self, on):
        for panel in self.cards:
            panel._set_expanded(on)

    # ---------- non-interactive stage runner ----------
    def set_run_status(self, text, running=False, ok=False, err=False):
        color = THEME["text_dim"]
        if running: color = THEME["warn"]
        elif ok:    color = THEME["ok"]
        elif err:   color = THEME["err"]
        self.run_status.config(text=text, fg=color)

    def begin_run(self, panel, folder, bat, extra_env=None):
        if self._run_active:
            messagebox.showinfo("Busy", "A stage is already running. Wait or Stop it.")
            return
        self._run_active = True
        self._run_panel = panel
        self._run_q = queue.Queue()
        panel.set_status("running")
        self.btn_stop.config(state="normal")
        self.progress.config(mode="indeterminate", maximum=100, value=0)
        self.progress.start(14)
        self.set_run_status(f"Running {panel.stage['title']}…", running=True)
        self.log(f"▶ Run {panel.stage['bat']}  ({folder})")
        env = os.environ.copy()
        env["PDF_RUN"]        = "1"
        env["PDF_RUN_PRESET"] = panel.path or ""
        env["PDF_RUN_FOLDER"] = folder
        env["BATFILE"]        = bat
        if extra_env:
            env.update(extra_env)
        threading.Thread(target=self._run_worker, args=(bat, env), daemon=True).start()
        self.after(120, self._run_poll)

    def _run_worker(self, bat, env):
        try:
            flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
            proc = subprocess.Popen(
                ["cmd", "/c", bat], cwd=ROOT, env=env,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, encoding="utf-8", errors="replace", bufsize=1,
                creationflags=flags)
            self._run_proc = proc
            for line in proc.stdout:
                self._run_q.put(("line", line.rstrip("\n")))
            rc = proc.wait()
            self._run_q.put(("done", rc))
        except Exception as e:
            self._run_q.put(("error", str(e)))

    def _run_poll(self):
        try:
            while True:
                kind, payload = self._run_q.get_nowait()
                if kind == "line":
                    if payload.strip():
                        self.log(payload)
                    m = re.search(r"\[(\d+)\s*/\s*(\d+)\]", payload)
                    if m:
                        i, total = int(m.group(1)), int(m.group(2))
                        if total > 0:
                            if str(self.progress["mode"]) != "determinate":
                                self.progress.stop()
                                self.progress.config(mode="determinate", maximum=total)
                            self.progress["value"] = i
                            self.set_run_status(
                                f"{self._run_panel.stage['title']}: {i}/{total}", running=True)
                elif kind == "done":
                    self._finish_run(payload)
                    return
                elif kind == "error":
                    self.log(f"  run error: {payload}")
                    self._finish_run(-1)
                    return
        except queue.Empty:
            pass
        if self._run_active:
            self.after(120, self._run_poll)

    def _finish_run(self, rc):
        self.progress.stop()
        self.progress.config(mode="determinate")
        panel = self._run_panel
        self._run_active = False
        self._run_proc = None
        self.btn_stop.config(state="disabled")
        if rc == 0:
            self.progress.config(value=self.progress["maximum"])
            panel.set_status("done")
            self.set_run_status(f"✓ Done: {panel.stage['title']}", ok=True)
            self.log(f"✓ {panel.stage['title']} finished.")
            self._refresh_folder_stats()
        else:
            panel.set_status("err")
            self.set_run_status(
                f"✗ Failed: {panel.stage['title']}  (exit {rc})", err=True)
            self.log(f"✗ {panel.stage['title']} failed (exit {rc}).")

    def _stop_run(self):
        p = self._run_proc
        if p and p.poll() is None:
            try:
                subprocess.run(["taskkill", "/F", "/T", "/PID", str(p.pid)],
                               capture_output=True)
            except Exception:
                try: p.terminate()
                except Exception: pass
            self.log("Stopped by user.")
            self.set_run_status("Stopped.", err=True)

    # ---------- folder ops ----------
    def _browse_folder(self):
        cur = self.folder_var.get()
        start = cur if os.path.isdir(cur) else ROOT
        chosen = filedialog.askdirectory(initialdir=start, title="Pick working folder")
        if chosen:
            self.folder_var.set(chosen.replace("/", "\\"))
            self._refresh_folder_stats()

    def _refresh_folder_stats(self):
        # No global working folder any more (each module has its own); this is
        # kept as a safe no-op so existing callers don't break.
        return

    def _refresh_all(self):
        for c in self.cards:
            c.refresh_presets()
        self._refresh_deps_async()
        self.log("Refreshed presets and dependency status.")

    # ---------- dependency probe (async) ----------
    def _refresh_deps_async(self):
        self._set_deps_text("(checking...)\n", "dim")
        threading.Thread(target=self._do_probe, daemon=True).start()

    def _do_probe(self):
        try:
            res = probe_deps()
        except Exception as e:
            self.after(0, self._set_deps_text, f"probe failed: {e}\n", "err")
            return
        self.after(0, self._render_deps, res)

    def _render_deps(self, res):
        self.deps_box.config(state="normal")
        self.deps_box.delete("1.0", "end")
        order = ["Python", "opencv", "numpy", "img2pdf", "Pillow",
                 "ocrmypdf", "Tesseract", "Ghostscript"]
        for name in order:
            ok, detail = res.get(name, (False, "?"))
            mark = "[OK]" if ok else "[ -]"
            tag  = "ok"  if ok else ("warn" if "optional" in detail else "err")
            self.deps_box.insert("end", f"{mark}  ", tag)
            self.deps_box.insert("end", f"{name:<12}", "ok" if ok else "err")
            self.deps_box.insert("end", f"  {detail}\n", "dim")
        self.deps_box.config(state="disabled")

    def _set_deps_text(self, text, tag):
        self.deps_box.config(state="normal")
        self.deps_box.delete("1.0", "end")
        self.deps_box.insert("end", text, tag)
        self.deps_box.config(state="disabled")

    # ---------- log ----------
    def log(self, msg):
        ts = datetime.now().strftime("%H:%M:%S")
        self.log_box.config(state="normal")
        self.log_box.insert("end", f"[{ts}] {msg}\n")
        self.log_box.see("end")
        self.log_box.config(state="disabled")

    def _clear_log(self):
        self.log_box.config(state="normal")
        self.log_box.delete("1.0", "end")
        self.log_box.config(state="disabled")

    # ---------- run actions ----------
    def _run_pipeline(self):
        ans = messagebox.askyesno(
            "Run full pipeline",
            "Launch all 4 stages back-to-back?\n\n"
            "Each stage opens in its own console window with its menu.\n"
            "Run each one, then close it to advance to the next.\n\n"
            "Folder and presets selected in the cards above are reminders -\n"
            "you'll still pick them inside each script's own menu."
        )
        if not ans:
            return
        threading.Thread(target=self._pipeline_worker, daemon=True).start()

    def _pipeline_worker(self):
        for stage in STAGES:
            if not stage.get("pipeline", True):
                continue   # optional add-ons (e.g. 05 VLM OCR) are not chained
            bat = os.path.join(ROOT, stage["bat"])
            self.after(0, self.log, f"=> Launching {stage['title']}  ({stage['bat']})")
            if not os.path.isfile(bat):
                self.after(0, self.log, f"   MISSING: {bat}")
                continue
            # Wait for the previous window to close before opening the next.
            try:
                subprocess.run(["cmd", "/c", bat], cwd=ROOT)
            except Exception as e:
                self.after(0, self.log, f"   error: {e}")
        self.after(0, self.log, "Full pipeline finished.")
        self.after(0, lambda: messagebox.showinfo(
            "Pipeline finished", "All four stages have completed."))

    def _open_ocr_advanced(self):
        OcrAdvancedDialog(self)
        self.log("Opened Advanced OCR (ocrmypdf direct).")

    def _run_install_all(self):
        bat = os.path.join(PRESETS, "00_INSTALL_ALL.bat")
        if not os.path.isfile(bat):
            messagebox.showerror("Not found", f"Cannot find:\n{bat}")
            return
        run_bat(bat)
        self.log("Launched dependency installer.")

    def _view_crash_log(self):
        log = os.path.join(tempfile.gettempdir(), "pdf_control_panel_crash.log")
        if os.path.isfile(log):
            try:
                os.startfile(log)
            except Exception:
                subprocess.Popen(["notepad.exe", log])
        else:
            messagebox.showinfo("No crash log",
                "No crash log found. (That's a good thing.)\n\n"
                f"Would have been at:\n{log}")

    # ---------- history ----------
    def save_history(self):
        try:
            save_json(HISTORY_FN, self.history)
        except Exception:
            pass

    def _on_close(self):
        self.save_history()
        self.destroy()


# ============================================================
#  Entry point
# ============================================================

def main():
    try:
        app = ControlPanel()
        app.mainloop()
    except Exception:
        # Crash log to TEMP (not project folder - paths with spaces issue)
        log_path = os.path.join(tempfile.gettempdir(), "pdf_control_panel_crash.log")
        try:
            with open(log_path, "w", encoding="utf-8") as f:
                f.write(f"Crash at {datetime.now()}\n\n")
                f.write(traceback.format_exc())
        except Exception:
            pass
        # Also try to show a message
        try:
            import tkinter.messagebox as mb
            mb.showerror("Control Panel crashed",
                f"See log:\n{log_path}\n\n{traceback.format_exc()[:600]}")
        except Exception:
            pass
        sys.exit(1)


if __name__ == "__main__":
    main()
