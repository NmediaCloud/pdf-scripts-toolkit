@echo off
rem ============================================================
rem  03_Images-to-PDF.bat  —  Python / img2pdf edition
rem  Stitch all images in a folder into a single PDF
rem  Lossless JPEG embedding — zero re-encoding, zero quality loss
rem  Requires: Python 3.x  (auto-installs img2pdf, Pillow)
rem
rem  VERSION HISTORY
rem  v1.0  2026-03-30  Initial release — img2pdf lossless stitching
rem ============================================================
setlocal
set "BATFILE=%~f0"

rem ── Auto-backup this script to _versions\ ───────────────────
if not exist "%~dp0_internal\_versions\" mkdir "%~dp0_internal\_versions\"
for /f "tokens=*" %%T in ('powershell -NoProfile -Command "Get-Date -Format 'yyyy-MM-dd_HHmmss'"') do set "_BKTS=%%T"
copy /y "%~f0" "%~dp0_internal\_versions\%~n0_%_BKTS%.bat" >nul 2>&1

rem ── Check Python ────────────────────────────────────────────
python --version >nul 2>&1
if errorlevel 1 (
    echo.
    echo  ERROR: Python is not installed.
    echo  Please install Python 3.x from https://python.org
    echo  Make sure to check "Add Python to PATH" during install.
    echo.
    pause & exit /b 1
)

rem ── Install dependencies if missing ─────────────────────────
python -c "import img2pdf, PIL" >nul 2>&1
if errorlevel 1 (
    echo  Installing required packages: img2pdf Pillow
    pip install img2pdf Pillow
    if errorlevel 1 (
        echo  Failed. Please run manually:  pip install img2pdf Pillow
        pause & exit /b 1
    )
)

rem ── Extract Python section and run ──────────────────────────
set "TMPPY=%TEMP%\images_to_pdf_03.py"
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$f=$env:BATFILE;$l=[IO.File]::ReadAllLines($f);$s=0;for($i=0;$i-lt$l.Count;$i++){if($l[$i]-eq'#PY_BEGIN'){$s=$i+1;break}};[IO.File]::WriteAllLines($env:TMPPY,$l[$s..($l.Count-1)],[Text.Encoding]::UTF8)"

python "%TMPPY%"

del "%TMPPY%" >nul 2>&1

if errorlevel 1 (
    echo.
    echo  Script exited with an error. Press any key to close.
    if not defined PDF_RUN pause >nul
)
exit /b
#PY_BEGIN
#!/usr/bin/env python3
"""
03 Images to PDF  v1.0
Stitch all images in a folder into a single PDF.
Lossless JPEG embedding via img2pdf — zero re-encoding.
"""

import img2pdf
from PIL import Image
import os, sys, json, glob, re, time
from pathlib import Path

VERSION = "1.1"
CHANGELOG = """\
v1.0  2026-03-30  Initial release — img2pdf lossless stitching
                  Fit-to-image & fixed page size modes
                  DPI override for correct physical sizing
                  i2p presets  i2p_preset_XX_desc.json
v1.1  2026-06-16  Panel run now OVERWRITES the same output PDF instead of
                  making timestamped duplicates (a stale old PDF made it look
                  like sort order wasn't being applied)
v1.2  2026-06-17  Batch mode: each subfolder -> its own <folder>.pdf
"""

# Standard page sizes in mm
PAGE_SIZES = {
    'A4':      (210,   297),
    'A5':      (148,   210),
    'Letter':  (215.9, 279.4),
    'Legal':   (215.9, 355.6),
    'B5':      (176,   250),
}

# ═══════════════════════════════════════════════════════════
#  Core PDF conversion
# ═══════════════════════════════════════════════════════════

def collect_images(folder, sort_order='name-asc'):
    """Find all images in folder, deduplicate (case-insensitive), sort."""
    found = []
    for ext in ('*.jpg','*.jpeg','*.png','*.bmp','*.tif','*.tiff',
                '*.JPG','*.JPEG','*.PNG','*.BMP','*.TIF','*.TIFF'):
        found.extend(glob.glob(os.path.join(folder, ext)))
    seen = set(); images = []
    for f in sorted(found):
        k = f.lower()
        if k not in seen:
            seen.add(k); images.append(f)

    if sort_order == 'name-desc':
        images = list(reversed(images))
    elif sort_order == 'date-asc':
        images.sort(key=lambda f: os.path.getmtime(f))
    elif sort_order == 'date-desc':
        images.sort(key=lambda f: os.path.getmtime(f), reverse=True)
    # default: name-asc (already sorted)

    return images


