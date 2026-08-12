@echo off
setlocal EnableDelayedExpansion
title FLUX.2 One-Click Installer

:: ============================================================
:: FLUX.2 One-Click Installer
:: Installs pyenv-win + Python 3.11 + venv locally under
::   flux2-model\  (next to this script)
:: Downloads chosen FLUX.2 checkpoint via download_model.py
:: Generates run_flux2.bat launcher
:: ============================================================

set "SCRIPT_DIR=%~dp0"
set "AI_DIR=%SCRIPT_DIR%flux2-model"
set "PYENV_DIR=%AI_DIR%\pyenv-win"
set "VENV_DIR=%AI_DIR%\venv"
set "PYTHON_VERSION=3.11.9"

:: FLUX.2-specific ignore patterns (passed to download_model.py)
set "FLUX_IGNORES=--ignore *.gguf --ignore flux2-*.png --ignore flux-2-*.png"

echo ============================================================
echo  FLUX.2 One-Click Installer
echo ============================================================
echo.
echo Install root : %AI_DIR%
echo.

:: ----------------------------------------------------------
:: Skip if already installed
:: ----------------------------------------------------------
if exist "%VENV_DIR%\Scripts\python.exe" (
    echo [install] Virtual environment already present — skipping Python setup.
    goto :pick_model
)

:: ----------------------------------------------------------
:: Install pyenv-win locally
:: ----------------------------------------------------------
echo [install] Setting up pyenv-win ...
if not exist "%PYENV_DIR%" (
    set "PYENV_HOME=%PYENV_DIR%"
    set "PATH=%PYENV_DIR%\bin;%PYENV_DIR%\shims;%PATH%"
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
        "$env:PYENV_HOME='%PYENV_DIR%'; " ^
        "Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/pyenv-win/pyenv-win/master/pyenv-win/install-pyenv-win.ps1' -UseBasicParsing | Invoke-Expression"
    if errorlevel 1 (
        echo [install] ERROR: pyenv-win installation failed.
        pause & exit /b 1
    )
) else (
    echo [install] pyenv-win already present.
)

set "PYENV_HOME=%PYENV_DIR%"
set "PATH=%PYENV_DIR%\bin;%PYENV_DIR%\shims;%PATH%"

:: ----------------------------------------------------------
:: Install Python via pyenv-win
:: ----------------------------------------------------------
echo [install] Installing Python %PYTHON_VERSION% ...
call "%PYENV_DIR%\bin\pyenv.bat" install %PYTHON_VERSION% --skip-existing
if errorlevel 1 (
    echo [install] ERROR: Python installation failed.
    pause & exit /b 1
)
set "PYTHON_EXE=%PYENV_DIR%\versions\%PYTHON_VERSION%\python.exe"

:: ----------------------------------------------------------
:: Create virtual environment
:: ----------------------------------------------------------
echo [install] Creating virtual environment ...
"%PYTHON_EXE%" -m venv "%VENV_DIR%"
if errorlevel 1 (
    echo [install] ERROR: venv creation failed.
    pause & exit /b 1
)

:: ----------------------------------------------------------
:: Helper: pip with retry
:: ----------------------------------------------------------
:pip_retry
    set "_PIP_CMD=%*"
    for /L %%i in (1,1,3) do (
        echo [install] Running: pip !_PIP_CMD! (attempt %%i)
        call "%VENV_DIR%\Scripts\pip.exe" !_PIP_CMD!
        if not errorlevel 1 goto :pip_retry_ok
        echo [install] pip attempt %%i failed — retrying ...
        timeout /t 3 >nul
    )
    echo [install] ERROR: pip failed after 3 attempts: !_PIP_CMD!
    pause & exit /b 1
:pip_retry_ok

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
"%VENV_DIR%\Scripts\python.exe" "%SCRIPT_DIR%download_model.py" ^
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
