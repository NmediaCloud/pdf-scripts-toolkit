@echo off
rem ============================================================
rem  02_Smart-Crop-Pages.bat  —  Python/OpenCV edition
rem  Smart page detection: colour-rectangle isolation + deskew
rem  Requires: Python 3.x  (auto-installs opencv-python, numpy)
rem
rem  VERSION HISTORY
rem  v1.0  2026-03-30  PowerShell brightness-threshold version
rem  v2.0  2026-03-30  Rewritten Python/OpenCV — contour detection
rem  v3.0  2026-03-30  Saturation-based page split (sleeve scans)
rem  v3.1  2026-03-30  Text straightening + content centering + safe margins
rem  v4.0  2026-06-16  Colour-mask + minAreaRect deskew warp (robust crop/rotate),
rem                    full-frame fallback for blanks, optional Tesseract OSD
rem                    auto-orient, UNIFORM page-size canvas (clean PDF, incl. cover)
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
python -c "import cv2, numpy" >nul 2>&1
if errorlevel 1 (
    echo  Installing required packages: opencv-python numpy
    pip install opencv-python numpy
    if errorlevel 1 (
        echo  Failed. Please run manually:  pip install opencv-python numpy
        pause & exit /b 1
    )
)
rem  Optional: pytesseract (Python side of auto-orient). The Tesseract binary
rem  is also required for orientation to do anything; it's a no-op without it.
python -c "import pytesseract" >nul 2>&1 || pip install pytesseract >nul 2>&1

rem ── Extract Python section and run ──────────────────────────
set "TMPPY=%TEMP%\smart_crop_pages_02.py"
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
02 Smart Crop Pages  v4.0  —  Python/OpenCV

Pipeline for sleeve / loose-leaf scans (coloured paper page on a white bed):
  1. Build a "content" mask = saturated OR dark pixels  (the tan/pink page +
     its printed border, vs. the white sleeve/backing/scanner bed).
  2. Take the largest page-shaped blob; a partial neighbouring leaf shows up
     as a smaller blob and is discarded automatically.
  3. cv2.minAreaRect on that blob -> a rotated rectangle; warp it flat. This
     crops AND deskews (and rotates landscape captures to portrait) in one go.
  4. Blank / near-white pages give no blob -> fall back to a near-full frame.
  5. Optional Tesseract OSD snaps each page to upright (0/90/180/270).
  6. UNIFORM SIZE: every output is padded onto one common canvas so the
     resulting PDF has perfectly uniform pages (covers and blanks included).
"""

import cv2
import numpy as np
import os, sys, json, glob, shutil, tempfile, re
from pathlib import Path

VERSION = "4.3"
CHANGELOG = """\
v4.0  2026-06-16  Colour-mask + minAreaRect deskew warp, blank fallback,
                  uniform page-size canvas
v4.2  2026-06-16  Column-projection page SPLIT (one single page per output,
                  drops partial neighbour leaf), no forced rotation,
                  rotation control (OSD off by default)
v4.3  2026-06-16  Two-pass STEP selector: crop (native single pages) /
                  canvas (uniform framing only) / crop + canvas
