@echo off
rem ============================================================
rem  INSTALL_ALL.bat  —  One-click dependency installer
rem  Installs all Python packages + checks Tesseract
rem  Run this ONCE on a new machine before using the scripts.
rem ============================================================
echo.
echo  ============================================================
echo   PDF Scripts Toolkit — Dependency Installer
echo  ============================================================
echo.

rem ── Check Python ────────────────────────────────────────────
echo  [1/5] Checking Python...
python --version >nul 2>&1
if errorlevel 1 (
    echo.
    echo    PYTHON NOT FOUND!
    echo.
    echo    Download Python 3.x from:
    echo      https://python.org
    echo.
    echo    IMPORTANT: Check "Add Python to PATH" during install!
    echo.
    echo    After installing Python, close this window and run
    echo    INSTALL_ALL.bat again.
    echo.
    pause
    exit /b 1
)
for /f "tokens=*" %%V in ('python --version 2^>^&1') do echo         %%V

rem ── Install all Python packages ─────────────────────────────
echo.
echo  [2/5] Installing Python packages...
echo         opencv-python, numpy, img2pdf, Pillow, ocrmypdf
echo.
pip install opencv-python numpy img2pdf Pillow ocrmypdf
if errorlevel 1 (
    echo.
    echo    WARNING: Some packages may have failed.
    echo    Try running manually:
    echo      pip install opencv-python numpy img2pdf Pillow ocrmypdf
    echo.
) else (
    echo.
    echo         All Python packages installed successfully.
)

rem ── Check / Install Tesseract OCR ────────────────────────────
echo.
echo  [3/5] Checking Tesseract OCR...
tesseract --version >nul 2>&1
if errorlevel 1 (
    echo.
    echo    Tesseract OCR not found. Downloading installer...
    echo.
    set "TESS_URL=https://github.com/UB-Mannheim/tesseract/releases/download/v5.4.0.20240606/tesseract-ocr-w64-setup-5.4.0.20240606.exe"
    set "TESS_EXE=%TEMP%\tesseract_setup.exe"
    powershell -NoProfile -Command "Write-Host '    Downloading Tesseract 5.4.0 (64-bit)...'; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; (New-Object Net.WebClient).DownloadFile($env:TESS_URL,$env:TESS_EXE); Write-Host '    Download complete.'"
    if not exist "%TESS_EXE%" (
        echo.
        echo    Download failed. Please install manually from:
        echo      https://github.com/UB-Mannheim/tesseract/wiki
        echo.
        goto :tess_skip
    )
    echo.
    echo    ═══════════════════════════════════════════════════
    echo     Tesseract installer will open now.
    echo.
    echo     IMPORTANT — during installation:
    echo       1. Keep the default install path
    echo       2. On "Choose Components" expand "Additional script data"
    echo          and "Additional language data", then CHECK:
    echo            [x] Tamil
    echo            [x] Hindi
    echo            [x] Sanskrit
    echo            [x] Devanagari
    echo          (English is included by default)
    echo       3. Click Install
    echo    ═══════════════════════════════════════════════════
    echo.
    echo    Press any key to launch the installer...
    pause >nul
    start /wait "" "%TESS_EXE%"
    del "%TESS_EXE%" >nul 2>&1

    rem  Refresh PATH so we can find tesseract without restarting
    for /f "tokens=2*" %%A in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" /v Path 2^>nul') do set "SYS_PATH=%%B"
    for /f "tokens=2*" %%A in ('reg query "HKCU\Environment" /v Path 2^>nul') do set "USR_PATH=%%B"
    set "PATH=%SYS_PATH%;%USR_PATH%"

    tesseract --version >nul 2>&1
    if errorlevel 1 (
        echo.
        echo    Tesseract still not found after install.
        echo    Try closing this window and running INSTALL_ALL again.
        goto :tess_skip
    )
    echo    Tesseract installed successfully!
)

tesseract --version >nul 2>&1
if not errorlevel 1 (
    for /f "tokens=*" %%V in ('tesseract --version 2^>^&1') do (
        echo         %%V
        goto :tess_ver_done
    )
    :tess_ver_done
    echo.
    echo    Installed languages:
    tesseract --list-langs 2>&1 | findstr /v "List"
    echo.
    rem Check for key languages
    tesseract --list-langs 2>&1 | findstr /i "tam" >nul
    if errorlevel 1 (
        echo    WARNING: Tamil ^(tam^) language pack NOT installed!
        echo    Download tam.traineddata from:
        echo      https://github.com/tesseract-ocr/tessdata_best
        echo    Place it in: C:\Program Files\Tesseract-OCR\tessdata\
        echo.
    )
)
:tess_skip

rem ── Check Ghostscript (optional) ────────────────────────────
echo  [4/5] Checking Ghostscript (optional — for PDF/A output)...
gswin64c --version >nul 2>&1
if errorlevel 1 (
    gswin32c --version >nul 2>&1
    if errorlevel 1 (
        echo         Not found (optional — Script 04 still works without it)
        echo         Download from: https://ghostscript.com/releases/gsdnld.html
    ) else (
        echo         Found (32-bit)
    )
) else (
    echo         Found (64-bit)
)

rem ── Check EasyOCR (optional — for Script 05 Sanskrit/Devanagari OCR) ─
echo.
echo  [5/5] Checking EasyOCR (optional — for Script 05 Sanskrit/Hindi OCR)...
python -c "import easyocr" >nul 2>&1
if errorlevel 1 (
    echo         Not found (optional — only needed for Script 05).
    echo         Installs automatically on first run of Script 05, or now with:
    echo           pip install easyocr
    echo         (pulls PyTorch CPU; models cache on first run, then run offline)
) else (
    echo         Installed — local, in-process Devanagari OCR ready.
)

rem ── Summary ─────────────────────────────────────────────────
echo.
echo  ============================================================
echo   Installation Summary
echo  ============================================================
echo.
echo    Script 01 (Adjust Images)   — PowerShell (built-in)    READY
echo    Script 02 (Smart Crop)      — Python + OpenCV
python -c "import cv2" >nul 2>&1
if errorlevel 1 (echo                                             MISSING) else (echo                                             READY)
echo    Script 03 (Images to PDF)   — Python + img2pdf
python -c "import img2pdf" >nul 2>&1
if errorlevel 1 (echo                                             MISSING) else (echo                                             READY)
echo    Script 04 (OCR PDF)         — Python + ocrmypdf + Tesseract
python -c "import ocrmypdf" >nul 2>&1
if errorlevel 1 (
    echo                                             MISSING (ocrmypdf)
) else (
    tesseract --version >nul 2>&1
    if errorlevel 1 (
        echo                                             MISSING (Tesseract)
    ) else (
        echo                                             READY
    )
)
echo    Script 05 (Sanskrit/Hindi OCR) — EasyOCR (local, optional)
python -c "import easyocr" >nul 2>&1
if errorlevel 1 (echo                                             EASYOCR NOT INSTALLED) else (echo                                             READY)
echo.
echo  ============================================================
echo.
pause
