@echo off
rem ============================================================
rem  05_VLM-OCR-Sanskrit.bat - Python / Ollama + Qwen2.5-VL
rem  Transcribe Sanskrit (Devanagari) page images to .txt using
rem  a local vision-language model served by Ollama.
rem  Model: hf.co/mradermacher/qwen2-5-vl-sanskrit-ocr-GGUF
rem  Requires: Python 3.x, Ollama (https://ollama.com)
rem
rem  NOTE: This is a TRANSCRIPTION tool (image -> text), not a
rem  searchable-PDF generator like 04_OCR-PDF.bat. Use it when
rem  Tesseract's Sanskrit output is not accurate enough.
rem ============================================================
setlocal
set "BATFILE=%~f0"

if not exist "%~dp0_internal\_versions\" mkdir "%~dp0_internal\_versions\"
for /f "tokens=*" %%T in ('powershell -NoProfile -Command "Get-Date -Format 'yyyy-MM-dd_HHmmss'"') do set "_BKTS=%%T"
copy /y "%~f0" "%~dp0_internal\_versions\%~n0_%_BKTS%.bat" >nul 2>&1

python --version >nul 2>&1 || (echo Python not found. Install from https://python.org & pause & exit /b 1)
ollama --version >nul 2>&1 || (echo. & echo  Ollama not found. Install from https://ollama.com & echo  Windows: winget install Ollama.Ollama & echo. & pause & exit /b 1)

set "TMPPY=%TEMP%\vlm_ocr_05.py"
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$f=$env:BATFILE;$l=[IO.File]::ReadAllLines($f);$s=0;for($i=0;$i-lt$l.Count;$i++){if($l[$i]-eq'#PY_BEGIN'){$s=$i+1;break}};[IO.File]::WriteAllLines($env:TMPPY,$l[$s..($l.Count-1)],[Text.Encoding]::UTF8)"

python "%TMPPY%"
del "%TMPPY%" >nul 2>&1
if not defined PDF_RUN pause >nul
exit /b
#PY_BEGIN
#!/usr/bin/env python3
"""
05 VLM OCR (Sanskrit)  v1.0
Transcribe Devanagari/Sanskrit page images to plain text using a local
vision-language model (Qwen2.5-VL fine-tuned for Sanskrit) served by Ollama.

Output: one .txt per image and/or a single combined .txt.
This complements 04 (searchable PDF) - it produces editable text, not a
text layer. Uses only the Python standard library + the Ollama HTTP API.
"""

import os, sys, json, glob, re, time, base64
import urllib.request
import urllib.error

# Fix Windows console encoding for Unicode (Devanagari, Tamil, etc.)
try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass

VERSION = "1.0"
CHANGELOG = """\
v1.0  2026-06-02  Initial release - Ollama + Qwen2.5-VL Sanskrit OCR
                  Image -> text transcription (per-page and/or combined)
                  Auto-pull model on first run; vlm presets vlm_preset_XX
"""

OLLAMA_HOST = os.environ.get("OLLAMA_HOST", "http://127.0.0.1:11434")
DEFAULT_MODEL = "hf.co/mradermacher/qwen2-5-vl-sanskrit-ocr-GGUF:Q4_K_M"
DEFAULT_PROMPT = (
    "Transcribe all the Sanskrit (Devanagari) text in this image exactly as "
    "written. Output only the transcribed text - no explanations, no "
    "translation, no extra commentary. Preserve the original line breaks."
)
IMAGE_EXTS = ('.jpg', '.jpeg', '.png', '.bmp', '.tif', '.tiff', '.webp')

# ═══════════════════════════════════════════════════════════
#  Preset helpers  (vlm_preset_01_desc.json)
# ═══════════════════════════════════════════════════════════

def script_folder():
    bat = os.environ.get('BATFILE', '')
    return os.path.dirname(bat) if bat else os.path.dirname(os.path.abspath(__file__))

def preset_folder():
    pf = os.path.join(script_folder(), '00_PRESETS')
    os.makedirs(pf, exist_ok=True)
    return pf

def list_vlm_presets():
    files  = sorted(glob.glob(os.path.join(preset_folder(), 'vlm_preset_*.json')))
    result = []
    for f in files:
        try:
            with open(f, encoding='utf-8-sig') as fp:
                d = json.load(fp); d['_file'] = f; result.append(d)
        except Exception:
            pass
    return result

def next_vlm_num():
    nums = []
    for f in glob.glob(os.path.join(preset_folder(), 'vlm_preset_*.json')):
        m = re.match(r'vlm_preset_(\d+)_', os.path.basename(f))
        if m:
            nums.append(int(m.group(1)))
    return max(nums, default=0) + 1

def save_vlm_preset(desc, folder_path, settings):
    num  = next_vlm_num()
    safe = re.sub(r'[^a-zA-Z0-9 _-]', '', desc).strip()
    safe = re.sub(r'\s+', '_', safe).lower()
    safe = re.sub(r'_+', '_', safe).strip('_') or 'vlm'
    fname = f'vlm_preset_{num:02d}_{safe}.json'
    data  = {'description': desc, 'folderPath': folder_path, **settings}
    with open(os.path.join(preset_folder(), fname), 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    print(f"  Saved as: {fname}")

def show_vlm_preset_menu():
    presets = list_vlm_presets()
    if not presets:
        return None
    print(f"\nSaved VLM presets ({len(presets)} found):")
    print("  " + chr(9472) * 74)
    for i, p in enumerate(presets, 1):
        fname  = os.path.splitext(os.path.basename(p['_file']))[0]
        model  = (p.get('model', '') or '').split(':')[-1] or '?'
        folder = os.path.basename(p.get('folderPath', '')) or chr(8212)
        print(f"  [{i}] {fname:<40} {model:<10} {folder}")
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
    print(f"  Sanskrit VLM OCR  v{VERSION}  (Ollama + Qwen2.5-VL)")
    print(f"  Transcribe Devanagari page images to text")
    print("=" * 56)
    for line in CHANGELOG.strip().split('\n'):
        print(f"  {line}")
    print()

def read_float(prompt, lo, hi, default):
    while True:
        raw = input(f"{prompt} [default {default}]: ").strip()
        if not raw:
            return default
        try:
            v = float(raw)
            if lo <= v <= hi:
                return v
        except Exception:
            pass
        print(f"  Enter a number {lo}-{hi}.")

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
        print(f"  Enter a whole number {lo}-{hi}.")

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
#  Ollama HTTP API
# ═══════════════════════════════════════════════════════════

def ollama_get(path, timeout=5):
    url = OLLAMA_HOST.rstrip('/') + path
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return json.loads(r.read().decode('utf-8'))

def ollama_running():
    try:
        ollama_get('/api/version')
        return True
    except Exception:
        return False

def model_present(model):
    try:
        tags = ollama_get('/api/tags')
        names = [m.get('name', '') for m in tags.get('models', [])]
        # Match exact tag, or same base with ':latest' appended by Ollama.
        return any(n == model or n == model + ":latest" for n in names)
    except Exception:
        return False

def pull_model(model):
    import subprocess
    print(f"\n  Pulling model (this is a multi-GB download, one time):")
    print(f"    {model}\n")
    rc = subprocess.call(["ollama", "pull", model])
    return rc == 0

def transcribe_image(model, image_path, prompt, temperature, num_predict):
    with open(image_path, 'rb') as f:
        b64 = base64.b64encode(f.read()).decode('ascii')
    body = json.dumps({
        "model": model,
        "prompt": prompt,
        "images": [b64],
        "stream": False,
        "options": {"temperature": float(temperature),
                    "num_predict": int(num_predict)},
    }).encode('utf-8')
    req = urllib.request.Request(
        OLLAMA_HOST.rstrip('/') + '/api/generate', data=body,
        headers={'Content-Type': 'application/json'})
    # Generous timeout - CPU inference on a page can take a while.
    with urllib.request.urlopen(req, timeout=900) as r:
        data = json.loads(r.read().decode('utf-8'))
    return (data.get('response') or '').strip()

# ═══════════════════════════════════════════════════════════
#  Main
# ═══════════════════════════════════════════════════════════

def main():
    print_header()

    if not ollama_running():
        print("  ERROR: Ollama is not responding at", OLLAMA_HOST)
        print("  Start it (it usually runs in the tray) or run:  ollama serve")
        input("\nPress Enter to exit..."); return
    print("  Ollama: running")

    preset = show_vlm_preset_menu()

    # ── Folder ────────────────────────────────────────────────
    suggested = script_folder()
    folder    = None
    if preset:
        fp = preset.get('folderPath', '')
        if fp and os.path.isdir(fp):
            print(f"\nPreset folder: {fp}")
            if yn("Use this folder?", True):
                folder = fp                       # use it directly, no re-prompt
                print("Using preset folder.")
    if folder is None:
        print(f"\nFolder with page images (Enter = {suggested}):")
        raw    = input("Folder path: ").strip().strip('"')
        folder = raw or suggested
    if not os.path.isdir(folder):
        print(f"\n  Folder not found: {folder}")
        input("Press Enter to exit..."); return

    # ── Settings ──────────────────────────────────────────────
    if preset:
        model      = preset.get('model', DEFAULT_MODEL)
        prompt     = preset.get('prompt', DEFAULT_PROMPT)
        out_mode   = preset.get('outputMode', 'per-page')
        temperature= float(preset.get('temperature', 0.1))
        max_tokens = int(preset.get('maxTokens', 2048))
        suffix     = preset.get('outputSuffix', '')
        combined   = preset.get('combinedFilename', 'transcription.txt')
        skip_exist = bool(preset.get('skipExisting', True))
        sort_order = preset.get('sortOrder', 'name-asc')
        print(f"\nPreset: {model.split(':')[-1]}  |  mode: {out_mode}  |  "
              f"temp: {temperature}  |  max tokens: {max_tokens}")
    else:
        model       = DEFAULT_MODEL
        prompt      = DEFAULT_PROMPT
        out_mode    = 'per-page'
        c = input("\nOutput - [1] per-page txt  [2] combined  [3] both [default 1]: ").strip() or '1'
        out_mode    = {'1': 'per-page', '2': 'combined', '3': 'both'}.get(c, 'per-page')
        temperature = read_float("Temperature (0-1, lower = literal)", 0.0, 1.0, 0.1)
        max_tokens  = read_int("Max tokens per page", 256, 8192, 2048)
        suffix      = input("Per-page filename suffix [default none]: ").strip()
        combined    = "transcription.txt"
        skip_exist  = yn("Skip images that already have a .txt?", True)
        sort_order  = 'name-asc'
        if yn("\nSave these settings as a preset?", False):
            desc = input("  Short description (e.g. 'sanskrit pages'): ").strip() or 'sanskrit'
            save_vlm_preset(desc, folder, {
                'model': model, 'prompt': prompt, 'outputMode': out_mode,
                'temperature': temperature, 'maxTokens': max_tokens,
                'outputSuffix': suffix, 'combinedFilename': combined,
                'skipExisting': skip_exist, 'sortOrder': sort_order,
            })

    # ── Model availability ────────────────────────────────────
    if not model_present(model):
        print(f"\n  Model not found locally: {model}")
        if not yn("  Download it now?", True):
            print("  Cannot run without the model."); input("Press Enter to exit..."); return
        if not pull_model(model):
            print("  Pull failed. Try manually:  ollama pull " + model)
            input("Press Enter to exit..."); return

    # ── Gather images ─────────────────────────────────────────
    images = collect_images(folder, sort_order)
    if not images:
        print(f"\n  No images found in: {folder}")
        input("Press Enter to exit..."); return
    print(f"\n  {len(images)} image(s) to transcribe.")
    print("  (First page may be slow while the model loads into memory.)\n")

    combined_parts = []
    ok, failed, skipped = 0, 0, 0
    t0 = time.time()
    for i, img in enumerate(images, 1):
        stem = os.path.splitext(os.path.basename(img))[0]
        txt_path = os.path.join(folder, f"{stem}{suffix}.txt")
        if skip_exist and out_mode in ('per-page', 'both') and os.path.isfile(txt_path):
            print(f"  [{i}/{len(images)}] {os.path.basename(img)}  - skip (exists)")
            skipped += 1
            continue
        print(f"  [{i}/{len(images)}] {os.path.basename(img)} ...", end="", flush=True)
        try:
            text = transcribe_image(model, img, prompt, temperature, max_tokens)
            if out_mode in ('per-page', 'both'):
                with open(txt_path, 'w', encoding='utf-8') as f:
                    f.write(text + "\n")
            if out_mode in ('combined', 'both'):
                combined_parts.append(f"# {os.path.basename(img)}\n{text}\n")
            ok += 1
            print(f"  ok ({len(text)} chars)")
        except urllib.error.URLError as e:
            failed += 1
            print(f"  FAILED ({e})")
        except Exception as e:
            failed += 1
            print(f"  FAILED ({e})")

    if out_mode in ('combined', 'both') and combined_parts:
        cpath = os.path.join(folder, combined)
        with open(cpath, 'w', encoding='utf-8') as f:
            f.write("\n".join(combined_parts))
        print(f"\n  Combined transcription: {cpath}")

    dt = time.time() - t0
    print(f"\n  Done. {ok} ok, {failed} failed, {skipped} skipped  "
          f"in {dt:.0f}s.")
    if ok:
        print(f"  Output folder: {folder}")


def run_noninteractive():
    """Non-interactive run for the control panel (env: PDF_RUN_*).
    Transcribes every image in the folder to .txt via the VLM."""
    pp = os.environ.get('PDF_RUN_PRESET', '')
    folder = os.environ.get('PDF_RUN_FOLDER', '')
    p = {}
    if pp and os.path.isfile(pp):
        with open(pp, encoding='utf-8-sig') as f:
            p = json.load(f)
    folder = folder or p.get('folderPath', '')
    if not os.path.isdir(folder):
        print(f"ERROR: folder not found: {folder}", flush=True); return 1
    if not ollama_running():
        print(f"ERROR: Ollama is not running at {OLLAMA_HOST}", flush=True); return 1
    model      = p.get('model', DEFAULT_MODEL)
    prompt     = p.get('prompt', DEFAULT_PROMPT)
    out_mode   = p.get('outputMode', 'per-page')
    temperature= float(p.get('temperature', 0.1))
    max_tokens = int(p.get('maxTokens', 2048))
    suffix     = p.get('outputSuffix', '')
    combined   = p.get('combinedFilename', 'transcription.txt')
    skip_exist = bool(p.get('skipExisting', True))
    sort_order = p.get('sortOrder', 'name-asc')
    if not model_present(model):
        print(f"Model not present; pulling {model} (one-time, multi-GB)...", flush=True)
        if not pull_model(model):
            print("ERROR: model pull failed", flush=True); return 1
    images = collect_images(folder, sort_order)
    if not images:
        print(f"ERROR: no images in {folder}", flush=True); return 1
    print(f"Sanskrit VLM OCR: {len(images)} image(s)  ({model.split(':')[-1]})", flush=True)
    parts = []; ok = failed = skipped = 0
    for i, img in enumerate(images, 1):
        stem = os.path.splitext(os.path.basename(img))[0]
        txt_path = os.path.join(folder, f"{stem}{suffix}.txt")
        if skip_exist and out_mode in ('per-page', 'both') and os.path.isfile(txt_path):
            skipped += 1
            print(f"[{i}/{len(images)}] skip {os.path.basename(img)} (exists)", flush=True); continue
        print(f"[{i}/{len(images)}] {os.path.basename(img)} ...", flush=True)
        try:
            text = transcribe_image(model, img, prompt, temperature, max_tokens)
            if out_mode in ('per-page', 'both'):
                with open(txt_path, 'w', encoding='utf-8') as f:
                    f.write(text + "\n")
            if out_mode in ('combined', 'both'):
                parts.append(f"# {os.path.basename(img)}\n{text}\n")
            ok += 1
        except Exception as e:
            failed += 1
            print(f"  FAILED: {e}", flush=True)
    if out_mode in ('combined', 'both') and parts:
        with open(os.path.join(folder, combined), 'w', encoding='utf-8') as f:
            f.write("\n".join(parts))
    print(f"DONE: {ok} ok, {failed} failed, {skipped} skipped  ->  {folder}", flush=True)
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    if os.environ.get('PDF_RUN'):
        try:
            sys.exit(run_noninteractive())
        except Exception as _e:
            print(f"ERROR: {_e}", flush=True); sys.exit(1)
    try:
        main()
    except KeyboardInterrupt:
        print("\n  Cancelled.")
    except Exception as e:
        print(f"\n  ERROR: {e}")
        input("Press Enter to exit...")
