@echo off
rem ============================================================
rem  04_OCR-PDF.bat - Python / ocrmypdf + Tesseract
rem  Add invisible searchable text layer to a scanned PDF
rem  Requires: Python 3.x, Tesseract OCR (separate install)
rem ============================================================
setlocal
set "BATFILE=%~f0"
set "PATH=%PATH%;C:\Program Files\Tesseract-OCR;C:\Program Files (x86)\Tesseract-OCR"

if not exist "%~dp0_internal\_versions\" mkdir "%~dp0_internal\_versions\"
for /f "tokens=*" %%T in ('powershell -NoProfile -Command "Get-Date -Format 'yyyy-MM-dd_HHmmss'"') do set "_BKTS=%%T"
copy /y "%~f0" "%~dp0_internal\_versions\%~n0_%_BKTS%.bat" >nul 2>&1

python --version >nul 2>&1 || (echo Python not found. Install from https://python.org & pause & exit /b 1)
tesseract --version >nul 2>&1 || (echo Tesseract not found. Install from https://github.com/UB-Mannheim/tesseract/wiki & pause & exit /b 1)
python -c "import ocrmypdf" >nul 2>&1 || (echo Installing ocrmypdf... & pip install ocrmypdf || (echo Failed. Run: pip install ocrmypdf & pause & exit /b 1))

set "TMPPY=%TEMP%\ocr_pdf_04.py"
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$f=$env:BATFILE;$l=[IO.File]::ReadAllLines($f);$s=0;for($i=0;$i-lt$l.Count;$i++){if($l[$i]-eq'#PY_BEGIN'){$s=$i+1;break}};[IO.File]::WriteAllLines($env:TMPPY,$l[$s..($l.Count-1)],[Text.Encoding]::UTF8)"

python "%TMPPY%"
del "%TMPPY%" >nul 2>&1
if not defined PDF_RUN pause >nul
exit /b
#PY_BEGIN
#!/usr/bin/env python3
"""
04 OCR PDF  v1.0
Add invisible searchable text layer to scanned PDFs.
Uses ocrmypdf + Tesseract OCR.
Supports Tamil, English, Hindi, Sanskrit, and other Indian languages.
"""

import subprocess
import os, sys, json, glob, re, time
from pathlib import Path

# Suppress the Windows "Application Error" pop-up if a child process (e.g.
# Ghostscript, used for PDF/A) fails to initialize. Child procs inherit this.
if os.name == "nt":
    try:
        import ctypes
        ctypes.windll.kernel32.SetErrorMode(0x0001 | 0x0002 | 0x8000)
    except Exception:
        pass

# ── Ensure Tesseract is findable on Windows ──────────────────────────────────
_tess_paths = [
    r'C:\Program Files\Tesseract-OCR',
    r'C:\Program Files (x86)\Tesseract-OCR',
]
for _tp in _tess_paths:
    if os.path.isfile(os.path.join(_tp, 'tesseract.exe')):
        if _tp not in os.environ.get('PATH', ''):
            os.environ['PATH'] = os.environ.get('PATH', '') + ';' + _tp
        break

import ocrmypdf

# Fix Windows console encoding for Unicode (Tamil, Hindi, etc.)
try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')
except: pass

VERSION = "1.0"
CHANGELOG = """\
v1.0  2026-03-30  Initial release — ocrmypdf + Tesseract
                  Multi-language OCR (Tamil, Hindi, Sanskrit, English +10)
                  Invisible text layer — original images untouched
                  PDF metadata embedding
                  ocr presets  ocr_preset_XX_desc.json
"""

# ═══════════════════════════════════════════════════════════
#  Language definitions
# ═══════════════════════════════════════════════════════════

# All supported languages — Tesseract codes
# Ordered: common first, then Indian languages, then others
ALL_LANGUAGES = [
    # ── Primary ──
    ('eng',  'English'),
    ('tam',  'Tamil'),
    ('hin',  'Hindi'),
    ('san',  'Sanskrit'),
    # ── South Indian ──
    ('tel',  'Telugu'),
    ('kan',  'Kannada'),
    ('mal',  'Malayalam'),
    # ── North / East Indian ──
    ('ben',  'Bengali'),
    ('guj',  'Gujarati'),
    ('mar',  'Marathi'),
    ('pan',  'Punjabi (Gurmukhi)'),
    ('ori',  'Odia'),
    ('urd',  'Urdu'),
    ('nep',  'Nepali'),
]

# Common prebuilt combos for quick selection
LANGUAGE_COMBOS = [
    (['tam', 'hin', 'eng'],        'Tamil + Hindi + English'),
    (['tam', 'eng'],               'Tamil + English'),
    (['hin', 'eng'],               'Hindi + English'),
    (['tam', 'hin', 'san', 'eng'], 'Tamil + Hindi + Sanskrit + English'),
    (['san', 'eng'],               'Sanskrit + English'),
    (['tam', 'san', 'eng'],        'Tamil + Sanskrit + English'),
    (['eng'],                      'English only'),
]

# ISO 639-1 codes for PDF metadata
LANG_TO_ISO = {
    'eng': 'en', 'tam': 'ta', 'hin': 'hi', 'san': 'sa',
    'tel': 'te', 'kan': 'kn', 'mal': 'ml', 'ben': 'bn',
    'guj': 'gu', 'mar': 'mr', 'pan': 'pa', 'ori': 'or',
    'urd': 'ur', 'nep': 'ne',
}


# ═══════════════════════════════════════════════════════════
#  Tesseract helpers
# ═══════════════════════════════════════════════════════════

def get_tesseract_version():
    """Return Tesseract version string, or None if not found."""
    try:
        r = subprocess.run(['tesseract', '--version'],
                           capture_output=True, text=True, timeout=10)
        first = r.stdout.strip().split('\n')[0] if r.stdout else ''
        return first or r.stderr.strip().split('\n')[0]
    except:
        return None


def get_installed_languages():
    """Return list of installed Tesseract language codes."""
    try:
        r = subprocess.run(['tesseract', '--list-langs'],
                           capture_output=True, text=True, timeout=10)
        lines = (r.stdout or r.stderr).strip().split('\n')
        # First line is usually "List of available languages..." — skip it
        langs = []
        for line in lines:
            code = line.strip()
            if code and not code.startswith('List') and len(code) <= 10:
                langs.append(code)
        return sorted(langs)
    except:
        return []


def check_languages(desired, installed):
    """Check which desired languages are installed. Return (available, missing)."""
    available = [l for l in desired if l in installed]
    missing   = [l for l in desired if l not in installed]
    return available, missing


def get_tessdata_path():
    """Try to find the tessdata directory."""
    # Check TESSDATA_PREFIX env var
    prefix = os.environ.get('TESSDATA_PREFIX', '')
    if prefix and os.path.isdir(prefix):
        return prefix

    # Common Windows install paths
    candidates = [
        r'C:\Program Files\Tesseract-OCR\tessdata',
        r'C:\Program Files (x86)\Tesseract-OCR\tessdata',
    ]
    # Also check Tesseract install from PATH
    try:
        r = subprocess.run(['where', 'tesseract'], capture_output=True, text=True, timeout=5)
        if r.stdout:
            tess_dir = os.path.dirname(r.stdout.strip().split('\n')[0])
            candidates.insert(0, os.path.join(tess_dir, 'tessdata'))
    except: pass

    for c in candidates:
        if os.path.isdir(c):
            return c
    return None


# ═══════════════════════════════════════════════════════════
#  OCR Preset helpers  (ocr_preset_01_desc.json)
# ═══════════════════════════════════════════════════════════

def script_folder():
    bat = os.environ.get('BATFILE', '')
    return os.path.dirname(bat) if bat else os.path.dirname(os.path.abspath(__file__))

def preset_folder():
    pf = os.path.join(script_folder(), '00_PRESETS')
    os.makedirs(pf, exist_ok=True)
    return pf


def list_ocr_presets():
    files  = sorted(glob.glob(os.path.join(preset_folder(), 'ocr_preset_*.json')))
    result = []
    for f in files:
        try:
            with open(f, encoding='utf-8') as fp:
                d = json.load(fp); d['_file'] = f; result.append(d)
        except: pass
    return result


def next_ocr_num():
    nums = []
    for f in glob.glob(os.path.join(preset_folder(), 'ocr_preset_*.json')):
        m = re.match(r'ocr_preset_(\d+)_', os.path.basename(f))
        if m: nums.append(int(m.group(1)))
    return max(nums, default=0) + 1


def save_ocr_preset(desc, folder_path, settings):
    num  = next_ocr_num()
    safe = re.sub(r'[^a-zA-Z0-9 _-]', '', desc).strip()
    safe = re.sub(r'\s+', '_', safe).lower()
    safe = re.sub(r'_+', '_', safe).strip('_') or 'ocr'
    fname = f'ocr_preset_{num:02d}_{safe}.json'
    data  = {'description': desc, 'folderPath': folder_path, **settings}
    with open(os.path.join(preset_folder(), fname), 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2)
    print(f"  Saved as: {fname}")


def show_ocr_preset_menu():
    presets = list_ocr_presets()
    if not presets: return None
    print(f"\nSaved OCR presets ({len(presets)} found):")
    print(f"  {'#':<4} {'File':<38} {'Languages':<20} Folder")
    print("  " + chr(9472) * 74)
    for i, p in enumerate(presets, 1):
        fname = os.path.splitext(os.path.basename(p['_file']))[0]
        langs = '+'.join(p.get('languages', ['eng']))
        folder = os.path.basename(p.get('folderPath', '')) or chr(8212)
        print(f"  [{i}] {fname:<38} {langs:<20} {folder}")
    print("  [0] Skip — enter settings manually")
    while True:
        raw = input(f"\nEnter preset number (0-{len(presets)}): ").strip()
        try:
            n = int(raw)
            if 0 <= n <= len(presets):
                return None if n == 0 else presets[n - 1]
        except: pass
        print(f"  Please enter a number between 0 and {len(presets)}.")


# ═══════════════════════════════════════════════════════════
#  UI helpers
# ═══════════════════════════════════════════════════════════

def clear():
    os.system('cls' if os.name == 'nt' else 'clear')


def print_header():
    clear()
    print("=" * 56)
    print(f"  OCR PDF  v{VERSION}  (ocrmypdf + Tesseract)")
    print(f"  Add searchable text layer to scanned PDFs")
    print("=" * 56)
    for line in CHANGELOG.strip().split('\n'):
        print(f"  {line}")
    print()


def read_int(prompt, lo, hi, default):
    while True:
        raw = input(f"{prompt} [default {default}]: ").strip()
        if not raw: return default
        try:
            n = int(raw)
            if lo <= n <= hi: return n
        except: pass
        print(f"  Enter a whole number {lo}-{hi}.")


def yn(prompt, default_yes=True):
    tag = "[Y/n]" if default_yes else "[y/N]"
    raw = input(f"{prompt} {tag}: ").strip().lower()
    return default_yes if not raw else raw.startswith('y')


def human_size(path):
    """Return file size as a human-readable string."""
    size = os.path.getsize(path)
    for unit in ('B', 'KB', 'MB', 'GB'):
        if size < 1024:
            return f"{size:.1f} {unit}"
        size /= 1024
    return f"{size:.1f} TB"


# ═══════════════════════════════════════════════════════════
#  Language selection UI
# ═══════════════════════════════════════════════════════════

def select_languages(installed):
    """
    Interactive language selection.
    Shows quick combos first, then individual language picker.
    Returns list of Tesseract language codes.
    """
    print("\n-- Language selection --------------------------------------------")

    # Show which Indian languages are installed
    our_langs = [(code, name) for code, name in ALL_LANGUAGES if code in installed]
    missing   = [(code, name) for code, name in ALL_LANGUAGES if code not in installed]

    print(f"  Installed: {', '.join(code for code, _ in our_langs) if our_langs else 'none'}")
    if missing:
        print(f"  Not installed: {', '.join(code for code, _ in missing)}")

    # ── Quick combos ──────────────────────────────────────────
    print("\n  Quick language combos:")
    available_combos = []
    for codes, name in LANGUAGE_COMBOS:
        avail, miss = check_languages(codes, installed)
        if not miss:
            available_combos.append((codes, name))

    if available_combos:
        for i, (codes, name) in enumerate(available_combos, 1):
            print(f"  [{i}] {name:<35} ({'+'.join(codes)})")
        print(f"  [C] Custom — pick individual languages")

        while True:
            raw = input(f"\nChoice (1-{len(available_combos)} or C) [default 1]: ").strip()
            if not raw:
                return available_combos[0][0]
            if raw.upper() == 'C':
                break
            try:
                n = int(raw)
                if 1 <= n <= len(available_combos):
                    selected = available_combos[n - 1][0]
                    print(f"  Selected: {'+'.join(selected)}")
                    return selected
            except: pass
            print(f"  Enter 1-{len(available_combos)} or C.")
    else:
        print("  (No quick combos available — some languages not installed)")

    # ── Individual selection ──────────────────────────────────
    print("\n  Available languages (enter numbers separated by commas):")
    for i, (code, name) in enumerate(our_langs, 1):
        default_mark = " *" if code in ('tam', 'eng') else ""
        print(f"  [{i:2d}] {code:<5}  {name}{default_mark}")

    if not our_langs:
        print("  No supported languages installed!")
        print(f"  Install language packs in Tesseract, or download .traineddata files.")
        tessdata = get_tessdata_path()
        if tessdata:
            print(f"  tessdata folder: {tessdata}")
        print(f"  Download from: https://github.com/tesseract-ocr/tessdata_best")
        return ['eng'] if 'eng' in installed else installed[:1] if installed else []

    # Find default indices for tam+eng
    default_indices = []
    for i, (code, _) in enumerate(our_langs, 1):
        if code in ('tam', 'eng'):
            default_indices.append(str(i))
    default_str = ','.join(default_indices) if default_indices else '1'

    while True:
        raw = input(f"\nEnter language numbers (e.g. 1,2) [default {default_str}]: ").strip()
        if not raw:
            raw = default_str
        try:
            nums = [int(x.strip()) for x in raw.split(',')]
            selected = []
            valid = True
            for n in nums:
                if 1 <= n <= len(our_langs):
                    code = our_langs[n - 1][0]
                    if code not in selected:
                        selected.append(code)
                else:
                    valid = False; break
            if valid and selected:
                print(f"  Selected: {'+'.join(selected)}")
                return selected
        except: pass
        print(f"  Enter numbers 1-{len(our_langs)} separated by commas.")


# ═══════════════════════════════════════════════════════════
#  PDF file selection
# ═══════════════════════════════════════════════════════════

def find_pdfs(folder):
    """Find PDF files in the folder."""
    found = glob.glob(os.path.join(folder, '*.pdf')) + \
            glob.glob(os.path.join(folder, '*.PDF'))
    seen = set(); pdfs = []
    for f in sorted(found):
        k = f.lower()
        if k not in seen:
            seen.add(k); pdfs.append(f)
    return pdfs


def select_input_pdf(folder):
    """Let user pick a PDF from the folder, or type a path."""
    pdfs = find_pdfs(folder)

    if not pdfs:
        print(f"\n  No PDF files found in: {folder}")
        print(f"  You can enter a full path to a PDF file instead.")
        while True:
            raw = input("\nPDF file path: ").strip().strip('"')
            if raw and os.path.isfile(raw) and raw.lower().endswith('.pdf'):
                return raw
            if raw and os.path.isfile(raw):
                print("  File must be a .pdf")
                continue
            print(f"  File not found: {raw}")

    if len(pdfs) == 1:
        print(f"\n  Found 1 PDF: {os.path.basename(pdfs[0])}")
        print(f"  Size: {human_size(pdfs[0])}")
        if yn("  Use this file?", True):
            return pdfs[0]

    print(f"\n  PDF files in folder ({len(pdfs)} found):")
    for i, p in enumerate(pdfs, 1):
        print(f"  [{i}] {os.path.basename(p):<40} {human_size(p)}")

    while True:
        raw = input(f"\nSelect PDF (1-{len(pdfs)}): ").strip()
        try:
            n = int(raw)
            if 1 <= n <= len(pdfs):
                return pdfs[n - 1]
        except: pass
        # Maybe they typed a path
        if raw and os.path.isfile(raw.strip('"')):
            return raw.strip('"')
        print(f"  Enter 1-{len(pdfs)} or a file path.")


# ═══════════════════════════════════════════════════════════
#  OCR processing
# ═══════════════════════════════════════════════════════════

def run_ocr(input_pdf, output_pdf, languages, optimize=1,
            skip_text=True, deskew=False, clean_final=False,
            metadata=None, pdfa=True, jobs=None):
    """
    Run OCR on a PDF using ocrmypdf.
    Returns (success: bool, message: str).
    """
    lang_str = '+'.join(languages)

    kwargs = {
        'language':       languages,       # list of codes, e.g. ['tam', 'eng']
        'optimize':       optimize,
        'deskew':         deskew,
        'clean_final':    clean_final,
        'progress_bar':   True,
    }

    # OCR mode
    if skip_text:
        kwargs['skip_text'] = True
    else:
        kwargs['force_ocr'] = True

    # PDF/A generation
    kwargs['output_type'] = 'pdfa' if pdfa else 'pdf'

    # Jobs (parallelism)
    if jobs:
        kwargs['jobs'] = jobs

    # Metadata
    if metadata:
        if metadata.get('title'):    kwargs['title']   = metadata['title']
        if metadata.get('author'):   kwargs['author']  = metadata['author']
        if metadata.get('subject'):  kwargs['subject'] = metadata['subject']
        if metadata.get('keywords'): kwargs['keywords'] = metadata['keywords']

    try:
        print(f"\n  Running OCR: {lang_str}")
        print(f"  Input:  {os.path.basename(input_pdf)}  ({human_size(input_pdf)})")
        print(f"  Output: {os.path.basename(output_pdf)}")
        print(f"  This may take several minutes for large documents...\n")

        # Positional args: input_file, output_file
        exit_code = ocrmypdf.ocr(input_pdf, output_pdf, **kwargs)

        return True, "OCR completed successfully"

    except ocrmypdf.exceptions.PriorOcrFoundError:
        return False, ("PDF already contains OCR text. "
                       "Use 'Force re-OCR' option to redo.")

    except ocrmypdf.exceptions.MissingDependencyError as e:
        msg = str(e)
        if 'ghostscript' in msg.lower():
            return False, ("Ghostscript not found (needed for PDF/A output).\n"
                          "  Download from: https://ghostscript.com/releases/gsdnld.html\n"
                          "  Or disable PDF/A generation to skip this requirement.")
        return False, f"Missing dependency: {e}"

    except ocrmypdf.exceptions.EncryptedPdfError:
        return False, "PDF is encrypted. Please decrypt it first."

    except ocrmypdf.exceptions.InputFileError as e:
        return False, f"Input file error: {e}"

    except PermissionError:
        return False, ("Permission denied — the PDF may be open in another program.\n"
                      "  Close Adobe Reader / browser and try again.")

    except Exception as e:
        return False, f"OCR failed: {e}"


# ═══════════════════════════════════════════════════════════
#  Main
# ═══════════════════════════════════════════════════════════

def main():
    print_header()

    # ── Check Tesseract ──────────────────────────────────────
    tess_ver = get_tesseract_version()
    if tess_ver:
        print(f"  Tesseract: {tess_ver}")
    else:
        print("  ERROR: Tesseract OCR not found in PATH!")
        print("  Download from: https://github.com/UB-Mannheim/tesseract/wiki")
        input("Press Enter to exit..."); return

    installed = get_installed_languages()
    print(f"  Languages installed: {len(installed)}")

    # Check for key languages
    key_langs = ['eng', 'tam', 'hin', 'san']
    _, missing_key = check_languages(key_langs, installed)
    if missing_key:
        print(f"\n  Note: These languages are NOT installed: {', '.join(missing_key)}")
        tessdata = get_tessdata_path()
        if tessdata:
            print(f"  To add them, download .traineddata files and place in:")
            print(f"    {tessdata}")
        print(f"  Download: https://github.com/tesseract-ocr/tessdata_best")
        print()

    # ── Preset? ──────────────────────────────────────────────
    preset = show_ocr_preset_menu()

    # ── Source folder / PDF ──────────────────────────────────
    sf        = script_folder()
    suggested = sf
    folder    = None

    if preset:
        fp = preset.get('folderPath', '')
        if fp and os.path.isdir(fp):
            print(f"\nPreset folder: {fp}")
            if yn("Use this folder?", True):
                folder = fp                       # use it directly, no re-prompt
                print("Using preset folder.")

    if folder is None:
        print(f"\nFolder containing the PDF (Enter = {suggested}):")
        raw    = input("Folder path: ").strip().strip('"')
        folder = raw or suggested
    if not os.path.isdir(folder):
        # Maybe they entered a direct PDF path
        if os.path.isfile(folder) and folder.lower().endswith('.pdf'):
            input_pdf = folder
            folder    = os.path.dirname(folder)
        else:
            print(f"\n  Folder not found: {folder}")
            input("Press Enter to exit..."); return
    else:
        # ── Select PDF file ──────────────────────────────────
        if preset and preset.get('inputPdf'):
            candidate = os.path.join(folder, preset['inputPdf'])
            if os.path.isfile(candidate):
                print(f"\n  Preset PDF: {preset['inputPdf']}  ({human_size(candidate)})")
                if yn("  Use this file?", True):
                    input_pdf = candidate
                else:
                    input_pdf = select_input_pdf(folder)
            else:
                input_pdf = select_input_pdf(folder)
        else:
            input_pdf = select_input_pdf(folder)

    # ── Settings ──────────────────────────────────────────────
    if preset:
        languages    = preset.get('languages', ['tam', 'eng'])
        optimize     = int(preset.get('optimizeLevel', 1))
        skip_text    = bool(preset.get('skipText', True))
        deskew       = bool(preset.get('deskew', False))
        clean_final  = bool(preset.get('cleanFinal', False))
        out_suffix   = preset.get('outputSuffix', '_ocr')
        pdfa         = bool(preset.get('pdfaGeneration', True))
        metadata     = preset.get('metadata', {})

        # Verify languages are available
        avail, miss = check_languages(languages, installed)
        if miss:
            print(f"\n  WARNING: Preset languages not installed: {', '.join(miss)}")
            print(f"  Available: {', '.join(avail) if avail else 'none'}")
            if not avail:
                print("  Cannot proceed without any OCR language.")
                input("Press Enter to exit..."); return
            languages = avail

        lang_names = '+'.join(languages)
        print(f"\nPreset settings:")
        print(f"  Languages: {lang_names}  |  Optimize: {optimize}  |  PDF/A: {pdfa}")
        print(f"  Skip existing text: {skip_text}  |  Deskew: {deskew}")
    else:
        # ── Language selection ────────────────────────────────
        languages = select_languages(installed)
        if not languages:
            print("\n  No languages selected. Cannot run OCR.")
            input("Press Enter to exit..."); return

        # ── Optimization level ────────────────────────────────
        print("\n-- Optimization level -------------------------------------------")
        print("  [0] None      — no image optimization (fastest, largest file)")
        print("  [1] Safe      — lossless optimization (recommended)")
        print("  [2] Moderate  — some lossy optimization (smaller file)")
        print("  [3] Aggressive — maximum compression (smallest, may reduce quality)")
        optimize = read_int("Optimization (0-3)", 0, 3, 1)

        # ── Skip pages with existing text ─────────────────────
        print("\n-- Existing text handling ----------------------------------------")
        print("  Skip pages that already have a text layer (from a previous OCR run).")
        skip_text = yn("Skip pages with existing text?", True)

        # ── Deskew ────────────────────────────────────────────
        print("\n-- Deskew pages -------------------------------------------------")
        print("  Straighten slightly tilted pages before OCR.")
        print("  (Usually not needed if Script 02 already straightened them.)")
        deskew = yn("Enable deskew?", False)

        # ── Clean final ──────────────────────────────────────
        clean_final = False    # Keep it simple; advanced users can edit preset

        # ── PDF/A ─────────────────────────────────────────────
        print("\n-- PDF/A output -------------------------------------------------")
        print("  PDF/A is an archival format — recommended for long-term storage.")
        print("  Requires Ghostscript installed (free). If not installed, will")
        print("  fall back to regular PDF.")
        pdfa = yn("Generate PDF/A?", True)

        # ── Output suffix ─────────────────────────────────────
        out_suffix = '_ocr'

        # ── Metadata ──────────────────────────────────────────
        print("\n-- PDF metadata (optional) --------------------------------------")
        print("  Press Enter to skip any field.")
        meta_title   = input("  Title: ").strip()
        meta_author  = input("  Author: ").strip()
        meta_subject = input("  Subject: ").strip()

        # Auto-detect primary language for metadata
        primary_lang = LANG_TO_ISO.get(languages[0], '')
        metadata = {
            'title':    meta_title,
            'author':   meta_author,
            'subject':  meta_subject,
            'language': primary_lang,
        }

        # ── Save preset? ─────────────────────────────────────
        if yn("\nSave these settings as an OCR preset?", False):
            desc = ''
            while not desc.strip():
                desc = input("  Short description (e.g. 'tamil english book'): ").strip()
            save_ocr_preset(desc, folder, {
                'languages': languages, 'optimizeLevel': optimize,
                'skipText': skip_text, 'deskew': deskew,
                'cleanFinal': clean_final, 'outputSuffix': out_suffix,
                'pdfaGeneration': pdfa, 'metadata': metadata,
            })

    # ── Build output path ─────────────────────────────────────
    in_base = os.path.splitext(os.path.basename(input_pdf))[0]
    out_name = f"{in_base}{out_suffix}.pdf"
    output_pdf = os.path.join(os.path.dirname(input_pdf), out_name)

    # If output == input, adjust
    if os.path.normcase(output_pdf) == os.path.normcase(input_pdf):
        out_name   = f"{in_base}{out_suffix}_out.pdf"
        output_pdf = os.path.join(os.path.dirname(input_pdf), out_name)

    # If output exists, ask
    if os.path.exists(output_pdf):
        if not yn(f"\n  {out_name} already exists. Overwrite?", False):
            ts = time.strftime('%Y%m%d_%H%M%S')
            out_name   = f"{in_base}{out_suffix}_{ts}.pdf"
            output_pdf = os.path.join(os.path.dirname(input_pdf), out_name)
            print(f"  Saving as: {out_name}")

    # ── Run OCR ───────────────────────────────────────────────
    print("\n" + "=" * 56)
    print(f"  Starting OCR...")
    print("=" * 56)

    t0 = time.time()

    ok, msg = run_ocr(
        input_pdf, output_pdf,
        languages=languages,
        optimize=optimize,
        skip_text=skip_text,
        deskew=deskew,
        clean_final=clean_final,
        metadata=metadata,
        pdfa=pdfa
    )

    elapsed = time.time() - t0
    mins = int(elapsed // 60)
    secs = int(elapsed % 60)

    print()
    if ok:
        fsize = human_size(output_pdf)
        in_size = human_size(input_pdf)
        print(f"  {chr(10003)}  OCR completed successfully!")
        print(f"  Input:    {os.path.basename(input_pdf)}  ({in_size})")
        print(f"  Output:   {output_pdf}")
        print(f"  Size:     {fsize}")
        print(f"  Languages: {'+'.join(languages)}")
        print(f"  Time:     {mins}m {secs}s")
        print()
        print(f"  The PDF is now searchable! Open it and try Ctrl+F to search text.")
    else:
        print(f"  ERROR: {msg}")

        # Helpful hints for common failures
        if 'ghostscript' in msg.lower():
            print(f"\n  Tip: Retry with PDF/A disabled, or install Ghostscript:")
            print(f"  https://ghostscript.com/releases/gsdnld.html")

    print()
    input("Press Enter to close...")


def run_noninteractive():
    """Non-interactive run for the control panel (env: PDF_RUN_*).
    OCRs the newest non-OCR'd PDF in the folder into a searchable PDF."""
    pp = os.environ.get('PDF_RUN_PRESET', '')
    folder = os.environ.get('PDF_RUN_FOLDER', '')
    input_file = os.environ.get('PDF_RUN_INPUT_FILE', '')
    p = {}
    if pp and os.path.isfile(pp):
        with open(pp, encoding='utf-8-sig') as f:
            p = json.load(f)
    folder = folder or p.get('folderPath', '')
    input_file = input_file or p.get('inputFile', '')   # panel saves a chosen PDF here
    languages   = p.get('languages', ['eng'])
    optimize    = int(p.get('optimizeLevel', 1))
    skip_text   = bool(p.get('skipText', True))
    deskew      = bool(p.get('deskew', False))
    clean_final = bool(p.get('cleanFinal', False))
    out_suffix  = p.get('outputSuffix', '_ocr')
    pdfa        = bool(p.get('pdfaGeneration', True))
    metadata    = p.get('metadata', {})
    # A specific PDF was chosen in the panel -> OCR exactly that file.
    if input_file and os.path.isfile(input_file):
        input_pdf = input_file
        folder = folder if os.path.isdir(folder) else os.path.dirname(input_pdf)
    else:
        if not os.path.isdir(folder):
            print(f"ERROR: folder not found: {folder}", flush=True); return 1
        pdfs = [x for x in glob.glob(os.path.join(folder, '*.pdf'))
                if not os.path.splitext(os.path.basename(x))[0].endswith(out_suffix)]
        if not pdfs:
            print(f"ERROR: no input PDF in {folder} (run stage 03 first)", flush=True); return 1
        input_pdf = max(pdfs, key=os.path.getmtime)
    in_base = os.path.splitext(os.path.basename(input_pdf))[0]
    output_pdf = os.path.join(folder, f"{in_base}{out_suffix}.pdf")
    if os.path.normcase(output_pdf) == os.path.normcase(input_pdf):
        output_pdf = os.path.join(folder, f"{in_base}{out_suffix}_out.pdf")
    if os.path.exists(output_pdf):
        ts = time.strftime('%Y%m%d_%H%M%S')
        output_pdf = os.path.join(folder, f"{in_base}{out_suffix}_{ts}.pdf")
    print(f"OCR: {os.path.basename(input_pdf)}  ->  {os.path.basename(output_pdf)}  "
          f"langs {'+'.join(languages)}", flush=True)
    ok, msg = run_ocr(input_pdf, output_pdf, languages=languages, optimize=optimize,
                      skip_text=skip_text, deskew=deskew, clean_final=clean_final,
                      metadata=metadata, pdfa=pdfa)
    if ok:
        print(f"DONE: {output_pdf}  ({human_size(output_pdf)})", flush=True)
        return 0
    print(f"ERROR: {msg}", flush=True)
    return 1


if __name__ == '__main__':
    if os.environ.get('PDF_RUN'):
        try:
            sys.exit(run_noninteractive())
        except Exception as _e:
            print(f"ERROR: {_e}", flush=True); sys.exit(1)
    _log_path = os.path.join(
        os.environ.get('TEMP', '.'), '04_ocr_crash.log'
    )
    try:
        main()
    except Exception as e:
        import traceback
        err_text = traceback.format_exc()
        # Print to screen
        print("\n" + "=" * 56)
        print("  CRASH — unhandled exception:")
        print("=" * 56)
        print(err_text)
        # Also save to file
        try:
            with open(_log_path, 'w', encoding='utf-8') as _f:
                _f.write(err_text)
            print(f"  Crash log saved to: {_log_path}")
        except: pass
        print()
        input("Press Enter to close...")