def validate_images(images):
    """Check each image can be opened; return (valid_list, skipped_list)."""
    valid   = []
    skipped = []
    for img_path in images:
        try:
            with Image.open(img_path) as im:
                im.verify()          # quick structural check
            valid.append(img_path)
        except Exception as e:
            skipped.append((img_path, str(e)))
    return valid, skipped


def fix_image_if_needed(img_path):
    """
    img2pdf cannot handle RGBA PNGs, CMYK JPEGs, or interlaced PNGs.
    Convert problematic images to a temp RGB JPEG; return the path to use.
    Returns (path_to_use, needs_cleanup).
    """
    try:
        with Image.open(img_path) as im:
            mode  = im.mode
            fmt   = (im.format or '').upper()
            # Check for interlaced PNG
            interlaced = False
            if fmt == 'PNG':
                interlaced = im.info.get('interlace', 0) != 0

            if mode in ('RGBA', 'LA', 'PA'):
                # Alpha channel — composite onto white, save as temp JPEG
                rgb = Image.new('RGB', im.size, (255, 255, 255))
                rgb.paste(im, mask=im.split()[-1])
                tmp = img_path + '.tmp_rgb.jpg'
                rgb.save(tmp, 'JPEG', quality=95)
                return tmp, True
            elif mode == 'CMYK':
                rgb = im.convert('RGB')
                tmp = img_path + '.tmp_rgb.jpg'
                rgb.save(tmp, 'JPEG', quality=95)
                return tmp, True
            elif interlaced:
                # Re-save without interlace
                tmp = img_path + '.tmp_nointerlace.png'
                im.save(tmp, 'PNG')
                return tmp, True

        return img_path, False
    except:
        return img_path, False


def get_image_dpi(img_path, default_dpi=300):
    """Read DPI from image metadata; return default if missing or weird."""
    try:
        with Image.open(img_path) as im:
            dpi = im.info.get('dpi', (0, 0))
            if isinstance(dpi, tuple) and len(dpi) >= 2:
                x_dpi = float(dpi[0])
                if 50 < x_dpi < 2400:   # sane range
                    return x_dpi
    except:
        pass
    return default_dpi


def build_layout(mode, fixed_size='A4', orientation='portrait', dpi=300):
    """
    Build an img2pdf layout_fun.

    mode='fit-to-image' — page size = image size at the given DPI
    mode='fixed'        — page = fixed_size, image fitted inside
    """
    if mode == 'fixed':
        pw_mm, ph_mm = PAGE_SIZES.get(fixed_size, PAGE_SIZES['A4'])
        if orientation == 'landscape':
            pw_mm, ph_mm = ph_mm, pw_mm
        pw_pt = pw_mm * 72.0 / 25.4
        ph_pt = ph_mm * 72.0 / 25.4
        layout = img2pdf.get_layout_fun(
            pagesize=(pw_pt, ph_pt),
            imgsize=None,
            border=None,
            fit=img2pdf.FitMode.into,
            auto_orient=True
        )
        return layout
    else:
        # fit-to-image: use the given DPI to compute physical page size
        layout = img2pdf.get_layout_fun(
            pagesize=None,
            imgsize=None,
            border=None,
            fit=img2pdf.FitMode.into,
            auto_orient=False
        )
        return layout


