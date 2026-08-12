@echo off
setlocal EnableDelayedExpansion
title FLUX.2 One-Click Installer

:: ============================================================
:: FLUX.2 One-Click Installer
:: Installs Python 3.11 + venv fully locally under
::   flux2-model\  (next to this script) — no system Python needed.
:: Downloads chosen FLUX.2 checkpoint via download_model.py
:: Generates run_flux2.bat launcher
:: ============================================================

set "SCRIPT_DIR=%~dp0"
set "AI_DIR=%SCRIPT_DIR%flux2-model"
set "VENV_DIR=%AI_DIR%\venv"
set "PYTHON_VERSION=3.11.9"
set "RUNTIME_DIR=%AI_DIR%\python-%PYTHON_VERSION%"
set "PYENV_DIR=%AI_DIR%\pyenv-win"
set "PY_ZIP_URL=https://www.python.org/ftp/python/%PYTHON_VERSION%/python-%PYTHON_VERSION%-embed-amd64.zip"
set "PYENV_ZIP_URL=https://github.com/pyenv-win/pyenv-win/archive/refs/heads/master.zip"
set "PY_EMBED_URL=https://www.python.org/ftp/python/%PYTHON_VERSION%/python-%PYTHON_VERSION%-amd64.zip"
set "GET_PIP_URL=https://bootstrap.pypa.io/get-pip.py"

:: FLUX.2-specific ignore patterns (passed to download_model.py)
set "FLUX_IGNORES=--ignore *.gguf --ignore flux2-*.png --ignore flux-2-*.png"

echo ============================================================
echo  FLUX.2 One-Click Installer
echo ============================================================
echo.
echo Install root : %AI_DIR%
echo.