v4.4  2026-06-17  Batch mode: each subfolder -> its own cropped_/framed_ folder
"""

# ═══════════════════════════════════════════════════════════
#  Page detection  (colour mask + per-page rotated-rect warp)
# ═══════════════════════════════════════════════════════════

def _content_mask(small):
    """Mask of 'page content' = coloured (saturated) OR dark pixels.
    The white sleeve / backing sheet / scanner bed is bright + unsaturated,
    so it drops out; the tan or pink page (and its black border) stays.
    Close kernel is kept small so it does NOT bridge the gutter between two
    side-by-side leaves (needed for the page split)."""
    hsv = cv2.cvtColor(small, cv2.COLOR_BGR2HSV)
    s = hsv[:, :, 1]
    v = hsv[:, :, 2]
    mask = ((s > 35) | (v < 160)).astype(np.uint8) * 255
    k = max(7, int(min(small.shape[:2]) * 0.012) | 1)
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, np.ones((k, k), np.uint8))
    ok = max(5, k // 3)
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, np.ones((ok, ok), np.uint8))
    return mask


def _column_runs(on):
    """Yield (start, end) index ranges where boolean array `on` is True."""
    out = []
    i, n = 0, len(on)
    while i < n:
        if on[i]:
            j = i
            while j < n and on[j]:
                j += 1
            out.append((i, j - 1))
            i = j
        else:
            i += 1
    return out


def detect_pages(image_path, analysis_size=1400, min_area_frac=0.04,
                 minw_frac=0.55, edge_frac=0.018):
    """Detect each FULL page in a scan and return (list_of_rects, (oh, ow)).

    These scans are open-book: a full page plus a PARTIAL neighbouring leaf
    (cut off at the scan edge), or occasionally two full pages. We:
      1. build the content mask,
      2. find vertical content "blocks" via a column projection (the white
         gutter/spine separates them),
      3. keep only FULL pages — a block wide enough vs. the widest, whose
         edges are NOT flush against the image border (partials are cut off
         and sit flush to an edge),
      4. fit a rotated rectangle to each kept block.

    Rects are in ORIGINAL coords, ordered left-to-right. Empty list = blank /
    nothing found (caller uses a full-frame crop).
    """
    img = cv2.imread(str(image_path))
    if img is None:
        return [], None
    oh, ow = img.shape[:2]
    sc = analysis_size / float(max(oh, ow))
    small = cv2.resize(img, (max(1, int(ow * sc)), max(1, int(oh * sc))))
    mw = small.shape[1]
    area = small.shape[0] * small.shape[1]

    mask = _content_mask(small)
    col = (mask > 0).sum(axis=0).astype(float)
    win = max(5, mw // 80)
    col = np.convolve(col, np.ones(win) / win, mode="same")
    if col.max() <= 0:
        return [], (oh, ow)

    blocks = [(a, b) for a, b in _column_runs(col > 0.30 * col.max())
              if (b - a) > mw * 0.03]
    if not blocks:
        return [], (oh, ow)

    max_bw = max(b - a for a, b in blocks)
    edge = mw * edge_frac
    rects = []
    for a, b in blocks:
        bw = b - a
        is_full = (bw >= minw_frac * max_bw) and (a > edge) and (b < mw - edge)
        if not is_full:
            continue
        sub = np.zeros_like(mask)
        sub[:, a:b + 1] = mask[:, a:b + 1]
        cnts, _ = cv2.findContours(sub, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        if not cnts:
            continue
        c = max(cnts, key=cv2.contourArea)
        if cv2.contourArea(c) < area * min_area_frac:
            continue
        (cx, cy), (rw, rh), ang = cv2.minAreaRect(c)
        if rw < 1 or rh < 1:
            continue
        rects.append(((cx / sc, cy / sc), (rw / sc, rh / sc), ang))
    rects.sort(key=lambda r: r[0][0])      # left-to-right
    return rects, (oh, ow)


def detect_page_rect(image_path, analysis_size=1400, min_area_frac=0.04):
    """Back-compat / preview helper: the single primary (largest) page rect,
    or None. Returns (rect_or_None, (oh, ow))."""
    rects, dims = detect_pages(image_path, analysis_size, min_area_frac)
    if not rects:
        return None, dims
    best = max(rects, key=lambda r: r[1][0] * r[1][1])
    return best, dims


def _order_box(box):
    """Order 4 box points TL, TR, BR, BL."""
    s = box.sum(axis=1)
    d = np.diff(box, axis=1).ravel()      # y - x
    return np.array([
        box[np.argmin(s)],   # top-left      smallest x+y
        box[np.argmin(d)],   # top-right     smallest y-x
        box[np.argmax(s)],   # bottom-right  largest  x+y
        box[np.argmax(d)],   # bottom-left   largest  y-x
    ], dtype="float32")


def rect_crop_size(rect):
    """The (w, h) the warped crop will have — computed the SAME way as
    extract_page from ordered box points, so it's deterministic (unlike
    minAreaRect's (w,h) whose order flips with the angle convention)."""
    src = _order_box(cv2.boxPoints(rect))
    tl, tr, br, bl = src
    w = int(round(max(np.linalg.norm(tr - tl), np.linalg.norm(br - bl))))
    h = int(round(max(np.linalg.norm(bl - tl), np.linalg.norm(br - tr))))
    return w, h


def extract_page(img, rect):
    """Warp the rotated rectangle flat -> a deskewed, cropped page image.
    Natural orientation is preserved (portrait stays portrait, landscape stays
    landscape); use auto_orient() afterwards to snap 90/180 if needed."""
    src = _order_box(cv2.boxPoints(rect))
    w, h = rect_crop_size(rect)
    if w < 10 or h < 10:
        return None
    dst = np.array([[0, 0], [w - 1, 0], [w - 1, h - 1], [0, h - 1]],
                   dtype="float32")
    M = cv2.getPerspectiveTransform(src, dst)
    return cv2.warpPerspective(img, M, (w, h), flags=cv2.INTER_LANCZOS4,
                               borderMode=cv2.BORDER_REPLICATE)


def expand_rect(rect, px):
    """Grow a rotated rect outward by `px` pixels on every side (the crop
    allowance), so the detected page edge / border isn't shaved off."""
    if rect is None or px == 0:
        return rect
    (c, (w, h), a) = rect
    return (c, (max(1.0, w + 2 * px), max(1.0, h + 2 * px)), a)


def full_frame_crop(img, inset=0.01):
    """Fallback for blank/undetected pages: trim a thin inset (no rotation)."""
    oh, ow = img.shape[:2]
    m = int(min(oh, ow) * inset)
    return img[m:oh - m, m:ow - m]


# ═══════════════════════════════════════════════════════════
#  Orientation  (optional Tesseract OSD — graceful no-op)
# ═══════════════════════════════════════════════════════════

_TESS_OK = None

def _tess_ready():
    global _TESS_OK
    if _TESS_OK is not None:
        return _TESS_OK
    _TESS_OK = False
    try:
        import pytesseract
        exe = shutil.which("tesseract")
        if not exe:
            for p in (r"C:\Program Files\Tesseract-OCR\tesseract.exe",
                      r"C:\Program Files (x86)\Tesseract-OCR\tesseract.exe"):
                if os.path.isfile(p):
                    pytesseract.pytesseract.tesseract_cmd = p
                    exe = p
                    break
        _TESS_OK = bool(exe)
    except Exception:
        _TESS_OK = False
    return _TESS_OK