def images_to_pdf(images, output_path, layout_fun=None, dpi=300):
    """
    Convert a list of image paths to a single PDF.
    Uses img2pdf for lossless JPEG embedding.
    Returns (success, message).
    """
    # Fix problematic images (RGBA, CMYK, interlaced)
    paths_to_use = []
    temps        = []
    for img in images:
        p, needs_cleanup = fix_image_if_needed(img)
        paths_to_use.append(p)
        if needs_cleanup:
            temps.append(p)

    try:
        # Build img2pdf kwargs
        kwargs = {}
        if layout_fun is not None:
            kwargs['layout_fun'] = layout_fun

        # For fit-to-image mode, override DPI in each image so page sizing is correct
        # img2pdf uses the image's own DPI; if missing it can produce giant pages
        # We pass a dpix/dpiy to force consistent sizing
        pdf_bytes = img2pdf.convert(
            paths_to_use,
            **kwargs
        )

        with open(output_path, 'wb') as f:
            f.write(pdf_bytes)

        size_mb = os.path.getsize(output_path) / (1024 * 1024)
        return True, f"{size_mb:.1f} MB"

    except img2pdf.PdfTooLargeError:
        # DPI metadata missing — pages would be absurdly large
        # Retry with explicit DPI
        try:
            dpix = dpiy = dpi
            pdf_bytes = img2pdf.convert(
                paths_to_use,
                layout_fun=img2pdf.get_layout_fun(
                    pagesize=None, imgsize=None, border=None,
                    fit=img2pdf.FitMode.into, auto_orient=False
                )
            )
            with open(output_path, 'wb') as f:
                f.write(pdf_bytes)
            size_mb = os.path.getsize(output_path) / (1024 * 1024)
            return True, f"{size_mb:.1f} MB (DPI fallback)"
        except Exception as e2:
            return False, f"PdfTooLargeError retry failed: {e2}"

    except Exception as e:
        return False, str(e)

    finally:
        # Cleanup temp files
        for t in temps:
            try: os.remove(t)
            except: pass


# ═══════════════════════════════════════════════════════════
#  I2P Preset helpers  (i2p_preset_01_desc.json)
# ═══════════════════════════════════════════════════════════

def script_folder():
    bat = os.environ.get('BATFILE', '')
    return os.path.dirname(bat) if bat else os.path.dirname(os.path.abspath(__file__))

def preset_folder():
    pf = os.path.join(script_folder(), '00_PRESETS')
    os.makedirs(pf, exist_ok=True)
    return pf


def list_i2p_presets():
    files  = sorted(glob.glob(os.path.join(preset_folder(), 'i2p_preset_*.json')))
    result = []
    for f in files:
        try:
            with open(f, encoding='utf-8') as fp:
                d = json.load(fp); d['_file'] = f; result.append(d)
        except: pass
    return result


def next_i2p_num():
    nums = []
    for f in glob.glob(os.path.join(preset_folder(), 'i2p_preset_*.json')):
        m = re.match(r'i2p_preset_(\d+)_', os.path.basename(f))
        if m: nums.append(int(m.group(1)))
    return max(nums, default=0) + 1


def save_i2p_preset(desc, folder_path, settings):
    num  = next_i2p_num()
    safe = re.sub(r'[^a-zA-Z0-9 _-]', '', desc).strip()
    safe = re.sub(r'\s+', '_', safe).lower()
    safe = re.sub(r'_+', '_', safe).strip('_') or 'i2p'
    fname = f'i2p_preset_{num:02d}_{safe}.json'
    data  = {'description': desc, 'folderPath': folder_path, **settings}
    with open(os.path.join(preset_folder(), fname), 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2)
    print(f"  Saved as: {fname}")


def show_i2p_preset_menu():
    presets = list_i2p_presets()
    if not presets: return None
    print(f"\nSaved I2P presets ({len(presets)} found):")
    print(f"  {'#':<4} {'File':<38} {'Mode':<16} Folder")
    print("  " + chr(9472) * 74)
    for i, p in enumerate(presets, 1):
        fname  = os.path.splitext(os.path.basename(p['_file']))[0]
        mode   = p.get('pageSizeMode', 'fit-to-image')
        folder = os.path.basename(p.get('folderPath', '')) or chr(8212)
        print(f"  [{i}] {fname:<38} {mode:<16} {folder}")
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
    print(f"  Images to PDF  v{VERSION}")
    print(f"  Lossless JPEG stitching into a single PDF")
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
#  Main
# ═══════════════════════════════════════════════════════════