:: ----------------------------------------------------------
:: Skip Python setup only if the venv python actually WORKS.
:: A leftover/corrupt python.exe from an interrupted install
:: must not be treated as "installed" — recreate the venv.
:: ----------------------------------------------------------
if exist "%VENV_DIR%\Scripts\python.exe" (
    "%VENV_DIR%\Scripts\python.exe" --version >nul 2>&1
    if not errorlevel 1 (
        echo [install] Virtual environment already present — skipping Python setup.
        goto :pip_section
    )
    echo [install] Found broken virtual environment (python.exe won't run) — recreating it.
    rmdir /s /q "%VENV_DIR%"
)

set "PIP_DIRECT=0"

:: ----------------------------------------------------------
:: Provision a local Python %PYTHON_VERSION% under AI_DIR.
:: Method 1 (preferred): official embedded distribution from
:: python.org (has venv + pip) — no pyenv needed.
:: Method 2 (fallback): pyenv-win from GitHub, still local.
:: Method 3 (last resort): embeddable package + get-pip.
:: ----------------------------------------------------------
set "PYTHON_EXE="
set "PY_TMP=%AI_DIR%\_pytmp"
if not exist "%AI_DIR%" mkdir "%AI_DIR%"
if exist "%PY_TMP%" rmdir /s /q "%PY_TMP%"
mkdir "%PY_TMP%"

echo [install] Downloading Python %PYTHON_VERSION% (embedded) from python.org ...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; " ^
    "(New-Object System.Net.WebClient).DownloadFile('%PY_ZIP_URL%', '%PY_TMP%\python.zip')"
if not exist "%PY_TMP%\python.zip" (
    echo [install] python.org download failed — trying pyenv-win from GitHub ...
    goto :try_pyenv
)

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "Expand-Archive -Path '%PY_TMP%\python.zip' -DestinationPath '%RUNTIME_DIR%' -Force"
if not exist "%RUNTIME_DIR%\python.exe" (
    echo [install] Extract failed — trying pyenv-win from GitHub ...
    goto :try_pyenv
)
set "PYTHON_EXE=%RUNTIME_DIR%\python.exe"
goto :make_venv

:try_pyenv
echo [install] Downloading pyenv-win (local, no system changes) ...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; " ^
    "(New-Object System.Net.WebClient).DownloadFile('%PYENV_ZIP_URL%', '%PY_TMP%\pyenv.zip'); " ^
    "Expand-Archive -Path '%PY_TMP%\pyenv.zip' -DestinationPath '%AI_DIR%' -Force; " ^
    "Move-Item -Path '%AI_DIR%\pyenv-win-master' -Destination '%PYENV_DIR%' -Force"
if not exist "%PYENV_DIR%\bin\pyenv.bat" (
    echo [install] pyenv-win unavailable — using embeddable Python + get-pip ...
    goto :try_embeddable
)
set "PYENV=%PYENV_DIR%\"
set "PYENV_ROOT=%PYENV_DIR%\"
set "PYENV_HOME=%PYENV_DIR%\"
set "PATH=%PYENV_DIR%\bin;%PYENV_DIR%\shims;%PATH%"
call "%PYENV_DIR%\bin\pyenv.bat" install %PYTHON_VERSION% --skip-existing
if errorlevel 1 (
    echo [install] pyenv install failed — using embeddable Python + get-pip ...
    goto :try_embeddable
)
set "PYTHON_EXE=%PYENV_DIR%\versions\%PYTHON_VERSION%\python.exe"
if not exist "%PYTHON_EXE%" (
    echo [install] pyenv did not produce python.exe — using embeddable Python + get-pip ...
    goto :try_embeddable
)
goto :make_venv

:try_embeddable
echo [install] Downloading embeddable Python %PYTHON_VERSION% ...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; " ^
    "(New-Object System.Net.WebClient).DownloadFile('%PY_EMBED_URL%', '%PY_TMP%\python.zip'); " ^
    "Expand-Archive -Path '%PY_TMP%\python.zip' -DestinationPath '%RUNTIME_DIR%' -Force"
if not exist "%RUNTIME_DIR%\python.exe" (
    echo [install] ERROR: could not obtain a local Python runtime.
    echo [install] Check your internet connection / firewall and re-run.
    pause & exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "(New-Object System.Net.WebClient).DownloadFile('%GET_PIP_URL%', '%RUNTIME_DIR%\get-pip.py')"
if not exist "%RUNTIME_DIR%\get-pip.py" (
    echo [install] ERROR: get-pip.py download failed.
    pause & exit /b 1
)
:: Enable site-packages + pip inside the embeddable runtime
for %%F in ("%RUNTIME_DIR%\python*._pth") do (
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
        "(Get-Content '%%~fF') -replace '#\s*import site','import site' | Set-Content '%%~fF'"
)
"%RUNTIME_DIR%\python.exe" "%RUNTIME_DIR%\get-pip.py" >nul 2>&1
if errorlevel 1 (
    echo [install] ERROR: get-pip failed inside embeddable runtime.
    pause & exit /b 1
)
set "PYTHON_EXE=%RUNTIME_DIR%\python.exe"
set "PIP_DIRECT=1"
goto :pip_section

:make_venv
if not exist "%PYTHON_EXE%" (
    echo [install] ERROR: local Python not found at %PYTHON_EXE%
    pause & exit /b 1
)
echo [install] Local Python ready: %PYTHON_EXE%

:: ----------------------------------------------------------
:: Create virtual environment
:: ----------------------------------------------------------
echo [install] Creating virtual environment ...
"%PYTHON_EXE%" -m venv "%VENV_DIR%"
if errorlevel 1 (
    echo [install] ERROR: venv creation failed.
    pause & exit /b 1
)

if not exist "%VENV_DIR%\Scripts\python.exe" (
    echo [install] ERROR: venv was created but python.exe is missing inside it.
    echo [install] Delete the folder "%VENV_DIR%" and re-run this installer.
    pause & exit /b 1
)

:pip_section
if exist "%PY_TMP%" rmdir /s /q "%PY_TMP%" 2>nul
goto :skip_pip_retry_def

:: ----------------------------------------------------------
:: Helper: pip with retry
:: ----------------------------------------------------------
:pip_retry
    set "_PIP_CMD=%*"
    for /L %%i in (1,1,3) do (
        echo [install] Running: pip !_PIP_CMD! (attempt %%i)
        if "!PIP_DIRECT!"=="1" (
            call "%RUNTIME_DIR%\python.exe" -m pip !_PIP_CMD!
        ) else (
            call "%VENV_DIR%\Scripts\pip.exe" !_PIP_CMD!
        )
        if not errorlevel 1 goto :pip_retry_ok
        echo [install] pip attempt %%i failed — retrying ...
        timeout /t 3 >nul
    )
    echo [install] ERROR: pip failed after 3 attempts: !_PIP_CMD!
    pause & exit /b 1
:pip_retry_ok
    goto :eof

:skip_pip_retry_def
set "PIP_TARGET_PY=%VENV_DIR%\Scripts\python.exe"
if "!PIP_DIRECT!"=="1" set "PIP_TARGET_PY=%RUNTIME_DIR%\python.exe"

:: ----------------------------------------------------------
:: Upgrade pip + install huggingface_hub
:: ----------------------------------------------------------
call :pip_retry install --upgrade pip
call :pip_retry install huggingface_hub

:: ----------------------------------------------------------
:: Detect GPU (NVIDIA)
:: ----------------------------------------------------------
echo [install] Detecting GPU ...
set "TORCH_INDEX=https://download.pytorch.org/whl/cpu"
nvidia-smi >nul 2>&1
if not errorlevel 1 (
    echo [install] NVIDIA GPU detected — installing CUDA 12.4 PyTorch wheels.
    set "TORCH_INDEX=https://download.pytorch.org/whl/cu124"
) else (
    echo [install] No NVIDIA GPU detected — installing CPU-only PyTorch.
    echo [install] Note: FLUX.2 inference will be slow without a GPU.
)

:: ----------------------------------------------------------
:: Install PyTorch
:: ----------------------------------------------------------
call :pip_retry install torch torchvision torchaudio --index-url !TORCH_INDEX!

:: ----------------------------------------------------------
:: Install diffusers + transformers stack (FLUX.2 deps)
:: ----------------------------------------------------------
call :pip_retry install diffusers[torch] transformers accelerate sentencepiece protobuf

:: ----------------------------------------------------------
:: Install gradio for the web UI
:: ----------------------------------------------------------
call :pip_retry install gradio

:pick_model
:: ----------------------------------------------------------
:: Model selection
:: ----------------------------------------------------------
echo.
echo ============================================================
echo  FLUX.2 Checkpoint Selection
echo ============================================================
echo.
echo  [1] FLUX.2-klein-4B        ~8 GB   (recommended, 4B params)
echo  [2] FLUX.2-standard-8B     ~16 GB  (higher quality, 8B params)
echo  [3] FLUX.1-dev             ~24 GB  (original FLUX.1, highest quality)
echo  [4] FLUX.1-schnell         ~24 GB  (original FLUX.1, fast)
echo.
echo  VRAM guidance:
echo    4 GB+  : FLUX.2-klein-4B (with quantization)
echo    8 GB+  : FLUX.2-klein-4B (full)
echo    16 GB+ : FLUX.2-standard-8B
echo    24 GB+ : FLUX.1-dev / FLUX.1-schnell
echo.
set /p CHOICE="Enter choice [1]: "
if "!CHOICE!"=="" set "CHOICE=1"

if "!CHOICE!"=="1" (
    set "REPO_ID=black-forest-labs/FLUX.2-klein-4B"
    set "MODEL_NAME=FLUX.2-klein-4B"
)
if "!CHOICE!"=="2" (
    set "REPO_ID=black-forest-labs/FLUX.2-standard-8B"
    set "MODEL_NAME=FLUX.2-standard-8B"
)
if "!CHOICE!"=="3" (
    set "REPO_ID=black-forest-labs/FLUX.1-dev"
    set "MODEL_NAME=FLUX.1-dev"
)
if "!CHOICE!"=="4" (
    set "REPO_ID=black-forest-labs/FLUX.1-schnell"
    set "MODEL_NAME=FLUX.1-schnell"
)

if not defined REPO_ID (
    echo [install] Invalid choice. Using default (FLUX.2-klein-4B).
    set "REPO_ID=black-forest-labs/FLUX.2-klein-4B"
    set "MODEL_NAME=FLUX.2-klein-4B"
)

echo.
echo [install] Downloading !MODEL_NAME! from !REPO_ID! ...
echo [install] (Download is resumable — you can Ctrl+C and restart safely.)
echo.

:: ----------------------------------------------------------
:: Download checkpoint via generalized download_model.py
:: ----------------------------------------------------------
"!PIP_TARGET_PY!" "%SCRIPT_DIR%download_model.py" ^
    "!REPO_ID!" "%AI_DIR%" ^
    --subdir model ^
    !FLUX_IGNORES!

if errorlevel 1 (
    echo [install] ERROR: Model download failed.
    pause & exit /b 1
)

:: ----------------------------------------------------------
:: Generate run_flux2.bat launcher
:: ----------------------------------------------------------
set "LAUNCHER=%SCRIPT_DIR%run_flux2.bat"
(
    echo @echo off
    echo setlocal
    echo title FLUX.2 - !MODEL_NAME!
    echo call "%VENV_DIR%\Scripts\activate.bat"
    echo python -c "from diffusers import FluxPipeline; import torch; pipe = FluxPipeline.from_pretrained('%AI_DIR%\model', torch_dtype=torch.bfloat16); pipe.to('cuda' if torch.cuda.is_available() else 'cpu'); print('FLUX.2 model loaded! Use pipe(...) to generate images.')"
    echo cmd /k
) > "!LAUNCHER!"

echo.
echo ============================================================
echo  Installation complete!
echo ============================================================
echo.
echo  Model location : %AI_DIR%\model
echo  Launcher       : !LAUNCHER!
echo.
echo  To run, double-click run_flux2.bat
echo.
pause
