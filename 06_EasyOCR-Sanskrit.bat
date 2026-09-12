@echo off
rem ============================================================
rem  06_EasyOCR-Sanskrit.bat - EasyOCR (local, in-process)
rem  Transcribe Devanagari (Sanskrit / Hindi) page images to .txt
rem  using EasyOCR's detection + recognition models on CPU via
rem  PyTorch. Fully local - no server, no Ollama, no Docker.
rem
rem  Devanagari ('hi') covers Sanskrit / Hindi / Marathi / Nepali.
rem  Models download once (~tens of MB) then run offline.
rem
rem  Requires: Python 3.x, easyocr (auto-installs on first run)
rem  Creates:  one .txt per image and/or a combined transcription
rem ============================================================
setlocal
set "BATFILE=%~f0"
set "PATH=%PATH%;C:\Program Files\Tesseract-OCR;C:\Program Files (x86)\Tesseract-OCR"

if not exist "%~dp0_internal\_versions\" mkdir "%~dp0_internal\_versions\"
for /f "tokens=*" %%T in ('powershell -NoProfile -Command "Get-Date -Format 'yyyy-MM-dd_HHmmss'"') do set "_BKTS=%%T"
copy /y "%~f0" "%~dp0_internal\_versions\%~n0_%_BKTS%.bat" >nul 2>&1

python --version >nul 2>&1 || (echo Python not found. Install from https://python.org & pause & exit /b 1)
python -c "import easyocr" >nul 2>&1 || (echo Installing EasyOCR ^(pulls PyTorch, one time^)... & pip install easyocr || (echo Failed. Run: pip install easyocr & pause & exit /b 1))
python -c "import fitz" >nul 2>&1 || (echo Installing PyMuPDF ^(for PDF input^)... & pip install pymupdf)
python -c "import reportlab" >nul 2>&1 || (echo Installing reportlab ^(for searchable PDF^)... & pip install reportlab)

set "TMPPY=%TEMP%\easyocr_06.py"
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$f=$env:BATFILE;$l=[IO.File]::ReadAllLines($f);$s=0;for($i=0;$i-lt$l.Count;$i++){if($l[$i]-eq'#PY_BEGIN'){$s=$i+1;break}};[IO.File]::WriteAllLines($env:TMPPY,$l[$s..($l.Count-1)],[Text.Encoding]::UTF8)"

python "%TMPPY%"
del "%TMPPY%" >nul 2>&1
if not defined PDF_RUN pause >nul
exit /b
#PY_BEGIN
#!/usr/bin/env python3
"""
06 EasyOCR (Sanskrit / Devanagari)  v1.0
Local, in-process OCR via EasyOCR. Detects + recognises text on CPU
through PyTorch - no server, no Ollama, no Docker.
Output: one .txt per image and/or a single combined .txt.
"""

import os
import sys
import json
import glob
import re
import time
import shutil

# Suppress the Windows "Application Error" pop-up if a child process (e.g.
# Ghostscript, used for PDF/A) fails to initialize. Child procs inherit this.
if os.name == "nt":
    try:
        import ctypes
        ctypes.windll.kernel32.SetErrorMode(0x0001 | 0x0002 | 0x8000)
    except Exception:
        pass

try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass

VERSION = "1.0"
CHANGELOG = """
v1.0  2026-06-03  Initial release - EasyOCR (local, in-process)
                  Devanagari (Sanskrit/Hindi) + other scripts
                  Replaces the IndicOCR / VLM (Ollama) stage
                  Outputs .txt transcription per page or combined
"""

IMAGE_EXTS = ('.jpg', '.jpeg', '.png', '.bmp', '.tif', '.tiff', '.webp')
PDF_EXTS   = ('.pdf',)


def pdf_to_images(pdf_path, out_dir, dpi=300):
    """Extract PDF pages as JPEG images. Returns list of image paths."""
    import fitz
    doc = fitz.open(pdf_path)
    paths = []
    for i in range(len(doc)):
        pix = doc[i].get_pixmap(dpi=dpi)
        img_path = os.path.join(out_dir, f"page_{i+1:04d}.jpg")
        pix.save(img_path)
        paths.append(img_path)
    doc.close()
    return paths


def script_folder():
    bat = os.environ.get('BATFILE', '')
    return os.path.dirname(bat) if bat else os.path.dirname(os.path.abspath(__file__))

ROOT = script_folder()
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)