def main():
    print_header()

    # ── Preset? ──────────────────────────────────────────────
    preset = show_i2p_preset_menu()

    # ── Source folder ─────────────────────────────────────────
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
        print(f"\nSource folder (Enter = {suggested}):")
        raw    = input("Folder path: ").strip().strip('"')
        folder = raw or suggested
    if not os.path.isdir(folder):
        print(f"\n  Folder not found: {folder}")
        input("Press Enter to exit..."); return

    # ── Settings ──────────────────────────────────────────────
    if preset:
        page_mode   = preset.get('pageSizeMode', 'fit-to-image')
        fixed_size  = preset.get('fixedPageSize', 'A4')
        orientation = preset.get('fixedOrientation', 'portrait')
        dpi         = int(preset.get('dpi', 300))
        sort_order  = preset.get('sortOrder', 'name-asc')
        out_name    = preset.get('outputFilename', '')
        print(f"\nPreset settings:")
        print(f"  Page mode: {page_mode}  |  DPI: {dpi}  |  Sort: {sort_order}")
        if page_mode == 'fixed':
            print(f"  Page size: {fixed_size} {orientation}")
    else:
        # ── Page size mode ──────────────────────────────────
        print("\n-- Page size mode -----------------------------------------------")
        print("  [1] Fit to image  (page = image dimensions, recommended)")
        print("      Each page matches the image exactly. No borders, no scaling.")
        print("  [2] Fixed page    (A4 / Letter / etc, image fitted inside)")
        print("      Standard page size with the image centred on it.")
        pc = input("\nChoice (1-2) [default 1]: ").strip() or '1'
        page_mode = 'fixed' if pc == '2' else 'fit-to-image'

        fixed_size  = 'A4'
        orientation = 'portrait'
        if page_mode == 'fixed':
            print("\n  Available page sizes:")
            sizes = list(PAGE_SIZES.keys())
            for i, s in enumerate(sizes, 1):
                w, h = PAGE_SIZES[s]
                print(f"  [{i}] {s:<8}  ({w} x {h} mm)")
            sc = input(f"\nChoice (1-{len(sizes)}) [default 1]: ").strip() or '1'
            try:
                fixed_size = sizes[int(sc) - 1]
            except: fixed_size = 'A4'

            oc = input("\nOrientation — [1] Portrait  [2] Landscape  [default 1]: ").strip() or '1'
            orientation = 'landscape' if oc == '2' else 'portrait'

        # ── DPI ──────────────────────────────────────────────
        print("\n-- DPI (dots per inch) ------------------------------------------")
        print("  Controls the physical print size of each page.")
        print("  300 = standard print   150 = screen/ebook   72 = web")
        dpi = read_int("DPI", 72, 2400, 300)

        # ── Sort order ───────────────────────────────────────
        print("\n-- Sort order ---------------------------------------------------")
        print("  [1] Filename ascending   (A-Z, 001-999)  (recommended)")
        print("  [2] Filename descending  (Z-A, 999-001)")
        print("  [3] Date ascending       (oldest first)")
        print("  [4] Date descending      (newest first)")
        sc = input("\nChoice (1-4) [default 1]: ").strip() or '1'
        sort_order = {'1':'name-asc','2':'name-desc',
                      '3':'date-asc','4':'date-desc'}.get(sc, 'name-asc')

        # ── Output filename ──────────────────────────────────
        out_name = ''

        # ── Save preset? ─────────────────────────────────────
        if yn("\nSave these settings as an I2P preset?", False):
            desc = ''
            while not desc.strip():
                desc = input("  Short description (e.g. 'tamil book 300dpi'): ").strip()
            save_i2p_preset(desc, folder, {
                'pageSizeMode': page_mode, 'fixedPageSize': fixed_size,
                'fixedOrientation': orientation, 'dpi': dpi,
                'sortOrder': sort_order, 'outputFilename': out_name
            })

    # ── Batch mode? (each subfolder -> its own <folder>.pdf) ──
    batch = bool(preset and preset.get('inputSource') == 'batch')
    if not preset:
        batch = yn("\nBatch mode - one PDF per SUBFOLDER?", False)
    if batch:
        opts = {'page_mode': page_mode, 'fixed_size': fixed_size,
                'orientation': orientation, 'dpi': dpi, 'sort_order': sort_order}
        subs = subfolders_with_images(folder)
        if not subs:
            print(f"\n  No subfolders with images under: {folder}")
            input("Press Enter to exit..."); return
        print(f"\nBatch: {len(subs)} subfolder(s).")
        n_ok = 0
        for si, sd in enumerate(subs, 1):
            name = os.path.basename(os.path.normpath(sd))
            print(f"\n=== [{si}/{len(subs)}] {name} ===")
            ok, _ = build_one_pdf(sd, opts, folder_pdf_name(sd), log=print)
            if ok:
                n_ok += 1
        print(f"\nDone (batch): {n_ok}/{len(subs)} folder(s) -> PDF.")
        input("\nPress Enter to close..."); return

    # ── Collect images ────────────────────────────────────────
    images = collect_images(folder, sort_order)
    if not images:
        print(f"\n  No images found in: {folder}")
        input("Press Enter to exit..."); return

    print(f"\nFound {len(images)} image(s) in: {os.path.basename(folder)}")
    if len(images) <= 10:
        for p in images:
            print(f"  {os.path.basename(p)}")
    else:
        for p in images[:3]:
            print(f"  {os.path.basename(p)}")
        print(f"  ... ({len(images) - 6} more) ...")
        for p in images[-3:]:
            print(f"  {os.path.basename(p)}")

    # ── Validate ──────────────────────────────────────────────
    print(f"\nValidating images...")
    valid, skipped = validate_images(images)
    if skipped:
        print(f"  WARNING: {len(skipped)} image(s) skipped (unreadable):")
        for path, err in skipped[:5]:
            print(f"    {os.path.basename(path)}: {err}")
        if len(skipped) > 5:
            print(f"    ... and {len(skipped) - 5} more")
    if not valid:
        print(f"\n  No valid images to convert!")
        input("Press Enter to exit..."); return
    print(f"  {len(valid)} valid image(s) ready.")

    # ── Output filename ───────────────────────────────────────
    if not out_name:
        # Default: folder name + .pdf
        folder_name = os.path.basename(os.path.normpath(folder))
        default_name = re.sub(r'[^\w\s\-.]', '_', folder_name) + '.pdf'
    else:
        default_name = out_name
        if not default_name.lower().endswith('.pdf'):
            default_name += '.pdf'

    print(f"\nOutput filename (Enter = {default_name}):")
    raw_name   = input("Filename: ").strip().strip('"')
    final_name = raw_name or default_name
    if not final_name.lower().endswith('.pdf'):
        final_name += '.pdf'

    # Output goes into the source folder
    output_path = os.path.join(folder, final_name)

    # If file exists, ask before overwrite
    if os.path.exists(output_path):
        if not yn(f"\n  {final_name} already exists. Overwrite?", False):
            # Add timestamp
            ts = time.strftime('%Y%m%d_%H%M%S')
            base = os.path.splitext(final_name)[0]
            final_name = f"{base}_{ts}.pdf"
            output_path = os.path.join(folder, final_name)
            print(f"  Saving as: {final_name}")

    # ── Check DPI in first image ──────────────────────────────
    first_dpi = get_image_dpi(valid[0], default_dpi=0)
    if first_dpi == 0:
        print(f"\n  Note: Images have no DPI metadata. Using {dpi} DPI for page sizing.")
    elif abs(first_dpi - dpi) > 50:
        print(f"\n  Note: Image DPI ({first_dpi:.0f}) differs from setting ({dpi})."
              f" Using {dpi} DPI.")

    # ── Build layout ──────────────────────────────────────────
    layout = build_layout(page_mode, fixed_size, orientation, dpi)

    # ── Convert ───────────────────────────────────────────────
    print(f"\nConverting {len(valid)} images to PDF...")
    print(f"  Output: {output_path}")
    t0 = time.time()

    ok, msg = images_to_pdf(valid, output_path, layout_fun=layout, dpi=dpi)

    elapsed = time.time() - t0

    if ok:
        fsize = human_size(output_path)
        print(f"\n  {chr(10003)}  PDF created successfully!")
        print(f"  File:   {output_path}")
        print(f"  Size:   {fsize}")
        print(f"  Pages:  {len(valid)}")
        print(f"  Time:   {elapsed:.1f}s")
    else:
        print(f"\n  ERROR: PDF creation failed!")
        print(f"  {msg}")

    print()
    input("Press Enter to close...")


