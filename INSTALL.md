# Installation & Prerequisites

Everything you need to download and install before running the **PDF Scripts Toolkit**
on a new Windows machine.

> **Fastest path:** double-click **`00_PRESETS\00_INSTALL_ALL.bat`** — it installs the
> Python packages, downloads & runs the Tesseract installer, and checks Ghostscript +
> Ollama for you. The manual list below is for reference or if the one-click installer
> can't reach the internet.

---

## At a glance

| # | Prerequisite | Needed for | Required? |
|---|--------------|-----------|-----------|
| 1 | **Windows 10 / 11** | everything | Required |
| 2 | **Python 3.x** (add to PATH) | stages 02, 03, 04, 05 | Required |
| 3 | **Python packages** (opencv-python, numpy, img2pdf, Pillow, ocrmypdf) | stages 02, 03, 04 | Required |
| 4 | **Tesseract OCR 5.4** + language data | stage 04 (searchable PDF) | Required for 04 |
| 5 | **Ghostscript** | PDF/A output in stage 04 | Optional |
| 6 | **EasyOCR** (pip; pulls PyTorch CPU) | stage 05 (Sanskrit/Hindi Devanagari OCR) | Optional |

> Stage **01 (Adjust)** uses PowerShell, which is built into Windows — nothing to install.

---

## 1. Python 3.x  — *required*

- Download: <https://www.python.org/downloads/>
- During setup **tick "Add Python to PATH"** (this is the #1 cause of "python not found").
- Verify in a new terminal: `python --version`

## 2. Python packages  — *required*

Installed automatically by `00_PRESETS\00_INSTALL_ALL.bat`, or run manually:

```bat
pip install opencv-python numpy img2pdf Pillow ocrmypdf
```

| Package | Used by |
|---------|---------|
| opencv-python, numpy | 02 Smart Crop |
| img2pdf, Pillow | 03 Images → PDF |
| ocrmypdf | 04 OCR |

Stage **05** (optional) needs **EasyOCR** — see section 5 below.

> Note: EasyOCR/PyTorch require **numpy 2.x**, so `opencv-python` must be **4.10+**
> (the toolkit's installer handles this). TensorFlow is *not* used by any stage.

## 3. Tesseract OCR 5.4  — *required for stage 04*

- Installer (64-bit), also **bundled offline** in `00_PRESETS\tesseract-ocr-w64-setup-5.4.0.20240606.exe`:
  <https://github.com/UB-Mannheim/tesseract/releases/download/v5.4.0.20240606/tesseract-ocr-w64-setup-5.4.0.20240606.exe>
- All versions / wiki: <https://github.com/UB-Mannheim/tesseract/wiki>
- Keep the default path `C:\Program Files\Tesseract-OCR`.
- During install, expand **"Additional language data"** and check the languages you need:
  **Tamil, Hindi, Sanskrit, Devanagari** (English is included).
- **For best accuracy**, replace the installed models with `tessdata_best`:
  <https://github.com/tesseract-ocr/tessdata_best> → copy the `.traineddata` files into
  `C:\Program Files\Tesseract-OCR\tessdata\`
- Verify: `tesseract --version` and `tesseract --list-langs`

> If Tesseract is installed but a script can't find it, add `C:\Program Files\Tesseract-OCR`
> to PATH and open a new terminal. (The scripts also try this path automatically.)

## 4. Ghostscript  — *optional (PDF/A output)*

- Download: <https://ghostscript.com/releases/gsdnld.html>
- Only needed if you enable **PDF/A** generation in stage 04. Stage 04 works without it.

## 5. EasyOCR  — *optional (stage 05, Sanskrit / Hindi Devanagari)*

Only needed for **05 EasyOCR (Sanskrit)** — transcribes Devanagari page images to editable
`.txt`. Runs **fully locally, in-process on CPU via PyTorch** — no server, no Ollama, no Docker.

- Install: `pip install easyocr` (auto-installs on first run of stage 05). This pulls
  **PyTorch (CPU)**; on first OCR run EasyOCR downloads its detection + recognition models
  (~tens of MB) which then run offline.
- Stage 05 also makes a **combined searchable PDF** (image + invisible text). That needs
  `pip install reportlab pymupdf` (also auto-installed). A Devanagari font is bundled in
  `_internal\fonts\` so the PDF text is searchable on any machine. For **PDF/A**, run the
  result through `ocrmypdf --skip-text --output-type pdfa "in.pdf" "out_pdfa.pdf"`.
- Language code **`hi`** = Devanagari (covers Sanskrit / Hindi / Marathi / Nepali script).
- Because PyTorch needs **numpy 2.x**, ensure `opencv-python` is **4.10+**:
  `pip install -U "opencv-python>=4.10"` (the installer does this automatically).
- Project: <https://github.com/JaidedAI/EasyOCR>
- **GPU (optional, much faster):** stage 05 has a **"Use GPU"** checkbox. It only works
  if you have an NVIDIA GPU **and** the CUDA build of PyTorch. The default `pip install`
  gives the CPU build, so to enable GPU:
  ```
  pip uninstall -y torch torchvision
  pip install torch torchvision --index-url https://download.pytorch.org/whl/cu121
  ```
  Then `python -c "import torch; print(torch.cuda.is_available())"` should print `True`.
  (If unchecked or no CUDA, it falls back to CPU automatically.)

---

## Verify everything

```bat
python --version
pip show opencv-python img2pdf ocrmypdf
tesseract --version
tesseract --list-langs
python -c "import easyocr"   REM optional, for stage 05
```

Or just open **`00_CONTROL_PANEL.bat`** → the **Environment** panel shows a live
green/red status for every dependency.
