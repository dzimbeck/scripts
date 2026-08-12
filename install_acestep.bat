@echo off
setlocal EnableDelayedExpansion
title ACE-Step One-Click Installer

:: ============================================================
:: ACE-Step One-Click Installer
:: Installs pyenv-win + Python 3.10 + venv locally under
::   acestep-model\  (next to this script)
:: Downloads chosen ACE-Step checkpoint via download_model.py
:: Generates run_acestep.bat launcher
::
:: ACE-Step: https://github.com/ace-step/ACE-Step
:: HF org:   https://huggingface.co/ACE-Step
:: License:  Code - Apache-2.0
::           Model weights - see model card on HF
:: ============================================================

set "SCRIPT_DIR=%~dp0"
set "AI_DIR=%SCRIPT_DIR%acestep-model"
set "PYENV_DIR=%AI_DIR%\pyenv-win"
set "VENV_DIR=%AI_DIR%\venv"
set "PYTHON_VERSION=3.10.11"

echo ============================================================
echo  ACE-Step One-Click Installer
echo  Music/Audio Generation Foundation Model
echo ============================================================
echo.
echo Install root : %AI_DIR%
echo.

:: ----------------------------------------------------------
:: GPU detection defaults (must stay out of the skipped setup
:: path so re-runs still install the correct PyTorch build)
:: ----------------------------------------------------------
set "GPU_DETECTED=0"
set "TORCH_INDEX=https://download.pytorch.org/whl/cpu"

