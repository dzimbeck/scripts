@echo off
setlocal EnableDelayedExpansion
title ACE-Step One-Click Installer

:: ============================================================
:: ACE-Step One-Click Installer
:: Installs Python 3.10 + venv fully locally under
::   acestep-model\  (next to this script) - no system Python needed.
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
set "VENV_DIR=%AI_DIR%\venv"
set "PYTHON_VERSION=3.10.11"
set "RUNTIME_DIR=%AI_DIR%\python-%PYTHON_VERSION%"
set "PYENV_DIR=%AI_DIR%\pyenv-win"
set "PY_NUGET_URL=https://www.nuget.org/api/v2/package/python/%PYTHON_VERSION%"
set "PYENV_ZIP_URL=https://github.com/pyenv-win/pyenv-win/archive/refs/heads/master.zip"
set "PY_EMBED_URL=https://www.python.org/ftp/python/%PYTHON_VERSION%/python-%PYTHON_VERSION%-embed-amd64.zip"
set "GET_PIP_URL=https://bootstrap.pypa.io/get-pip.py"

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
:: must not be treated as "installed" - recreate the venv.
:: ----------------------------------------------------------
if exist "%VENV_DIR%\Scripts\python.exe" (
    "%VENV_DIR%\Scripts\python.exe" --version >nul 2>&1
    if not errorlevel 1 (
        echo [install] Virtual environment already present - skipping Python setup.
        goto :install_acestep
    )
    echo [install] Found broken virtual environment - recreating it.
    rmdir /s /q "%VENV_DIR%"
)

set "PIP_DIRECT=0"

:: A previous run may have finished via the embeddable fallback
:: (no venv, pip runs directly in the runtime). Detect and reuse it.
if exist "%RUNTIME_DIR%\python.exe" (
    "%RUNTIME_DIR%\python.exe" -m pip --version >nul 2>&1
    if not errorlevel 1 (
        echo [install] Embeddable Python runtime already present - skipping Python setup.
        set "PIP_DIRECT=1"
        set "DIRECT_PY=%RUNTIME_DIR%\python.exe"
        set "DIRECT_DIR=%RUNTIME_DIR%\"
        goto :install_acestep
    )
)

:: ----------------------------------------------------------
:: Provision a local Python %PYTHON_VERSION% under AI_DIR.
:: Method 1 (preferred): official full CPython build published
:: on NuGet by the python.org team (includes venv + ensurepip).
:: NOTE: the python.org "embeddable" zip must NOT be used here -
:: it ships without the venv module ("No module named venv").
:: Method 2 (fallback): pyenv-win from GitHub, still local.
:: Method 3 (last resort): embeddable package + get-pip,
:: pip runs directly in the runtime (no venv needed).
:: ----------------------------------------------------------
set "PYTHON_EXE="
set "PY_TMP=%AI_DIR%\_pytmp"
if not exist "%AI_DIR%" mkdir "%AI_DIR%"
if exist "%PY_TMP%" rmdir /s /q "%PY_TMP%"
mkdir "%PY_TMP%"
:: Remove any stale/incomplete runtime from a previous run
if exist "%RUNTIME_DIR%" rmdir /s /q "%RUNTIME_DIR%"

echo [install] Downloading Python %PYTHON_VERSION% (full, official NuGet build) ...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; " ^
    "(New-Object System.Net.WebClient).DownloadFile('%PY_NUGET_URL%', '%PY_TMP%\python-nuget.zip')"
if not exist "%PY_TMP%\python-nuget.zip" (
    echo [install] NuGet download failed - trying pyenv-win from GitHub ...
    goto :try_pyenv
)

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "Expand-Archive -Path '%PY_TMP%\python-nuget.zip' -DestinationPath '%PY_TMP%\nuget' -Force"
if not exist "%PY_TMP%\nuget\tools\python.exe" (
    echo [install] Extract failed - trying pyenv-win from GitHub ...
    goto :try_pyenv
)
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "Move-Item -Path '%PY_TMP%\nuget\tools' -Destination '%RUNTIME_DIR%' -Force"
if not exist "%RUNTIME_DIR%\python.exe" (
    echo [install] Runtime install failed - trying pyenv-win from GitHub ...
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
    echo [install] pyenv-win unavailable - using embeddable Python + get-pip ...
    goto :try_embeddable
)
set "PYENV=%PYENV_DIR%\"
set "PYENV_ROOT=%PYENV_DIR%\"
set "PYENV_HOME=%PYENV_DIR%\"
set "PATH=%PYENV_DIR%\bin;%PYENV_DIR%\shims;%PATH%"
call "%PYENV_DIR%\bin\pyenv.bat" install %PYTHON_VERSION% --skip-existing
if errorlevel 1 (
    echo [install] pyenv install failed - using embeddable Python + get-pip ...
    goto :try_embeddable
)
set "PYTHON_EXE=%PYENV_DIR%\versions\%PYTHON_VERSION%\python.exe"
if not exist "%PYTHON_EXE%" (
    echo [install] pyenv did not produce python.exe - using embeddable Python + get-pip ...
    goto :try_embeddable
)
goto :make_venv