def auto_orient(img):
    """Rotate to upright using Tesseract OSD. Returns (img, rotation_applied).
    No-op (returns 0) if Tesseract/pytesseract are unavailable or OSD fails.
    NOTE: OSD can MISFIRE on Devanagari (it may rotate an already-upright page),
    so this is opt-in (rotate='auto-osd'), not the default."""
    if img is None or not _tess_ready():
        return img, 0
    try:
        import pytesseract
        osd = pytesseract.image_to_osd(img)
        m = re.search(r"Rotate:\s*(\d+)", osd)
        rot = int(m.group(1)) if m else 0
        if rot == 90:
            img = cv2.rotate(img, cv2.ROTATE_90_CLOCKWISE)
        elif rot == 180:
            img = cv2.rotate(img, cv2.ROTATE_180)
        elif rot == 270:
            img = cv2.rotate(img, cv2.ROTATE_90_COUNTERCLOCKWISE)
        return img, rot
    except Exception:
        return img, 0


def apply_rotation(img, mode):
    """Apply a fixed/auto rotation. mode in:
      none | 90cw | 90ccw | 180 | auto-osd
    The minAreaRect deskew already makes pages upright, so the default is
    'none'. Use a fixed 90cw/90ccw/180 for books scanned sideways/upside-down
    (reliable), or 'auto-osd' for Tesseract OSD (may misfire on Devanagari)."""
    if img is None:
        return img
    if mode == '90cw':
        return cv2.rotate(img, cv2.ROTATE_90_CLOCKWISE)
    if mode == '90ccw':
        return cv2.rotate(img, cv2.ROTATE_90_COUNTERCLOCKWISE)
    if mode == '180':
        return cv2.rotate(img, cv2.ROTATE_180)
    if mode == 'auto-osd':
        out, _ = auto_orient(img)
        return out
    return img


# ═══════════════════════════════════════════════════════════
#  Enhancement
# ═══════════════════════════════════════════════════════════

def enhance_page(img, level='auto'):
    """CLAHE contrast + unsharp mask. Keeps the paper colour intact."""
    if level == 'none' or img is None or img.size == 0:
        return img
    lab = cv2.cvtColor(img, cv2.COLOR_BGR2LAB)
    l, a, b = cv2.split(lab)
    clip = 2.0 if level == 'auto' else 3.5
    clahe = cv2.createCLAHE(clipLimit=clip, tileGridSize=(8, 8))
    l_eq = clahe.apply(l)
    enhanced = cv2.cvtColor(cv2.merge([l_eq, a, b]), cv2.COLOR_LAB2BGR)
    sigma = 1.5 if level == 'auto' else 2.0
    amount = 0.55 if level == 'auto' else 0.90
    blur = cv2.GaussianBlur(enhanced, (0, 0), sigma)
    return cv2.addWeighted(enhanced, 1.0 + amount, blur, -amount, 0)


# ═══════════════════════════════════════════════════════════
#  Uniform-size canvas
# ═══════════════════════════════════════════════════════════

def _bg_color(name, sample_img=None):
    if name == 'black':
        return (0, 0, 0)
    if name == 'sampled' and sample_img is not None and sample_img.size:
        h, w = sample_img.shape[:2]
        strip = np.concatenate([
            sample_img[0:max(1, min(6, h))].reshape(-1, 3),
            sample_img[max(0, h - 6):h].reshape(-1, 3),
        ], axis=0)
        return tuple(int(c) for c in np.median(strip, axis=0))
    return (255, 255, 255)


def place_on_canvas(img, cw, ch, bg=(255, 255, 255)):
    """Centre img on a cw x ch canvas, scaling DOWN only if it would overflow."""
    h, w = img.shape[:2]
    s = min(cw / float(w), ch / float(h))
    if s < 1.0:
        img = cv2.resize(img, (max(1, int(w * s)), max(1, int(h * s))),
                         interpolation=cv2.INTER_AREA)
        h, w = img.shape[:2]
    canvas = np.full((ch, cw, 3), bg, dtype=np.uint8)
    y = (ch - h) // 2
    x = (cw - w) // 2
    canvas[y:y + h, x:x + w] = img
    return canvas