try:
    from _internal.easyocr_engine import (
        check_dependencies, create_reader, ocr_page, ocr_page_detailed,
        build_searchable_pdf, convert_to_pdfa, parse_langs, restrict_to_best_gpu,
    )
except ImportError as e:
    print(f"  ERROR: cannot load EasyOCR engine from _internal/easyocr_engine.py: {e}")
    if not os.environ.get('PDF_RUN'):
        input("Press Enter to exit...")
    sys.exit(1)


def use_gpu():
    """Return True if torch CUDA is available, else False."""
    try:
        import torch
        return torch.cuda.is_available()
    except Exception:
        return False


def resolve_gpu(device):
    """device = 'auto' | 'gpu' | 'cpu' -> bool for EasyOCR's gpu= argument.
    Prints a clear note if GPU was asked for but CUDA isn't available."""
    device = (device or 'auto').lower()
    if device == 'cpu':
        return False
    avail = use_gpu()
    if device == 'gpu' and not avail:
        print("  NOTE: GPU requested but PyTorch has no CUDA. Install the CUDA"
              " build:  pip install torch torchvision --index-url"
              " https://download.pytorch.org/whl/cu121   (falling back to CPU)",
              flush=True)
    if device == 'gpu':
        return avail        # True only if CUDA really present
    return avail            # 'auto'


# ════════════════════════════════════════════════════════════
#  Preset helpers  (eocr_preset_01_desc.json)
# ═══════════════════════════════════════════════════════════

def preset_folder():
    pf = os.path.join(ROOT, '00_PRESETS')
    os.makedirs(pf, exist_ok=True)
    return pf

def list_eocr_presets():
    out = []
    for f in sorted(glob.glob(os.path.join(preset_folder(), 'eocr_preset_*.json'))):
        try:
            with open(f, encoding='utf-8-sig') as fp:
                d = json.load(fp); d['_file'] = f; out.append(d)
        except Exception:
            pass
    return out

def next_eocr_num():
    nums = []
    for f in glob.glob(os.path.join(preset_folder(), 'eocr_preset_*.json')):
        m = re.match(r'eocr_preset_(\d+)_', os.path.basename(f))
        if m:
            nums.append(int(m.group(1)))
    return max(nums, default=0) + 1