:try_embeddable
echo [install] Downloading embeddable Python %PYTHON_VERSION% ...
if exist "%RUNTIME_DIR%" rmdir /s /q "%RUNTIME_DIR%"
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
set "DIRECT_PY=%RUNTIME_DIR%\python.exe"
set "DIRECT_DIR=%RUNTIME_DIR%\"
goto :install_acestep

:make_venv
if not exist "%PYTHON_EXE%" (
    echo [install] ERROR: local Python not found at %PYTHON_EXE%
    pause & exit /b 1
)
echo [install] Local Python ready: %PYTHON_EXE%

:: ----------------------------------------------------------
:: Create virtual environment
:: The venv module must exist (embeddable builds lack it) -
:: if it's missing, fall back to the direct-pip runtime path.
:: ----------------------------------------------------------
"%PYTHON_EXE%" -c "import venv" >nul 2>&1
if errorlevel 1 (
    echo [install] This Python runtime has no venv module - using it directly instead.
    goto :use_runtime_direct
)
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
goto :install_acestep

:: Use the runtime directly (no venv): make sure pip is available.
:use_runtime_direct
"%PYTHON_EXE%" -m pip --version >nul 2>&1
if not errorlevel 1 goto :runtime_direct_ok
"%PYTHON_EXE%" -m ensurepip --default-pip >nul 2>&1
"%PYTHON_EXE%" -m pip --version >nul 2>&1
if errorlevel 1 (
    echo [install] Runtime has no pip either - falling back to embeddable + get-pip ...
    goto :try_embeddable
)
:runtime_direct_ok
set "PIP_DIRECT=1"
set "DIRECT_PY=%PYTHON_EXE%"
for %%D in ("%PYTHON_EXE%") do set "DIRECT_DIR=%%~dpD"
goto :install_acestep

:install_acestep
if exist "%PY_TMP%" rmdir /s /q "%PY_TMP%" 2>nul
:: ----------------------------------------------------------
:: Helper: pip with retry (3 attempts)
:: pip_retry is called as: call :pip_retry <args>
:: ----------------------------------------------------------
goto :skip_pip_retry_def

:pip_retry
    set "_PIP_ARGS=%*"
    for /L %%i in (1,1,3) do (
        echo [install] Running: pip !_PIP_ARGS! attempt %%i of 3
        if "!PIP_DIRECT!"=="1" (
            call "!DIRECT_PY!" -m pip !_PIP_ARGS!
        ) else (
            call "%VENV_DIR%\Scripts\python.exe" -m pip !_PIP_ARGS!
        )
        if not errorlevel 1 goto :pip_retry_ok
        echo [install] pip attempt %%i failed - retrying in 3s ...
        timeout /t 3 >nul
    )
    echo [install] ERROR: pip failed after 3 attempts.
    echo [install] Command: pip !_PIP_ARGS!
    pause & exit /b 1
:pip_retry_ok
    goto :eof

:skip_pip_retry_def
set "PIP_TARGET_PY=%VENV_DIR%\Scripts\python.exe"
if "!PIP_DIRECT!"=="1" set "PIP_TARGET_PY=!DIRECT_PY!"

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
    echo [install] NVIDIA GPU detected - installing CUDA 12.6 PyTorch wheels.
    echo [install] ACE-Step recommends cu126 per their Windows installation guide.
    set "TORCH_INDEX=https://download.pytorch.org/whl/cu126"
    set "GPU_DETECTED=1"
) else (
    echo [install] No NVIDIA GPU detected - installing CPU-only PyTorch.
    echo.
    echo  *** WARNING ***
    echo  ACE-Step is designed for CUDA-capable GPUs.
    echo  CPU generation will be extremely slow - minutes per clip.
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
"!PIP_TARGET_PY!" -c "import acestep" >nul 2>&1
if not errorlevel 1 (
    echo [install] ACE-Step already installed - skipping.
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
echo  [3] ACE-Step-v1-chinese-rap-LoRA  ~1 GB  (RapMachine LoRA - requires base model)
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
    echo [install] Invalid choice. Using default ACE-Step-v1-3.5B.
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
echo [install] Download is resumable - Ctrl+C and re-run the installer to continue.
echo.

:: ----------------------------------------------------------
:: Download checkpoint via generalized download_model.py
:: ----------------------------------------------------------
"!PIP_TARGET_PY!" "%SCRIPT_DIR%download_model.py" ^
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
set "ENV_PATH=%VENV_DIR%\Scripts"
if "!PIP_DIRECT!"=="1" set "ENV_PATH=!DIRECT_DIR!;!DIRECT_DIR!Scripts"

(
    echo @echo off
    echo setlocal
    echo title ACE-Step - !MODEL_NAME!
    echo.
    echo :: Put the installed Python environment on PATH
    echo set "PATH=!ENV_PATH!;%%PATH%%"
    echo.
    echo :: Launch ACE-Step Gradio GUI
    echo :: Flags:
    echo ::   --checkpoint_path  : local checkpoint directory
    echo ::   --port             : Gradio server port
    echo ::   --bf16             : use bfloat16 precision - faster on GPU only
    echo ::   --cpu_offload      : offload weights to CPU to save VRAM
    echo ::   --torch_compile    : compile model for extra speed - optional
    echo ::   --overlapped_decode: faster decoding - optional
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