:: ----------------------------------------------------------
:: Skip Python setup only if the venv python actually WORKS.
:: A leftover/corrupt python.exe from an interrupted install
:: must not be treated as "installed" — recreate the venv.
:: ----------------------------------------------------------
if exist "%VENV_DIR%\Scripts\python.exe" (
    "%VENV_DIR%\Scripts\python.exe" --version >nul 2>&1
    if not errorlevel 1 (
        echo [install] Virtual environment already present — skipping Python setup.
        goto :install_acestep
    )
    echo [install] Found broken virtual environment (python.exe won't run) — recreating it.
    rmdir /s /q "%VENV_DIR%"
)

:: ----------------------------------------------------------
:: Install pyenv-win locally (under AI_DIR)
:: ----------------------------------------------------------
echo [install] Setting up pyenv-win ...
if not exist "%PYENV_DIR%" (
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

set "PATH=%PYENV_DIR%\bin;%PYENV_DIR%\shims;%PATH%"

:: ----------------------------------------------------------
:: Install Python 3.10 via pyenv-win
:: ----------------------------------------------------------
echo [install] Installing Python %PYTHON_VERSION% ...
call "%PYENV_DIR%\bin\pyenv.bat" install %PYTHON_VERSION% --skip-existing
if errorlevel 1 (
    echo [install] ERROR: Python %PYTHON_VERSION% installation failed.
    pause & exit /b 1
)
set "PYTHON_EXE=%PYENV_DIR%\versions\%PYTHON_VERSION%\python.exe"
if not exist "%PYTHON_EXE%" (
    echo [install] ERROR: Expected Python not found at:
    echo            %PYTHON_EXE%
    echo [install] Run  pyenv versions  to see installed runtimes.
    pause & exit /b 1
)

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

:install_acestep
:: ----------------------------------------------------------
:: Helper: pip with retry (3 attempts)
:: pip_retry is called as: call :pip_retry <args>
:: ----------------------------------------------------------
goto :skip_pip_retry_def

:pip_retry
    set "_PIP_ARGS=%*"
    for /L %%i in (1,1,3) do (
        echo [install] pip !_PIP_ARGS! (attempt %%i)
        call "%VENV_DIR%\Scripts\pip.exe" !_PIP_ARGS!
        if not errorlevel 1 goto :pip_retry_ok
        echo [install] pip attempt %%i failed — retrying in 3s ...
        timeout /t 3 >nul
    )
    echo [install] ERROR: pip failed after 3 attempts.
    echo [install] Command: pip !_PIP_ARGS!
    pause & exit /b 1
:pip_retry_ok
    goto :eof

:skip_pip_retry_def

:: ----------------------------------------------------------
:: Upgrade pip
:: ----------------------------------------------------------
call :pip_retry install --upgrade pip

:: ----------------------------------------------------------
:: Detect NVIDIA GPU
:: ----------------------------------------------------------
echo [install] Detecting GPU ...
nvidia-smi >nul 2>&1
if not errorlevel 1 (
    echo [install] NVIDIA GPU detected — installing CUDA 12.6 PyTorch wheels.
    echo [install] (ACE-Step recommends cu126 per their Windows installation guide)
    set "TORCH_INDEX=https://download.pytorch.org/whl/cu126"
    set "GPU_DETECTED=1"
) else (
    echo [install] No NVIDIA GPU detected — installing CPU-only PyTorch.
    echo.
    echo  *** WARNING ***
    echo  ACE-Step is designed for CUDA-capable GPUs.
    echo  CPU generation will be extremely slow (minutes per clip).
    echo  Low-VRAM / no-GPU flags will be set in the launcher automatically:
    echo    --cpu_offload true
    echo  ***************
    echo.
)

:: ----------------------------------------------------------
:: Install PyTorch (ACE-Step README: cu126 for Windows/NVIDIA)
:: ----------------------------------------------------------
call :pip_retry install torch torchvision torchaudio --index-url !TORCH_INDEX!

:: ----------------------------------------------------------
:: Install huggingface_hub for download_model.py
:: ----------------------------------------------------------
call :pip_retry install huggingface_hub

:: ----------------------------------------------------------
:: Install ACE-Step from GitHub (includes all core deps)
:: Skip if already importable
:: ----------------------------------------------------------
echo [install] Checking if ACE-Step is already installed ...
"%VENV_DIR%\Scripts\python.exe" -c "import acestep" >nul 2>&1
if not errorlevel 1 (
    echo [install] ACE-Step already installed — skipping.
    goto :pick_model
)

echo [install] Installing ACE-Step from GitHub ...
call :pip_retry install "git+https://github.com/ace-step/ACE-Step.git"

:: ----------------------------------------------------------
:: Install Gradio (web UI)
:: ----------------------------------------------------------
call :pip_retry install gradio

:pick_model
:: ----------------------------------------------------------
:: Model / checkpoint selection
:: ----------------------------------------------------------
echo.
echo ============================================================
echo  ACE-Step Checkpoint Selection
echo ============================================================
echo.
echo  Available checkpoints (all on https://huggingface.co/ACE-Step):
echo.
echo  [1] ACE-Step-v1-3.5B          ~14 GB  (recommended base model)
echo      Full music generation, all features
echo.
echo  [2] ACE-Step-v1.5             ~14 GB  (latest version, improved quality)
echo      Best overall quality as of 2026-01
echo.
echo  [3] ACE-Step-v1-chinese-rap-LoRA  ~1 GB  (RapMachine LoRA — requires base model)
echo      Chinese rap generation add-on
echo.
echo  VRAM guidance:
echo    8 GB+  : Any option with --cpu_offload true (slower)
echo    12 GB+ : Base model, standard quality
echo    16 GB+ : Base model, full speed
echo.
set /p CHOICE="Enter choice [1]: "
if "!CHOICE!"=="" set "CHOICE=1"

if "!CHOICE!"=="1" (
    set "REPO_ID=ACE-Step/ACE-Step-v1-3.5B"
    set "MODEL_NAME=ACE-Step-v1-3.5B"
    set "CHECKPOINT_SUBDIR=checkpoints"
)
if "!CHOICE!"=="2" (
    set "REPO_ID=ACE-Step/ACE-Step-v1.5"
    set "MODEL_NAME=ACE-Step-v1.5"
    set "CHECKPOINT_SUBDIR=checkpoints"
)
if "!CHOICE!"=="3" (
    set "REPO_ID=ACE-Step/ACE-Step-v1-chinese-rap-LoRA"
    set "MODEL_NAME=ACE-Step-v1-chinese-rap-LoRA"
    set "CHECKPOINT_SUBDIR=checkpoints-lora"
)

if not defined REPO_ID (
    echo [install] Invalid choice. Using default (ACE-Step-v1-3.5B).
    set "REPO_ID=ACE-Step/ACE-Step-v1-3.5B"
    set "MODEL_NAME=ACE-Step-v1-3.5B"
    set "CHECKPOINT_SUBDIR=checkpoints"
)

:: Check if this checkpoint was already downloaded
if exist "%AI_DIR%\!CHECKPOINT_SUBDIR!\DOWNLOAD_COMPLETE" (
    echo [install] Checkpoint !MODEL_NAME! already downloaded.
    goto :generate_launcher
)

echo.
echo [install] Downloading !MODEL_NAME! from !REPO_ID! ...
echo [install] (Download is resumable — Ctrl+C and re-run the installer to continue.)
echo.

:: ----------------------------------------------------------
:: Download checkpoint via generalized download_model.py
:: ----------------------------------------------------------
"%VENV_DIR%\Scripts\python.exe" "%SCRIPT_DIR%download_model.py" ^
    "!REPO_ID!" "%AI_DIR%" ^
    --subdir "!CHECKPOINT_SUBDIR!"

if errorlevel 1 (
    echo.
    echo [install] ERROR: Checkpoint download failed.
    echo [install] Re-run this installer to resume the download.
    pause & exit /b 1
)

:generate_launcher
:: ----------------------------------------------------------
:: Determine GPU flags for the launcher
:: ----------------------------------------------------------
set "GPU_FLAGS=--bf16 true"
if "!GPU_DETECTED!"=="0" (
    set "GPU_FLAGS=--bf16 false --cpu_offload true"
)

:: ----------------------------------------------------------
:: Generate run_acestep.bat launcher
:: ----------------------------------------------------------
set "LAUNCHER=%SCRIPT_DIR%run_acestep.bat"
set "CHECKPOINT_PATH=%AI_DIR%\!CHECKPOINT_SUBDIR!"

(
    echo @echo off
    echo setlocal
    echo title ACE-Step - !MODEL_NAME!
    echo.
    echo :: Activate virtual environment
    echo call "%VENV_DIR%\Scripts\activate.bat"
    echo.
    echo :: Launch ACE-Step Gradio GUI
    echo :: Flags:
    echo ::   --checkpoint_path  : local checkpoint directory
    echo ::   --port             : Gradio server port
    echo ::   --bf16             : use bfloat16 precision (faster, GPU only)
    echo ::   --cpu_offload      : offload weights to CPU to save VRAM
    echo ::   --torch_compile    : compile model for extra speed (optional)
    echo ::   --overlapped_decode: faster decoding (optional)
    echo echo Starting ACE-Step on http://127.0.0.1:7865
    echo echo Close this window to stop the server.
    echo echo.
    echo acestep --checkpoint_path "!CHECKPOINT_PATH!" --port 7865 !GPU_FLAGS!
    echo.
    echo pause
) > "!LAUNCHER!"

echo.
echo ============================================================
echo  Installation complete!
echo ============================================================
echo.
echo  Model location : !CHECKPOINT_PATH!
echo  Launcher       : !LAUNCHER!
echo.
echo  Double-click run_acestep.bat to start the Gradio web UI.
echo  Then open http://127.0.0.1:7865 in your browser.
echo.
if "!GPU_DETECTED!"=="0" (
    echo  NOTE: No GPU detected. Generation will be slow.
    echo  CPU offload is enabled automatically.
    echo  For faster generation, use a CUDA-capable GPU.
    echo.
)
echo  Optional speed flags you can add to run_acestep.bat:
echo    --torch_compile true    (faster, requires triton-windows on Windows)
echo    --overlapped_decode true (faster decoding)
echo    --cpu_offload true       (lower VRAM usage)
echo.
pause