def folder_pdf_name(folder):
    """Default PDF filename for a folder = sanitized folder name + .pdf."""
    fn = os.path.basename(os.path.normpath(folder))
    return re.sub(r'[^\w\s\-.]', '_', fn) + '.pdf'


def subfolders_with_images(parent):
    """Immediate subfolders of `parent` that contain images, sorted by name,
    excluding this toolkit's own output/temp dirs."""
    out = []
    for d in sorted(os.listdir(parent)):
        sub = os.path.join(parent, d)
        if not os.path.isdir(sub):
            continue
        if (d.startswith('cropped_') or d.startswith('framed_')
                or d.startswith('adjusted_') or d == '_internal'
                or d.startswith('_eocr_tmp_')):
            continue
        if collect_images(sub):
            out.append(sub)
    return out


def build_one_pdf(folder, opts, out_name, log=print):
    """Build one PDF from `folder`'s images into folder\\out_name.
    Re-runs overwrite the same file (timestamp fallback if locked).
    Returns (ok, pages)."""
    images = collect_images(folder, opts['sort_order'])
    if not images:
        log(f"  no images in {folder}"); return False, 0
    valid, skipped = validate_images(images)
    if not valid:
        log("  no valid images to convert"); return False, 0
    if skipped:
        log(f"  ({len(skipped)} unreadable skipped)")
    if not out_name.lower().endswith('.pdf'):
        out_name += '.pdf'
    output_path = os.path.join(folder, out_name)
    if os.path.exists(output_path):
        try:
            os.remove(output_path)
        except Exception:
            ts = time.strftime('%Y%m%d_%H%M%S')
            output_path = os.path.join(folder, f"{os.path.splitext(out_name)[0]}_{ts}.pdf")
            log(f"  (existing PDF is open/locked - writing {os.path.basename(output_path)} instead)")
    layout = build_layout(opts['page_mode'], opts['fixed_size'], opts['orientation'], opts['dpi'])
    log(f"Converting {len(valid)} images  ->  {output_path}")
    ok, msg = images_to_pdf(valid, output_path, layout_fun=layout, dpi=opts['dpi'])
    if ok:
        log(f"DONE: {output_path}  ({human_size(output_path)}, {len(valid)} pages)")
        return True, len(valid)
    log(f"ERROR: {msg}")
    return False, 0