def save_eocr_preset(desc, folder_path, settings):
    num = next_eocr_num()
    safe = re.sub(r'[^a-zA-Z0-9 _-]', '', desc).strip()
    safe = re.sub(r'\s+', '_', safe).lower()
    safe = re.sub(r'_+', '_', safe).strip('_') or 'eocr'
    fname = f'eocr_preset_{num:02d}_{safe}.json'
    data = {'description': desc, 'folderPath': folder_path, **settings}
    with open(os.path.join(preset_folder(), fname), 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    print(f"  Saved as: {fname}")

def show_eocr_preset_menu():
    presets = list_eocr_presets()
    if not presets:
        return None
    print(f"\nSaved EasyOCR presets ({len(presets)} found):")
    print("  " + chr(9472) * 70)
    for i, p in enumerate(presets, 1):
        fname = os.path.splitext(os.path.basename(p['_file']))[0]
        lang = p.get('language', 'hi')
        folder = os.path.basename(p.get('folderPath', '')) or chr(8212)
        print(f"  [{i}] {fname:<40} {lang:<8} {folder}")
    print("  [0] Skip - enter settings manually")
    while True:
        raw = input(f"\nEnter preset number (0-{len(presets)}): ").strip()
        try:
            n = int(raw)
            if 0 <= n <= len(presets):
                return None if n == 0 else presets[n - 1]
        except Exception:
            pass
        print(f"  Please enter a number between 0 and {len(presets)}.")

# ═══════════════════════════════════════════════════════════
#  UI helpers
# ═══════════════════════════════════════════════════════════

def clear():
    os.system('cls' if os.name == 'nt' else 'clear')

def print_header():
    clear()
    print("=" * 56)
    print(f"  EasyOCR (Sanskrit / Devanagari)  v{VERSION}")
    print(f"  Local, in-process OCR - no server, no Ollama")
    print("=" * 56)
    for line in CHANGELOG.strip().split('\n'):
        print(f"  {line}")
    print()

def yn(prompt, default_yes=True):
    tag = "[Y/n]" if default_yes else "[y/N]"
    raw = input(f"{prompt} {tag}: ").strip().lower()
    return default_yes if not raw else raw.startswith('y')

def collect_images(folder, sort_order='name-asc'):
    files = [os.path.join(folder, fn) for fn in os.listdir(folder)
             if fn.lower().endswith(IMAGE_EXTS)]
    files.sort(key=lambda p: os.path.getmtime(p) if sort_order.startswith('date')
               else os.path.basename(p).lower())
    if sort_order.endswith('-desc'):
        files.reverse()
    return files

# ═══════════════════════════════════════════════════════════
#  Main (interactive)
# ═══════════════════════════════════════════════════════════

def main():
    print_header()
    print("Dependencies:")
    for name, (ok, detail) in check_dependencies().items():
        print(f"  {'[OK]' if ok else '[ -]'} {name:<16} {detail}")

    preset = show_eocr_preset_menu()

    # Folder / single file
    folder = None
    input_file = None
    batch = False
    if preset:
        fp = preset.get('folderPath', '')
        if fp and os.path.isdir(fp):
            print(f"\nPreset folder: {fp}")
            if yn("Use this folder?", True):
                folder = fp
                print("Using preset folder.")
        if preset.get('inputSource') == 'batch':
            batch = True
    if folder is None:
        print(f"\n-- Input ----------------------------------------------------")
        print("  [1] Folder (OCR every image -> one PDF)")
        print("  [2] Single image file")
        print("  [3] Single PDF file (extracts + OCRs every page)")
        print("  [4] Batch: each SUBFOLDER -> its own <folder>_searchable.pdf")
        c = input("Mode [default 1]: ").strip() or '1'
        if c == '2':
            raw = input("Image file path: ").strip().strip('"')
            if not raw or not os.path.isfile(raw):
                print(f"File not found: {raw}"); input("Press Enter to exit..."); return
            input_file = raw
            folder = os.path.dirname(raw)
        elif c == '3':
            raw = input("PDF file path: ").strip().strip('"')
            if not raw or not os.path.isfile(raw):
                print(f"File not found: {raw}"); input("Press Enter to exit..."); return
            input_file = raw
            folder = os.path.dirname(raw)
        elif c == '4':
            batch = True
            raw = input(f"Parent folder (Enter = {ROOT}): ").strip().strip('"')
            folder = raw or ROOT
            if not os.path.isdir(folder):
                print(f"Folder not found: {folder}"); input("Press Enter to exit..."); return
        else:
            raw = input(f"Folder path (Enter = {ROOT}): ").strip().strip('"')
            folder = raw or ROOT
            if not os.path.isdir(folder):
                print(f"Folder not found: {folder}"); input("Press Enter to exit..."); return

    # Settings
    if preset:
        language   = preset.get('language', 'hi')
        paragraph  = bool(preset.get('paragraph', False))
        out_mode   = preset.get('outputMode', 'none')
        make_pdf   = bool(preset.get('searchablePdf', True))
        pdf_name   = (preset.get('pdfFilename') or 'searchable.pdf').strip() or 'searchable.pdf'
        if not pdf_name.lower().endswith('.pdf'):
            pdf_name += '.pdf'
        pdf_quality= int(preset.get('pdfQuality', 55))
        pdf_maxdim = int(preset.get('pdfMaxDim', 2000))
        pdf_pagedpi= int(preset.get('pdfPageDpi', 150))
        ocr_dpi    = int(preset.get('ocrDpi', 300))
        make_pdfa  = bool(preset.get('pdfa', False))
        skip_exist = bool(preset.get('skipExisting', True))
        sort_order = preset.get('sortOrder', 'name-asc')
        suffix     = preset.get('outputSuffix', '')
        combined   = preset.get('combinedFilename', 'transcription.txt')
        device     = preset.get('device') or ('gpu' if preset.get('useGpu', True) else 'cpu')
        print(f"\nPreset: lang {language}  |  searchable PDF {make_pdf}  |  .txt {out_mode}")
    else:
        print("\n-- Language (EasyOCR codes) ---------------------------------")
        print("  hi    = Devanagari (Sanskrit / Hindi)   [recommended]")
        print("  hi,en = Devanagari + English")
        print("  mr / ne = Marathi / Nepali (also Devanagari)")
        language = input("Language [default hi]: ").strip() or 'hi'
        make_pdf = yn("Make a combined searchable PDF?", True)
        pdf_name = "searchable.pdf"
        pdf_quality = 55
        pdf_maxdim  = 2000
        pdf_pagedpi = 150
        ocr_dpi     = 300
        make_pdfa = yn("Also convert to PDF/A (archival; needs Ghostscript)?", False) if make_pdf else False
        c = input("Also write .txt - [0] no [1] per-page [2] combined [3] both [default 0]: ").strip() or '0'
        out_mode = {'0': 'none', '1': 'per-page', '2': 'combined', '3': 'both'}.get(c, 'none')
        paragraph  = yn("Group words into paragraphs?", False)
        suffix     = input("Per-page .txt suffix [default none]: ").strip()
        combined   = "transcription.txt"
        skip_exist = yn("Skip .txt that already exists?", True)
        sort_order = 'name-asc'
        device = 'gpu' if yn("Use GPU (if available)?", True) else 'cpu'

    if device != 'cpu':
        sel = preset.get('gpuDevices') if preset else None
        if sel:
            os.environ["CUDA_DEVICE_ORDER"] = "PCI_BUS_ID"
            os.environ["CUDA_VISIBLE_DEVICES"] = ",".join(str(x) for x in sel)
            print(f"  Using GPU(s): {os.environ['CUDA_VISIBLE_DEVICES']}")
        else:
            bi = restrict_to_best_gpu()
            if bi is not None:
                print(f"  Pinned to GPU index {bi} (highest memory)")
    gpu = resolve_gpu(device)
    print(f"\n  Loading EasyOCR ({language}) on {'GPU' if gpu else 'CPU'} ...")
    try:
        reader = create_reader(parse_langs(language), gpu=gpu, verbose=True)
    except Exception as e:
        print(f"  Failed to load EasyOCR: {e}")
        input("Press Enter to exit..."); return
    print("  Ready.\n")

    log = lambda m: print(m)
    opts = {
        'paragraph': paragraph, 'out_mode': out_mode, 'make_pdf': make_pdf,
        'skip_exist': skip_exist, 'suffix': suffix, 'combined': combined,
        'pdf_quality': pdf_quality, 'pdf_maxdim': pdf_maxdim,
        'pdf_pagedpi': pdf_pagedpi, 'make_pdfa': make_pdfa, 'pdf_stem': None,
    }
    t0 = time.time()
    ok = failed = skipped = 0

    if batch:
        subs = subfolders_with_images(folder)
        if not subs:
            print(f"  No subfolders with images under: {folder}")
            input("Press Enter to exit..."); return
        print(f"  Batch: {len(subs)} subfolder(s).\n")
        for si, sub in enumerate(subs, 1):
            name = os.path.basename(os.path.normpath(sub))
            imgs = collect_images(sub, sort_order)
            out_pdf = os.path.join(sub, f"{name}_searchable.pdf")
            print(f"\n  === [{si}/{len(subs)}] {name}: {len(imgs)} image(s) ===")
            o, f_, s = process_image_set(imgs, sub, reader, opts, out_pdf, log=log)
            ok += o; failed += f_; skipped += s
    else:
        tmp_pdf_dir = None
        if input_file and input_file.lower().endswith(PDF_EXTS):
            opts['pdf_stem'] = os.path.splitext(os.path.basename(input_file))[0]
            tmp_pdf_dir = os.path.join(folder, f"_eocr_tmp_{int(time.time())}")
            os.makedirs(tmp_pdf_dir, exist_ok=True)
            print(f"  Extracting PDF pages @ {ocr_dpi} DPI ...")
            images = pdf_to_images(input_file, tmp_pdf_dir, dpi=ocr_dpi)
        elif input_file:
            images = [input_file]
        else:
            images = collect_images(folder, sort_order)
        if not images:
            print(f"  No images found in: {folder}")
            if tmp_pdf_dir:
                shutil.rmtree(tmp_pdf_dir, ignore_errors=True)
            input("Press Enter to exit..."); return
        print(f"  {len(images)} page(s) to process.\n")
        stem = opts['pdf_stem']
        out_pdf = os.path.join(folder, f"{stem}_searchable.pdf" if stem else pdf_name)
        ok, failed, skipped = process_image_set(images, folder, reader, opts, out_pdf, log=log)
        if tmp_pdf_dir:
            shutil.rmtree(tmp_pdf_dir, ignore_errors=True)

    print(f"\n  Done. {ok} ok, {failed} failed, {skipped} skipped  in {time.time()-t0:.0f}s.")
    if ok:
        print(f"  Output folder: {folder}")

    if not preset and ok > 0 and yn("\nSave these settings as a preset?", False):
        desc = input("  Short description (e.g. 'sanskrit pages'): ").strip() or 'sanskrit'
        save_eocr_preset(desc, folder, {
            'inputSource': ('batch' if batch else 'images'),
            'language': language, 'paragraph': paragraph, 'outputMode': out_mode,
            'searchablePdf': make_pdf, 'pdfFilename': pdf_name, 'pdfa': make_pdfa,
            'pdfQuality': pdf_quality, 'pdfMaxDim': pdf_maxdim,
            'pdfPageDpi': pdf_pagedpi, 'ocrDpi': ocr_dpi,
            'outputSuffix': suffix, 'combinedFilename': combined,
            'skipExisting': skip_exist, 'sortOrder': sort_order,
            'useGpu': (device == 'gpu'),
        })

    if not os.environ.get('PDF_RUN'):
        input("\nPress Enter to close...")

# ═══════════════════════════════════════════════════════════
#  Shared OCR worker (one image set -> optional .txt + searchable PDF)
# ═══════════════════════════════════════════════════════════

def process_image_set(images, out_folder, reader, opts, out_pdf, log=print):
    """OCR a list of images; write optional .txt and a searchable PDF (+PDF/A).
    out_pdf is the full path of the searchable PDF to create.
    Returns (ok, failed, skipped)."""
    paragraph   = opts['paragraph'];   out_mode   = opts['out_mode']
    make_pdf    = opts['make_pdf'];     skip_exist = opts['skip_exist']
    suffix      = opts['suffix'];       combined   = opts['combined']
    pdf_quality = opts['pdf_quality'];  pdf_maxdim = opts['pdf_maxdim']
    pdf_pagedpi = opts['pdf_pagedpi'];  make_pdfa  = opts['make_pdfa']
    pdf_stem    = opts.get('pdf_stem')
    txt_parts = []
    pdf_pages = []
    ok = failed = skipped = 0
    n = len(images)
    for i, img in enumerate(images, 1):
        stem = os.path.splitext(os.path.basename(img))[0]
        base = f"{pdf_stem}_p{i:03d}" if pdf_stem else stem
        txt_path = os.path.join(out_folder, f"{base}{suffix}.txt")
        if (not make_pdf and skip_exist and out_mode in ('per-page', 'both')
                and os.path.isfile(txt_path)):
            skipped += 1
            log(f"[{i}/{n}] skip {os.path.basename(img)} (exists)")
            continue
        log(f"[{i}/{n}] {os.path.basename(img)} ...")
        try:
            boxes = ocr_page_detailed(reader, img, paragraph=paragraph)
            text = "\n".join(t for _, t in boxes)
            if out_mode in ('per-page', 'both'):
                with open(txt_path, 'w', encoding='utf-8') as f:
                    f.write(text + "\n")
            if out_mode in ('combined', 'both'):
                txt_parts.append(f"# {base}\n{text}\n")
            if make_pdf:
                pdf_pages.append((img, boxes))
            ok += 1
        except Exception as e:
            failed += 1
            log(f"  FAILED: {e}")

    if out_mode in ('combined', 'both') and txt_parts:
        cname = f"{pdf_stem}{suffix}.txt" if pdf_stem else combined
        with open(os.path.join(out_folder, cname), 'w', encoding='utf-8') as f:
            f.write("\n".join(txt_parts))

    if make_pdf and pdf_pages:
        log(f"Building searchable PDF ({len(pdf_pages)} pages) -> "
            f"{os.path.basename(out_pdf)}")
        try:
            build_searchable_pdf(pdf_pages, out_pdf, log=log,
                                 quality=pdf_quality, max_dim=pdf_maxdim,
                                 page_dpi=pdf_pagedpi)
            log(f"  Searchable PDF: {out_pdf}")
            if make_pdfa:
                pdfa_out = os.path.splitext(out_pdf)[0] + "_pdfa.pdf"
                log(f"Converting to PDF/A -> {os.path.basename(pdfa_out)}")
                try:
                    convert_to_pdfa(out_pdf, pdfa_out, log=log)
                    log(f"  PDF/A: {pdfa_out}")
                except Exception as e:
                    log(f"  PDF/A conversion FAILED: {e}")
        except Exception as e:
            log(f"  PDF build FAILED: {e}")
            failed += 1
    return ok, failed, skipped


def subfolders_with_images(parent):
    """Immediate subfolders of `parent` that contain at least one image,
    sorted by name. (Skips our own temp dirs.)"""
    out = []
    for d in sorted(os.listdir(parent)):
        sub = os.path.join(parent, d)
        if not os.path.isdir(sub) or d.startswith('_eocr_tmp_'):
            continue
        if collect_images(sub, 'name-asc'):
            out.append(sub)
    return out


# ═══════════════════════════════════════════════════════════
#  Non-interactive runner (control panel)
# ═══════════════════════════════════════════════════════════

def run_noninteractive():
    pp = os.environ.get('PDF_RUN_PRESET', '')
    input_file = os.environ.get('PDF_RUN_INPUT_FILE', '')
    folder = os.environ.get('PDF_RUN_FOLDER', '')
    p = {}
    if pp and os.path.isfile(pp):
        with open(pp, encoding='utf-8-sig') as f:
            p = json.load(f)
    folder = folder or p.get('folderPath', '')
    input_file = input_file or p.get('inputFile', '')   # panel saves it in the preset
    if not os.path.isdir(folder):
        if input_file and os.path.isfile(input_file):
            folder = os.path.dirname(input_file)
        else:
            print(f"ERROR: folder not found: {folder}", flush=True); return 1

    input_source = p.get('inputSource', 'images')   # 'images' | 'pdf' | 'batch'
    language   = p.get('language', 'hi')
    paragraph  = bool(p.get('paragraph', False))
    out_mode   = p.get('outputMode', 'none')          # none|per-page|combined|both (.txt)
    make_pdf   = bool(p.get('searchablePdf', True))    # combined searchable PDF
    pdf_name   = (p.get('pdfFilename') or 'searchable.pdf').strip() or 'searchable.pdf'
    if not pdf_name.lower().endswith('.pdf'):
        pdf_name += '.pdf'
    pdf_quality= int(p.get('pdfQuality', 55))          # embedded image JPEG quality
    pdf_maxdim = int(p.get('pdfMaxDim', 2000))         # cap longest edge px (size)
    pdf_pagedpi= int(p.get('pdfPageDpi', 150))         # page physical size DPI
    ocr_dpi    = int(p.get('ocrDpi', 300))             # rasterize input PDF at this
    make_pdfa  = bool(p.get('pdfa', False))            # also convert to PDF/A
    skip_exist = bool(p.get('skipExisting', True))

    # Guard: warn if the run would produce NO output at all (this is exactly the
    # "it finished but where's the file?" case - searchable PDF off + .txt none).
    if not make_pdf and out_mode == 'none':
        print("WARNING: no output selected (searchable PDF is OFF and 'write .txt' "
              "is none) - this run will not save anything.", flush=True)
        print("         Enable 'Make combined searchable PDF' to get searchable.pdf.",
              flush=True)
    sort_order = p.get('sortOrder', 'name-asc')
    suffix     = p.get('outputSuffix', '')
    combined   = p.get('combinedFilename', 'transcription.txt')
    device     = p.get('device') or ('gpu' if p.get('useGpu', True) else 'cpu')

    if device != 'cpu':
        sel = p.get('gpuDevices')        # explicit checkbox selection from the panel
        if sel:
            os.environ["CUDA_DEVICE_ORDER"] = "PCI_BUS_ID"
            os.environ["CUDA_VISIBLE_DEVICES"] = ",".join(str(x) for x in sel)
            print(f"Using GPU(s): {os.environ['CUDA_VISIBLE_DEVICES']}", flush=True)
        else:
            bi = restrict_to_best_gpu()  # auto: pin to the highest-memory GPU
            if bi is not None:
                print(f"Pinned to GPU index {bi} (highest memory)", flush=True)
    gpu = resolve_gpu(device)
    print(f"Loading EasyOCR ({language}) on {'GPU' if gpu else 'CPU'}...", flush=True)
    reader = create_reader(parse_langs(language), gpu=gpu, verbose=True)

    log = lambda m: print(m, flush=True)
    opts = {
        'paragraph': paragraph, 'out_mode': out_mode, 'make_pdf': make_pdf,
        'skip_exist': skip_exist, 'suffix': suffix, 'combined': combined,
        'pdf_quality': pdf_quality, 'pdf_maxdim': pdf_maxdim,
        'pdf_pagedpi': pdf_pagedpi, 'make_pdfa': make_pdfa, 'pdf_stem': None,
    }

    # ── Batch mode: each subfolder -> its own <foldername>_searchable.pdf ────
    if input_source == 'batch':
        subs = subfolders_with_images(folder)
        if not subs:
            print(f"ERROR: no subfolders with images under {folder}", flush=True)
            return 1
        print(f"Batch: {len(subs)} subfolder(s) under "
              f"{os.path.basename(os.path.normpath(folder))}", flush=True)
        tot_ok = tot_fail = tot_skip = 0
        for si, sub in enumerate(subs, 1):
            name = os.path.basename(os.path.normpath(sub))
            imgs = collect_images(sub, sort_order)
            out_pdf = os.path.join(sub, f"{name}_searchable.pdf")
            print(f"\n=== [{si}/{len(subs)}] {name}: {len(imgs)} image(s) ===", flush=True)
            o, f_, s = process_image_set(imgs, sub, reader, opts, out_pdf, log=log)
            tot_ok += o; tot_fail += f_; tot_skip += s
        print(f"\nDONE (batch): {len(subs)} folder(s) | {tot_ok} ok, "
              f"{tot_fail} failed, {tot_skip} skipped  ->  {folder}", flush=True)
        return 0 if tot_fail == 0 else 1

    # ── Single folder / single file ─────────────────────────────────────────
    tmp_pdf_dir = None
    if input_source == 'pdf':
        if not (input_file and os.path.isfile(input_file)):
            print(f"ERROR: input source = PDF but no valid file selected: "
                  f"{input_file!r}", flush=True)
            return 1
        if input_file.lower().endswith(PDF_EXTS):
            opts['pdf_stem'] = os.path.splitext(os.path.basename(input_file))[0]
            tmp_pdf_dir = os.path.join(folder, f"_eocr_tmp_{int(time.time())}")
            os.makedirs(tmp_pdf_dir, exist_ok=True)
            images = pdf_to_images(input_file, tmp_pdf_dir, dpi=ocr_dpi)
            print(f"EasyOCR ({language}): PDF {os.path.basename(input_file)}  "
                  f"({len(images)} pages @ {ocr_dpi} DPI)", flush=True)
        else:
            images = [input_file]
    else:
        images = collect_images(folder, sort_order)
        print(f"EasyOCR ({language}): images folder "
              f"{os.path.basename(os.path.normpath(folder))}", flush=True)
    if not images:
        print(f"ERROR: no images in {folder}", flush=True)
        if tmp_pdf_dir:
            shutil.rmtree(tmp_pdf_dir, ignore_errors=True)
        return 1

    stem = opts['pdf_stem']
    out_pdf = os.path.join(folder, f"{stem}_searchable.pdf" if stem else pdf_name)
    ok, failed, skipped = process_image_set(images, folder, reader, opts, out_pdf, log=log)

    if tmp_pdf_dir:
        shutil.rmtree(tmp_pdf_dir, ignore_errors=True)
    print(f"DONE: {ok} ok, {failed} failed, {skipped} skipped  ->  {folder}", flush=True)
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    if os.environ.get('PDF_RUN'):
        try:
            sys.exit(run_noninteractive())
        except Exception as _e:
            print(f"ERROR: {_e}", flush=True)
            sys.exit(1)
    try:
        main()
    except KeyboardInterrupt:
        print("\n  Cancelled.")
    except Exception as e:
        print(f"\n  ERROR: {e}")
        import traceback
        traceback.print_exc()
        input("Press Enter to exit...")