def get_median(values):
    if not values:
        return 0
    s = sorted(values)
    return s[len(s) // 2]


# ═══════════════════════════════════════════════════════════
#  Folder processing  (shared by interactive + control-panel run)
# ═══════════════════════════════════════════════════════════

def gather_images(folder):
    found = []
    for ext in ('*.jpg', '*.jpeg', '*.png', '*.bmp', '*.tif', '*.tiff',
                '*.JPG', '*.JPEG', '*.PNG', '*.BMP', '*.TIF', '*.TIFF'):
        found.extend(glob.glob(os.path.join(folder, ext)))
    seen = set()
    images = []
    for f in sorted(found):
        if f.lower() not in seen:
            seen.add(f.lower())
            images.append(f)
    return images


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
        if gather_images(sub):
            out.append(sub)
    return out


def canvas_pages(folder, settings, out_folder, log=print):
    """STEP 2 (canvas only): pad every image in `folder` onto one uniform
    canvas. NO detection / cropping / rotation — meant to run on an already
    cropped + manually-reviewed folder. Returns (saved, skipped)."""
    padding   = int(settings.get('padding', 10))
    canvas_w  = int(settings.get('canvasWidth', 0))
    canvas_h  = int(settings.get('canvasHeight', 0))
    target_h  = int(settings.get('targetHeight', 0))
    canvas_bg = settings.get('canvasBg', 'white')
    out_fmt   = settings.get('outputFormat', 'jpg')
    quality   = int(settings.get('jpegQuality', 85))
    out_ext   = '.jpg' if out_fmt == 'jpg' else '.png'
    fit = settings.get('fitMode')
    if fit not in ('pad-to-largest', 'scale-to-height', 'per-page'):
        fit = 'pad-to-largest' if settings.get('uniformSize', True) else 'per-page'
    if fit == 'per-page':
        fit = 'pad-to-largest'      # canvas step is pointless without uniforming

    images = gather_images(folder)
    if not images:
        log(f"ERROR: no images in {folder}")
        return 0, 0
    os.makedirs(out_folder, exist_ok=True)
    log(f"Canvas/frame: {len(images)} image(s)  ->  {out_folder}")

    # Pass 1: collect image sizes (PIL reads the header only - fast).
    from PIL import Image as _PILImage
    sizes = []
    for p in images:
        try:
            with _PILImage.open(p) as im:
                sizes.append(im.size)      # (w, h)
        except Exception:
            sizes.append(None)
    valid = [wh for wh in sizes if wh]

    cw = ch = 0
    if fit == 'scale-to-height':
        if target_h == 0:
            target_h = int(round(get_median([h for w, h in valid]) or 2600))
            log(f"  auto target height: {target_h}px (median)")
        scaled_w = [w * target_h / h for w, h in valid if h > 0]
        content_w = max(scaled_w) if scaled_w else target_h
        cw = int(round(content_w)) + 2 * padding
        ch = int(target_h) + 2 * padding
        log(f"  scale-to-height canvas: {cw} x {ch}px (+{padding}px margin)")
    else:  # pad-to-largest
        max_w = max(w for w, h in valid) if valid else 2000
        max_h = max(h for w, h in valid) if valid else 2800
        if canvas_w > 0 and canvas_h > 0:
            cw, ch = canvas_w, canvas_h
            fits = "OK - no scaling" if (cw >= max_w and ch >= max_h) \
                else f"WARNING: smaller than largest image {max_w}x{max_h} (will scale to fit)"
            log(f"  fixed canvas: {cw} x {ch}px  ({fits})")
        else:
            cw = max_w + 2 * padding
            ch = max_h + 2 * padding
            log(f"  pad-to-largest canvas: {cw} x {ch}px "
                f"(largest image {max_w}x{max_h} + {padding}px margin, no scaling)")

    saved = skipped = 0
    for i, p in enumerate(images, 1):
        name = os.path.splitext(os.path.basename(p))[0] + out_ext
        img = cv2.imread(p)
        if img is None:
            skipped += 1
            log(f"[{i}/{len(images)}] skip {name} (unreadable)")
            continue
        if fit == 'scale-to-height':
            th = int(target_h)
            tw = max(1, int(img.shape[1] * th / img.shape[0]))
            interp = cv2.INTER_AREA if th < img.shape[0] else cv2.INTER_LANCZOS4
            img = cv2.resize(img, (tw, th), interpolation=interp)
        out = place_on_canvas(img, cw, ch, _bg_color(canvas_bg, img))
        dest = os.path.join(out_folder, name)
        if out_fmt == 'png':
            ok = cv2.imwrite(dest, out)
        else:
            ok = cv2.imwrite(dest, out, [cv2.IMWRITE_JPEG_QUALITY, quality])
        if ok:
            saved += 1
            log(f"[{i}/{len(images)}] framed {name}")
        else:
            skipped += 1
            log(f"[{i}/{len(images)}] FAILED {name}")

    log(f"DONE: saved {saved}, skipped {skipped}  ->  {out_folder}")
    return saved, skipped


def process_folder(folder, settings, out_folder, log=print):
    """Two-pass crop/deskew/orient + uniform canvas. Returns (saved, skipped)."""
    padding    = int(settings.get('padding', 40))
    crop_allow = int(settings.get('cropAllowance', 2))   # px kept around page edge
    canvas_w   = int(settings.get('canvasWidth', 0))     # 0 = auto (largest+margin)
    canvas_h   = int(settings.get('canvasHeight', 0))
    rotate     = settings.get('rotate', 'none')
    if rotate not in ('none', '90cw', '90ccw', '180', 'auto-osd'):
        rotate = 'none'
    enhance    = settings.get('enhance', 'auto')
    target_h   = int(settings.get('targetHeight', 0))
    canvas_bg  = settings.get('canvasBg', 'white')
    out_fmt    = settings.get('outputFormat', 'jpg')
    quality    = int(settings.get('jpegQuality', 85))
    out_ext    = '.jpg' if out_fmt == 'jpg' else '.png'
    # fitMode: how outputs are made uniform.
    #   pad-to-largest  - crops kept at native size, centred on one big white
    #                     canvas = largest crop + margin (NO scaling). (default)
    #   scale-to-height - resize every crop to a common height, then pad.
    #   per-page        - just add the margin border (sizes vary; non-uniform).
    fit = settings.get('fitMode')
    if fit not in ('pad-to-largest', 'scale-to-height', 'per-page'):
        # back-compat with the old uniformSize toggle
        fit = 'pad-to-largest' if settings.get('uniformSize', True) else 'per-page'

    # step: which half of the two-pass workflow to run.
    #   crop          - detect + deskew + rotate + enhance -> NATIVE-size single
    #                   pages (no uniform canvas). Review/fix these by hand.
    #   canvas        - take an already-cropped folder and only pad every image
    #                   onto one uniform canvas (no re-detection / cropping).
    #   crop + canvas - do both in one go (the all-in-one path).
    step = settings.get('step', 'crop + canvas')
    if step not in ('crop', 'canvas', 'crop + canvas'):
        step = 'crop + canvas'
    if step == 'canvas':
        return canvas_pages(folder, settings, out_folder, log)
    if step == 'crop':
        fit = 'per-page'        # native single pages, no uniform canvas
        padding = 0             # no border - keep the raw crop for manual review

    images = gather_images(folder)
    if not images:
        log(f"ERROR: no images in {folder}")
        return 0, 0
    os.makedirs(out_folder, exist_ok=True)
    log(f"Smart Crop: {len(images)} image(s)  ->  {out_folder}")

    if rotate == 'auto-osd' and not _tess_ready():
        log("  note: Tesseract not found - OSD auto-orient disabled "
            "(crop + deskew still applied)")
        rotate = 'none'

    # ── Pass 1: detect pages (1+ per scan), collect crop dimensions ──────────
    recs = []          # (path, [rect,...], (oh, ow))
    page_dims = []     # (w, h) of every full page crop, natural orientation
    for i, p in enumerate(images, 1):
        log(f"[{i}/{len(images)}] detect {os.path.basename(p)}")
        try:
            rects, dims = detect_pages(p, min_area_frac=0.04)
        except Exception as e:
            log(f"  WARNING {os.path.basename(p)}: {e}")
            rects, dims = [], None
        rects = [expand_rect(r, crop_allow) for r in rects]   # edge allowance
        recs.append((p, rects, dims))
        if len(rects) > 1:
            log(f"      -> split into {len(rects)} pages")
        for r in rects:
            w, h = rect_crop_size(r)              # deterministic crop (w, h)
            if rotate in ('90cw', '90ccw'):       # fixed 90° swaps the aspect
                w, h = h, w
            page_dims.append((w, h))

    # ── Common canvas size for uniform output ────────────────────────────────
    cw = ch = 0
    if fit == 'scale-to-height':
        if target_h == 0:
            target_h = int(round(get_median([h for _, h in page_dims]) or 2600))
            log(f"  auto target height: {target_h}px (median page)")
        scaled_w = [w * target_h / h for w, h in page_dims if h > 0]
        content_w = max(scaled_w) if scaled_w else target_h
        cw = int(round(content_w)) + 2 * padding
        ch = int(target_h) + 2 * padding
        log(f"  scale-to-height canvas: {cw} x {ch}px (+{padding}px margin)")
    elif fit == 'pad-to-largest':
        # Size the canvas from the REAL detected page crops; blank/full-frame
        # fallback pages are scaled down to fit so a stray whole-scan blank
        # doesn't bloat every page's canvas.
        max_w = int(round(max(w for w, h in page_dims)))  if page_dims else 2000
        max_h = int(round(max(h for w, h in page_dims)))  if page_dims else 2800
        if canvas_w > 0 and canvas_h > 0:
            # Explicit numeric canvas. Set it >= the largest crop to guarantee
            # NO scaling/cropping; anything larger just gets more white border.
            cw, ch = canvas_w, canvas_h
            fits = "OK - no scaling" if (cw >= max_w and ch >= max_h) \
                else f"WARNING: smaller than largest crop {max_w}x{max_h} (will scale to fit)"
            log(f"  fixed canvas: {cw} x {ch}px  ({fits})")
        else:
            cw = max_w + 2 * padding
            ch = max_h + 2 * padding
            log(f"  pad-to-largest canvas: {cw} x {ch}px "
                f"(largest page crop {max_w}x{max_h} + {padding}px margin, no scaling)")

    def finish(page):
        """rotate + enhance + place on the uniform canvas / pad."""
        page = apply_rotation(page, rotate)
        page = enhance_page(page, enhance)
        if fit == 'scale-to-height':
            th = int(target_h)
            tw = max(1, int(page.shape[1] * th / page.shape[0]))
            interp = cv2.INTER_AREA if th < page.shape[0] else cv2.INTER_LANCZOS4
            page = cv2.resize(page, (tw, th), interpolation=interp)
            return place_on_canvas(page, cw, ch, _bg_color(canvas_bg, page))
        if fit == 'pad-to-largest':
            return place_on_canvas(page, cw, ch, _bg_color(canvas_bg, page))
        # per-page
        if target_h > 0 and page.shape[0] > 0:
            tw = max(1, int(page.shape[1] * target_h / page.shape[0]))
            page = cv2.resize(page, (tw, int(target_h)),
                              interpolation=cv2.INTER_LANCZOS4)
        if padding > 0:
            return cv2.copyMakeBorder(page, padding, padding, padding, padding,
                                      cv2.BORDER_CONSTANT,
                                      value=_bg_color(canvas_bg, page))
        return page

    # ── Pass 2: extract each page, finish, save (one file per page) ───────────
    saved = skipped = 0
    for i, (p, rects, dims) in enumerate(recs, 1):
        base = os.path.splitext(os.path.basename(p))[0]
        if dims is None:
            skipped += 1
            log(f"[{i}/{len(images)}] skip {base} (unreadable)")
            continue
        img = cv2.imread(p)
        if img is None:
            skipped += 1
            log(f"[{i}/{len(images)}] skip {base} (unreadable)")
            continue

        # Build the list of page crops for this scan (or a full-frame fallback).
        crops = []
        for r in rects:
            pg = extract_page(img, r)
            if pg is not None:
                crops.append(pg)
        if not crops:
            crops = [full_frame_crop(img)]

        multi = len(crops) > 1
        for pidx, page in enumerate(crops, 1):
            name = (f"{base}_{pidx}{out_ext}" if multi else f"{base}{out_ext}")
            out = finish(page)
            dest = os.path.join(out_folder, name)
            if out_fmt == 'png':
                ok = cv2.imwrite(dest, out)
            else:
                ok = cv2.imwrite(dest, out, [cv2.IMWRITE_JPEG_QUALITY, quality])
            if ok:
                saved += 1
                log(f"[{i}/{len(images)}] saved {name}")
            else:
                skipped += 1
                log(f"[{i}/{len(images)}] FAILED {name}")

    log(f"DONE: saved {saved}, skipped {skipped}  ->  {out_folder}")
    return saved, skipped


# ═══════════════════════════════════════════════════════════
#  SC Preset helpers  (sc_preset_NN_desc.json)
# ═══════════════════════════════════════════════════════════

def script_folder():
    bat = os.environ.get('BATFILE', '')
    return os.path.dirname(bat) if bat else os.path.dirname(os.path.abspath(__file__))


def preset_folder():
    pf = os.path.join(script_folder(), '00_PRESETS')
    os.makedirs(pf, exist_ok=True)
    return pf


def list_sc_presets():
    files = sorted(glob.glob(os.path.join(preset_folder(), 'sc_preset_*.json')))
    result = []
    for f in files:
        try:
            with open(f, encoding='utf-8') as fp:
                d = json.load(fp); d['_file'] = f; result.append(d)
        except Exception:
            pass
    return result


def next_sc_num():
    nums = []
    for f in glob.glob(os.path.join(preset_folder(), 'sc_preset_*.json')):
        m = re.match(r'sc_preset_(\d+)_', os.path.basename(f))
        if m:
            nums.append(int(m.group(1)))
    return max(nums, default=0) + 1


def save_sc_preset(desc, folder_path, settings):
    num = next_sc_num()
    safe = re.sub(r'[^a-zA-Z0-9 _-]', '', desc).strip()
    safe = re.sub(r'\s+', '_', safe).lower()
    safe = re.sub(r'_+', '_', safe).strip('_') or 'sc'
    fname = f'sc_preset_{num:02d}_{safe}.json'
    data = {'description': desc, 'folderPath': folder_path, **settings}
    with open(os.path.join(preset_folder(), fname), 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2)
    print(f"  Saved as: {fname}")


def show_sc_preset_menu():
    presets = list_sc_presets()
    if not presets:
        return None
    print(f"\nSaved SC presets ({len(presets)} found):")
    print("  " + "─" * 70)
    for i, p in enumerate(presets, 1):
        fname = os.path.splitext(os.path.basename(p['_file']))[0]
        fmts = f"JPG q{p.get('jpegQuality', 85)}" if p.get('outputFormat', 'jpg') == 'jpg' else 'PNG'
        folder = os.path.basename(p.get('folderPath', '')) or '—'
        fit = p.get('fitMode') or ('pad-to-largest' if p.get('uniformSize', True) else 'per-page')
        print(f"  [{i}] {fname:<30} pad{p.get('padding', 40):>3}  {fmts:<9} {fit:<14} {folder}")
    print("  [0] Skip — enter settings manually")
    while True:
        raw = input(f"\nEnter preset number (0–{len(presets)}): ").strip()
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
    print(f"  Smart Crop Pages  v{VERSION}  (Python + OpenCV)")
    print(f"  Colour-mask crop + minAreaRect deskew + uniform size")
    print("=" * 56)
    for line in CHANGELOG.strip().split('\n'):
        print(f"  {line}")
    print()


def read_int(prompt, lo, hi, default):
    while True:
        raw = input(f"{prompt} [default {default}]: ").strip()
        if not raw:
            return default
        try:
            n = int(raw)
            if lo <= n <= hi:
                return n
        except Exception:
            pass
        print(f"  Enter a whole number {lo}–{hi}.")


def yn(prompt, default_yes=True):
    tag = "[Y/n]" if default_yes else "[y/N]"
    raw = input(f"{prompt} {tag}: ").strip().lower()
    return default_yes if not raw else raw.startswith('y')


# ═══════════════════════════════════════════════════════════
#  Main (interactive)
# ═══════════════════════════════════════════════════════════

def main():
    print_header()
    preset = show_sc_preset_menu()

    sf = script_folder()
    folder = None
    if preset:
        fp = preset.get('folderPath', '')
        if fp and os.path.isdir(fp):
            print(f"\nPreset folder: {fp}")
            if yn("Use this folder?", True):
                folder = fp
    if folder is None:
        print(f"\nSource folder (Enter = {sf}):")
        raw = input("Folder path: ").strip().strip('"')
        folder = raw or sf
    if not os.path.isdir(folder):
        print(f"\n  Folder not found: {folder}")
        input("Press Enter to exit…"); return

    # Batch? (each subfolder processed separately)
    batch = bool(preset and preset.get('inputSource') == 'batch')
    if not preset:
        batch = yn("\nBatch mode - process each SUBFOLDER separately?", False)

    if batch:
        subs = subfolders_with_images(folder)
        if not subs:
            print(f"\n  No subfolders with images under: {folder}")
            input("Press Enter to exit…"); return
        print(f"\nBatch: {len(subs)} subfolder(s) to process.")
    else:
        images = gather_images(folder)
        if not images:
            print(f"\n  No images found in: {folder}")
            input("Press Enter to exit…"); return
        print(f"\nFound {len(images)} image(s).")

    if preset:
        settings = {
            'padding':       int(preset.get('padding', 40)),
            'cropAllowance': int(preset.get('cropAllowance', 2)),
            'canvasWidth':   int(preset.get('canvasWidth', 0)),
            'canvasHeight':  int(preset.get('canvasHeight', 0)),
            'fitMode':       preset.get('fitMode', ''),
            'uniformSize':   bool(preset.get('uniformSize', True)),
            'rotate':        preset.get('rotate', 'none'),
            'step':          preset.get('step', 'crop + canvas'),
            'enhance':       preset.get('enhance', 'auto'),
            'targetHeight':  int(preset.get('targetHeight', 0)),
            'canvasBg':      preset.get('canvasBg', 'white'),
            'outputFormat':  preset.get('outputFormat', 'jpg'),
            'jpegQuality':   int(preset.get('jpegQuality', 85)),
        }
        print(f"\nPreset: step {settings['step']} | allow {settings['cropAllowance']}px | "
              f"fit {settings['fitMode'] or '(auto)'} | "
              f"canvas {settings['canvasWidth']}x{settings['canvasHeight'] or 'auto'} | "
              f"rotate {settings['rotate']} | enhance {settings['enhance']} | "
              f"{settings['outputFormat']} q{settings['jpegQuality']}")
    else:
        print("\n── Crop allowance ───────────────────────────────────────────")
        print("  Pixels kept around the detected page edge so the border isn't")
        print("  shaved off. 2 = tight (1-2px), 0 = exact edge, 8 = looser.")
        crop_allow = read_int("Crop allowance px", 0, 50, 2)

        print("\n── Margin / padding (white border, auto-canvas only) ─────────")
        print("  e.g. 5, 10 or 15 px of white space around the cropped page.")
        padding = read_int("Margin px around page", 0, 300, 10)

        print("\n── Fixed canvas size (0 = auto from largest crop) ────────────")
        print("  Set explicit output W x H so every page is padded to exactly")
        print("  this size. Use values >= your largest crop to avoid any")
        print("  scaling. Leave 0 to auto-size to the largest crop + margin.")
        canvas_w = read_int("Canvas width px (0=auto)", 0, 12000, 0)
        canvas_h = read_int("Canvas height px (0=auto)", 0, 12000, 0)

        print("\n── Uniform page size ────────────────────────────────────────")
        print("  How to make every output the same size (clean PDF, covers")
        print("  and blanks included):")
        print("  [1] Pad to largest  — keep crops at native size, centre each on")
        print("                        one big white canvas = largest crop + margin")
        print("                        (NO scaling of the page).  (recommended)")
        print("  [2] Scale to height — resize every crop to one height, then pad.")
        print("  [3] Per-page        — just add the margin (sizes vary).")
        mc = input("\nChoice (1-3) [default 1]: ").strip() or '1'
        fit = {'1': 'pad-to-largest', '2': 'scale-to-height',
               '3': 'per-page'}.get(mc, 'pad-to-largest')

        print("\n── Rotation ─────────────────────────────────────────────────")
        print("  Pages are already deskewed/upright after cropping. Only rotate")
        print("  if the whole book was scanned sideways/upside-down.")
        print("  [1] None   [2] 90 CW   [3] 90 CCW   [4] 180   [5] Auto (OSD)")
        print("  (OSD needs Tesseract and can MISFIRE on Devanagari.)")
        rc = input("\nChoice (1-5) [default 1]: ").strip() or '1'
        rotate = {'1': 'none', '2': '90cw', '3': '90ccw', '4': '180',
                  '5': 'auto-osd'}.get(rc, 'none')

        print("\n── Enhancement ──────────────────────────────────────────────")
        print("  [1] None   [2] Auto (CLAHE + sharpen)   [3] Strong")
        ec = input("\nChoice (1-3) [default 2]: ").strip() or '2'
        enhance = {'1': 'none', '2': 'auto', '3': 'strong'}.get(ec, 'auto')

        print("\n── Output height ────────────────────────────────────────────")
        print("  0 = auto (median detected page height)")
        target_h = read_int("Target height px (0=auto)", 0, 10000, 0)

        print("\n── Output format ────────────────────────────────────────────")
        print("  [1] JPG (choose quality)   [2] PNG (lossless)")
        fc = input("\nChoice (1-2) [default 1]: ").strip() or '1'
        if fc == '2':
            out_fmt, quality = 'png', 100
        else:
            out_fmt = 'jpg'
            quality = read_int("JPEG quality (1-100)", 1, 100, 85)

        print("\n── Step (two-pass workflow) ─────────────────────────────────")
        print("  [1] Crop          — crop+deskew+rotate, NATIVE single pages")
        print("                      (review/fix by hand before framing)")
        print("  [2] Canvas        — only pad an already-cropped folder to one")
        print("                      uniform size (no re-cropping)")
        print("  [3] Crop + Canvas — do both at once")
        sc_ = input("\nChoice (1-3) [default 3]: ").strip() or '3'
        step = {'1': 'crop', '2': 'canvas', '3': 'crop + canvas'}.get(sc_, 'crop + canvas')

        settings = {
            'inputSource': ('batch' if batch else 'folder'),
            'padding': padding, 'cropAllowance': crop_allow,
            'canvasWidth': canvas_w, 'canvasHeight': canvas_h,
            'fitMode': fit, 'rotate': rotate, 'step': step,
            'enhance': enhance, 'targetHeight': target_h, 'canvasBg': 'white',
            'outputFormat': out_fmt, 'jpegQuality': quality,
        }
        if yn("\nSave these settings as an SC preset?", False):
            desc = ''
            while not desc.strip():
                desc = input("  Short description: ").strip()
            save_sc_preset(desc, folder, settings)

    fmt_tag = f"jpg{settings['jpegQuality']}" if settings['outputFormat'] == 'jpg' else 'png'
    sub_tag = 'framed' if settings.get('step') == 'canvas' else 'cropped'
    if batch:
        tot_saved = tot_skipped = 0
        for si, sd in enumerate(subs, 1):
            name = os.path.basename(os.path.normpath(sd))
            out_folder = os.path.join(sd, f"{sub_tag}_{fmt_tag}")
            print(f"\n=== [{si}/{len(subs)}] {name} -> {out_folder} ===")
            sv, sk = process_folder(sd, settings, out_folder, log=print)
            tot_saved += sv; tot_skipped += sk
        print(f"\nDONE (batch): {len(subs)} folder(s) | {tot_saved} saved, {tot_skipped} skipped")
    else:
        out_folder = os.path.join(folder, f"{sub_tag}_{fmt_tag}")
        print(f"\nOutput folder: {out_folder}\n")
        process_folder(folder, settings, out_folder, log=print)
    print()
    input("Press Enter to close…")


def run_noninteractive():
    """Control-panel run (env: PDF_RUN_*)."""
    pp = os.environ.get('PDF_RUN_PRESET', '')
    folder = os.environ.get('PDF_RUN_FOLDER', '')
    p = {}
    if pp and os.path.isfile(pp):
        with open(pp, encoding='utf-8-sig') as f:
            p = json.load(f)
    folder = folder or p.get('folderPath', '')
    if not os.path.isdir(folder):
        print(f"ERROR: folder not found: {folder}", flush=True)
        return 1
    settings = {
        'padding':       int(p.get('padding', 40)),
        'cropAllowance': int(p.get('cropAllowance', 2)),
        'canvasWidth':   int(p.get('canvasWidth', 0)),
        'canvasHeight':  int(p.get('canvasHeight', 0)),
        'fitMode':       p.get('fitMode', ''),
        'uniformSize':   bool(p.get('uniformSize', True)),
        'rotate':        p.get('rotate', 'none'),
        'step':          p.get('step', 'crop + canvas'),
        'enhance':      p.get('enhance', 'auto'),
        'targetHeight': int(p.get('targetHeight', 0)),
        'canvasBg':     p.get('canvasBg', 'white'),
        'outputFormat': p.get('outputFormat', 'jpg'),
        'jpegQuality':  int(p.get('jpegQuality', 85)),
    }
    input_source = p.get('inputSource', 'folder')   # 'folder' | 'batch'
    fmt_tag = f"jpg{settings['jpegQuality']}" if settings['outputFormat'] == 'jpg' else 'png'
    sub_tag = 'framed' if settings.get('step') == 'canvas' else 'cropped'

    def log(m):
        print(m, flush=True)

    # ── Batch: each subfolder -> its own cropped_/framed_ output folder ──────
    if input_source == 'batch':
        subs = subfolders_with_images(folder)
        if not subs:
            log(f"ERROR: no subfolders with images under {folder}")
            return 1
        log(f"Batch: {len(subs)} subfolder(s) under "
            f"{os.path.basename(os.path.normpath(folder))}")
        tot_saved = tot_skipped = 0
        for si, sd in enumerate(subs, 1):
            name = os.path.basename(os.path.normpath(sd))
            out_folder = os.path.join(sd, f"{sub_tag}_{fmt_tag}")
            log(f"\n=== [{si}/{len(subs)}] {name} ===")
            sv, sk = process_folder(sd, settings, out_folder, log=log)
            tot_saved += sv; tot_skipped += sk
        log(f"\nDONE (batch): {len(subs)} folder(s) | {tot_saved} saved, "
            f"{tot_skipped} skipped  ->  {folder}")
        return 0 if tot_saved else 1

    out_folder = os.path.join(folder, f"{sub_tag}_{fmt_tag}")
    saved, skipped = process_folder(folder, settings, out_folder, log=log)
    return 0 if saved else 1


if __name__ == '__main__':
    if os.environ.get('PDF_RUN'):
        try:
            sys.exit(run_noninteractive())
        except Exception as _e:
            print(f"ERROR: {_e}", flush=True); sys.exit(1)
    main()