def run_noninteractive():
    """Non-interactive run for the control panel (env: PDF_RUN_*).
    Single folder -> one PDF, or batch -> one PDF per subfolder."""
    pp = os.environ.get('PDF_RUN_PRESET', '')
    folder = os.environ.get('PDF_RUN_FOLDER', '')
    p = {}
    if pp and os.path.isfile(pp):
        with open(pp, encoding='utf-8-sig') as f:
            p = json.load(f)
    folder = folder or p.get('folderPath', '')
    if not os.path.isdir(folder):
        print(f"ERROR: folder not found: {folder}", flush=True); return 1
    opts = {
        'page_mode':   p.get('pageSizeMode', 'fit-to-image'),
        'fixed_size':  p.get('fixedPageSize', 'A4'),
        'orientation': p.get('fixedOrientation', 'portrait'),
        'dpi':         int(p.get('dpi', 300)),
        'sort_order':  p.get('sortOrder', 'name-asc'),
    }
    input_source = p.get('inputSource', 'folder')   # 'folder' | 'batch'
    log = lambda m: print(m, flush=True)

    if input_source == 'batch':
        subs = subfolders_with_images(folder)
        if not subs:
            print(f"ERROR: no subfolders with images under {folder}", flush=True); return 1
        print(f"Batch: {len(subs)} subfolder(s) under "
              f"{os.path.basename(os.path.normpath(folder))}", flush=True)
        n_ok = 0
        for si, sd in enumerate(subs, 1):
            name = os.path.basename(os.path.normpath(sd))
            print(f"\n=== [{si}/{len(subs)}] {name} ===", flush=True)
            ok, _ = build_one_pdf(sd, opts, folder_pdf_name(sd), log=log)
            if ok:
                n_ok += 1
        print(f"\nDONE (batch): {n_ok}/{len(subs)} folder(s) -> PDF  ->  {folder}", flush=True)
        return 0 if n_ok else 1

    out_name = p.get('outputFilename', '') or folder_pdf_name(folder)
    ok, _ = build_one_pdf(folder, opts, out_name, log=log)
    return 0 if ok else 1


if __name__ == '__main__':
    if os.environ.get('PDF_RUN'):
        try:
            sys.exit(run_noninteractive())
        except Exception as _e:
            print(f"ERROR: {_e}", flush=True); sys.exit(1)
    try:
        main()
    except Exception as e:
        import traceback
        print("\n" + "=" * 56)
        print("  CRASH — unhandled exception:")
        print("=" * 56)
        traceback.print_exc()
        print()
        input("Press Enter to close...")
