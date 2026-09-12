"""
EasyOCR engine  -  local, in-process Indic OCR (no server, no Ollama).

Runs EasyOCR's detection + recognition models directly on CPU via PyTorch.
Models download once from the EasyOCR model zoo (~tens of MB per language)
and are cached under the user's ~/.EasyOCR folder, then run fully offline.

Devanagari ('hi') covers Sanskrit / Hindi / Marathi / Nepali script.
"""

import os
import sys

_READERS = {}   # langs-tuple -> easyocr.Reader  (cached so we load once)


def restrict_to_best_gpu():
    """Pin CUDA to the single highest-memory GPU so EasyOCR uses just the best
    card (avoids DataParallel imbalance across mismatched GPUs, e.g. RTX + Quadro).
    MUST be called before any torch CUDA call. Returns the chosen index or None."""
    if os.environ.get("CUDA_VISIBLE_DEVICES"):
        return os.environ["CUDA_VISIBLE_DEVICES"]
    try:
        import subprocess
        r = subprocess.run(
            ["nvidia-smi", "--query-gpu=index,memory.total",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=8)
        best_idx, best_mem = None, -1
        for line in r.stdout.strip().splitlines():
            parts = [x.strip() for x in line.split(",")]
            if len(parts) >= 2 and parts[1].isdigit():
                if int(parts[1]) > best_mem:
                    best_mem, best_idx = int(parts[1]), parts[0]
        if best_idx is not None:
            # Force PCI ordering so this nvidia-smi index matches what CUDA
            # selects (torch otherwise defaults to "fastest first").
            os.environ["CUDA_DEVICE_ORDER"] = "PCI_BUS_ID"
            os.environ["CUDA_VISIBLE_DEVICES"] = best_idx
            return best_idx
    except Exception:
        pass
    return None


def check_dependencies():
    """Return {name: (ok, detail)} for the EasyOCR stack."""
    deps = {"Python": (True, sys.version.split()[0])}
    for mod, name in (("numpy", "numpy"), ("cv2", "opencv-python"),
                      ("PIL", "pillow"), ("torch", "torch"),
                      ("easyocr", "easyocr")):
        try:
            m = __import__(mod)
            deps[name] = (True, str(getattr(m, "__version__", "installed")))
        except Exception as e:
            deps[name] = (False, f"missing ({type(e).__name__})")
    return deps


def parse_langs(lang_spec):
    """'hi,en' or 'hi+en' or 'hi' -> ['hi', 'en']."""
    parts = [p.strip() for p in str(lang_spec or "hi").replace("+", ",").split(",")]
    return [p for p in parts if p] or ["hi"]


def create_reader(langs, gpu=False, verbose=True):
    """Build (and cache) an EasyOCR Reader for the given language list.

    verbose=True lets EasyOCR print its model-download / progress bars on
    first run (the download can take a minute or two for new languages).
    """
    import easyocr
    key = tuple(langs)
    if key not in _READERS:
        _READERS[key] = easyocr.Reader(list(langs), gpu=gpu, verbose=verbose)
    return _READERS[key]


def ocr_page(reader, image_path, paragraph=True):
    """OCR one image, returning text (one block/paragraph per line)."""
    res = reader.readtext(image_path, detail=0, paragraph=paragraph)
    return "\n".join(s for s in res if s)


def ocr_page_detailed(reader, image_path, paragraph=False):
    """OCR one image, returning [(bbox_points, text), ...] with positions.

    bbox_points is a list of 4 [x, y] corners in image-pixel coords
    (origin top-left). Used to place an invisible searchable text layer.
    """
    res = reader.readtext(image_path, detail=1, paragraph=paragraph)
    out = []
    for item in res:                       # (bbox, text[, conf])
        bbox, text = item[0], item[1]
        if text and str(text).strip():
            out.append((bbox, str(text)))
    return out


# ── Searchable-PDF builder (image + invisible text underlay) ───────────────

def _register_pdf_font():
    """Register a Unicode (Devanagari-capable) TTF for reportlab so the
    invisible text is actually searchable. Falls back to Helvetica."""
    from reportlab.pdfbase import pdfmetrics
    from reportlab.pdfbase.ttfonts import TTFont
    win = os.environ.get("WINDIR", r"C:\Windows")
    here = os.path.dirname(os.path.abspath(__file__))
    candidates = [
        os.path.join(here, "fonts", "NotoSansDevanagari-Regular.ttf"),  # bundled
        os.path.join(win, "Fonts", "Nirmala.ttf"),    # Nirmala UI (Devanagari)
        os.path.join(win, "Fonts", "mangal.ttf"),     # Mangal (Devanagari)
        os.path.join(win, "Fonts", "arial.ttf"),      # last resort (Latin only)
    ]
    for path in candidates:
        if os.path.isfile(path):
            try:
                pdfmetrics.registerFont(TTFont("OCRFont", path))
                return "OCRFont", os.path.basename(path)
            except Exception:
                continue
    return "Helvetica", "Helvetica (no Devanagari - search may fail)"


def build_searchable_pdf(pages, out_pdf, log=print, quality=55, max_dim=2000, page_dpi=150):
    """Build a combined searchable PDF, normalized to size + DPI.

    pages    : list of (image_path, [(bbox_points, text), ...]) - OCR images and
               their text boxes (box coords are pixels in the OCR image).
    quality  : JPEG quality (1-95) for the embedded page images.
    max_dim  : cap the longest edge to this many px (0 = keep original) - the
               main file-SIZE control (these scans can be ~90 MP/page).
    page_dpi : the embedded image is treated as this DPI, so the page gets a
               sane physical size (page_inch = embedded_px / page_dpi).

    Image and text are scaled together, so the text underlay stays aligned.
    """
    import io
    from reportlab.pdfgen import canvas
    from reportlab.lib.utils import ImageReader
    from PIL import Image

    font, font_name = _register_pdf_font()
    log(f"  PDF font: {font_name} | max edge {max_dim or 'orig'} px, "
        f"page {page_dpi} DPI, JPEG q{quality}")
    c = canvas.Canvas(out_pdf)
    for img_path, boxes in pages:
        with Image.open(img_path) as im:
            w, h = im.size
            factor = min(1.0, max_dim / max(w, h)) if max_dim else 1.0
            im2 = im.convert("RGB")
            if factor < 1.0:
                im2 = im2.resize((max(1, int(w * factor)), max(1, int(h * factor))),
                                 Image.LANCZOS)
            buf = io.BytesIO()
            im2.save(buf, "JPEG", quality=int(quality), optimize=True)
            buf.seek(0)
        scale = factor / float(page_dpi) * 72.0    # OCR px -> PDF point
        pw, ph = w * scale, h * scale
        c.setPageSize((pw, ph))
        c.drawImage(ImageReader(buf), 0, 0, width=pw, height=ph)
        for bbox, text in boxes:
            try:
                xs = [float(p[0]) * scale for p in bbox]
                ys = [float(p[1]) * scale for p in bbox]
            except Exception:
                continue
            x0, y1 = min(xs), max(ys)
            box_w = max(1.0, max(xs) - x0)
            box_h = max(1.0, y1 - min(ys))
            fs = max(2.0, box_h * 0.85)
            to = c.beginText()
            to.setTextRenderMode(3)             # invisible (the underlay)
            to.setFont(font, fs)
            tw = c.stringWidth(text, font, fs)
            if tw > 0:
                to.setHorizScale(max(10.0, min(500.0, box_w / tw * 100.0)))
            to.setTextOrigin(x0, ph - y1)       # PDF origin is bottom-left
            to.textLine(text)
            c.drawText(to)
        c.showPage()
    c.save()
    return out_pdf


def rebuild_compressed_pdf(in_pdf, out_pdf, log=print, quality=55, max_dim=2000, page_dpi=150):
    """Shrink an existing searchable PDF WITHOUT re-OCR, normalized to size +
    DPI: cap each page's longest edge to max_dim px, JPEG-compress, give the
    page a sane physical size (embedded_px / page_dpi), and re-lay the text
    layer from the PDF's words. Keeps it searchable; makes the file small."""
    import io
    import fitz
    from reportlab.pdfgen import canvas
    from reportlab.lib.utils import ImageReader
    from PIL import Image

    font, _ = _register_pdf_font()
    doc = fitz.open(in_pdf)
    n = doc.page_count
    c = canvas.Canvas(out_pdf)
    for i in range(n):
        page = doc[i]
        rect = page.rect
        W, H = rect.width, rect.height          # points (== original pixels)
        factor = min(1.0, max_dim / max(W, H)) if max_dim else 1.0
        pix = page.get_pixmap(matrix=fitz.Matrix(factor, factor), alpha=False)
        img = Image.frombytes("RGB", (pix.width, pix.height), pix.samples)
        buf = io.BytesIO()
        img.save(buf, "JPEG", quality=int(quality), optimize=True)
        buf.seek(0)
        scale = factor / float(page_dpi) * 72.0     # original px -> new point
        pw, ph = W * scale, H * scale
        c.setPageSize((pw, ph))
        c.drawImage(ImageReader(buf), 0, 0, width=pw, height=ph)
        for x0, y0, x1, y1, word, *_ in page.get_text("words"):
            if not word.strip():
                continue
            X0, Y1 = x0 * scale, y1 * scale
            bw = max(1.0, (x1 - x0) * scale)
            fs = max(2.0, (y1 - y0) * scale * 0.9)
            to = c.beginText()
            to.setTextRenderMode(3)
            to.setFont(font, fs)
            tw = c.stringWidth(word, font, fs)
            if tw > 0:
                to.setHorizScale(max(10.0, min(500.0, bw / tw * 100.0)))
            to.setTextOrigin(X0, ph - Y1)
            to.textLine(word)
            c.drawText(to)
        c.showPage()
        if log and (i + 1) % 20 == 0:
            log(f"  shrunk page {i + 1}/{n}")
    doc.close()
    c.save()
    return out_pdf


def convert_to_pdfa(in_pdf, out_pdf, log=print):
    """Wrap an existing searchable PDF as PDF/A via ocrmypdf - no re-OCR
    (keeps the EasyOCR text layer). Requires Ghostscript. Raises on failure."""
    import subprocess
    cmd = [sys.executable, "-m", "ocrmypdf", "--skip-text",
           "--output-type", "pdfa", in_pdf, out_pdf]
    log(f"  PDF/A: ocrmypdf --skip-text --output-type pdfa -> {os.path.basename(out_pdf)}")
    r = subprocess.run(cmd, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    if r.returncode != 0:
        msg = (r.stderr or r.stdout or "ocrmypdf failed").strip()
        if "ghostscript" in msg.lower() or "gswin" in msg.lower():
            msg = "Ghostscript not found (needed for PDF/A). Install from " \
                  "https://ghostscript.com/releases/gsdnld.html  |  " + msg[:160]
        raise RuntimeError(msg[:300])
    return out_pdf
