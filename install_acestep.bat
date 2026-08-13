@echo off
setlocal EnableDelayedExpansion
title ACE-Step 1.5 One-Click Installer

:: ============================================================
:: ACE-Step 1.5 One-Click Installer
:: Installs Python 3.11 + venv fully locally under
::   acestep-model\  (next to this script) - no system Python needed.
:: ACE-Step 1.5 requires Python 3.11-3.12; its prebuilt Windows
:: wheels (flash-attn / triton-windows for nano-vllm) are cp311,
:: so this installer uses Python 3.11.
:: Downloads chosen ACE-Step checkpoint via download_model.py
:: Generates run_acestep.bat launcher
::
:: ACE-Step 1.5: https://github.com/ace-step/ACE-Step-1.5
:: HF org:       https://huggingface.co/ACE-Step
:: License:      Code - MIT
::               Model weights - see model card on HF
:: ============================================================

set "SCRIPT_DIR=%~dp0"
set "AI_DIR=%SCRIPT_DIR%acestep-model"
set "VENV_DIR=%AI_DIR%\venv"
set "SRC_DIR=%AI_DIR%\ACE-Step-1.5"
set "ACESTEP_ZIP_URL=https://github.com/ace-step/ACE-Step-1.5/archive/refs/heads/main.zip"
set "PYTHON_VERSION=3.11.9"
set "RUNTIME_DIR=%AI_DIR%\python-%PYTHON_VERSION%"
set "PYENV_DIR=%AI_DIR%\pyenv-win"
set "PY_NUGET_URL=https://www.nuget.org/api/v2/package/python/%PYTHON_VERSION%"
set "PYENV_ZIP_URL=https://github.com/pyenv-win/pyenv-win/archive/refs/heads/master.zip"
set "PY_EMBED_URL=https://www.python.org/ftp/python/%PYTHON_VERSION%/python-%PYTHON_VERSION%-embed-amd64.zip"
set "GET_PIP_URL=https://bootstrap.pypa.io/get-pip.py"

echo ============================================================
echo  ACE-Step 1.5 One-Click Installer
echo  Music/Audio Generation Foundation Model
echo ============================================================
echo.
echo Install root : %AI_DIR%
echo.

:: ----------------------------------------------------------
:: GPU detection defaults (must stay out of the skipped setup
:: path so re-runs still set the correct launcher flags).
:: ACE-Step 1.5 pins torch==2.7.1+cu128 on Windows (see its
:: pyproject.toml), so the cu128 wheels are always installed -
:: they also run fine on CPU-only machines.
:: ----------------------------------------------------------
set "GPU_DETECTED=0"
set "TORCH_INDEX=https://download.pytorch.org/whl/cu128"

:: ----------------------------------------------------------
:: Skip Python setup only if the venv python actually WORKS
:: and is the Python 3.11 that ACE-Step 1.5 needs. A leftover
:: 3.10 venv from the old installer (or a corrupt python.exe)
:: must be recreated.
:: ----------------------------------------------------------
if exist "%VENV_DIR%\Scripts\python.exe" (
    "%VENV_DIR%\Scripts\python.exe" -c "import sys; sys.exit(0 if sys.version_info[:2] == (3, 11) else 1)" >nul 2>&1
    if not errorlevel 1 (
        echo [install] Virtual environment already present - skipping Python setup.
        goto :install_acestep
    )
    echo [install] Found old/broken virtual environment - recreating it with Python %PYTHON_VERSION%.
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
:: Detect NVIDIA GPU (only affects launcher flags - ACE-Step
:: 1.5 pins the cu128 PyTorch build on Windows either way)
:: ----------------------------------------------------------
echo [install] Detecting GPU ...
nvidia-smi >nul 2>&1
if not errorlevel 1 (
    echo [install] NVIDIA GPU detected.
    set "GPU_DETECTED=1"
) else (
    echo [install] No NVIDIA GPU detected.
    echo.
    echo  *** WARNING ***
    echo  ACE-Step is designed for CUDA-capable GPUs.
    echo  CPU generation will be extremely slow - minutes per clip.
    echo  CPU offload will be set in the launcher automatically:
    echo    --offload_to_cpu true
    echo  ***************
    echo.
)

:: ----------------------------------------------------------
:: Install PyTorch exactly as pinned by ACE-Step 1.5 for
:: Windows (pyproject.toml): torch==2.7.1+cu128,
:: torchvision==0.22.1+cu128, torchaudio==2.7.1+cu128
:: ----------------------------------------------------------
call :pip_retry install torch==2.7.1+cu128 torchvision==0.22.1+cu128 torchaudio==2.7.1+cu128 --index-url !TORCH_INDEX!

:: ----------------------------------------------------------
:: Install huggingface_hub for download_model.py
:: ----------------------------------------------------------
call :pip_retry install huggingface_hub

:: ----------------------------------------------------------
:: Install ACE-Step 1.5 from the GitHub zip archive (no git
:: needed). The source is extracted locally because its
:: vendored nano-vllm package (acestep\third_parts\nano-vllm)
:: is not on PyPI and must be installed from the source tree
:: before ACE-Step itself. All remaining dependency versions
:: (gradio==6.2.0, transformers, torchcodec, ...) come from
:: ACE-Step's own pyproject.toml pins.
:: Skip if already importable.
:: ----------------------------------------------------------
echo [install] Checking if ACE-Step is already installed ...
"!PIP_TARGET_PY!" -c "import acestep" >nul 2>&1
if not errorlevel 1 (
    echo [install] ACE-Step already installed - skipping.
    goto :pick_model
)

echo [install] Downloading ACE-Step 1.5 source (zip archive, no git required) ...
if exist "%SRC_DIR%" rmdir /s /q "%SRC_DIR%"
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; " ^
    "(New-Object System.Net.WebClient).DownloadFile('%ACESTEP_ZIP_URL%', '%AI_DIR%\acestep-src.zip'); " ^
    "Expand-Archive -Path '%AI_DIR%\acestep-src.zip' -DestinationPath '%AI_DIR%\_srctmp' -Force; " ^
    "Move-Item -Path '%AI_DIR%\_srctmp\ACE-Step-1.5-main' -Destination '%SRC_DIR%' -Force"
del "%AI_DIR%\acestep-src.zip" 2>nul
if exist "%AI_DIR%\_srctmp" rmdir /s /q "%AI_DIR%\_srctmp"
if not exist "%SRC_DIR%\pyproject.toml" (
    echo [install] ERROR: could not download/extract the ACE-Step 1.5 source.
    pause & exit /b 1
)

echo [install] Installing vendored nano-vllm (required by ACE-Step 1.5) ...
call :pip_retry install "%SRC_DIR%\acestep\third_parts\nano-vllm" --extra-index-url !TORCH_INDEX!

echo [install] Installing ACE-Step 1.5 and its pinned dependencies ...
call :pip_retry install "%SRC_DIR%" --extra-index-url !TORCH_INDEX!

:pick_model
:: ----------------------------------------------------------
:: Model / checkpoint selection
:: ACE-Step 1.5 expects each model in its own subfolder:
::   checkpoints\<model_name>\
:: Core components (vae, Qwen3-Embedding-0.6B text encoder,
:: acestep-v15-turbo, acestep-5Hz-lm-1.7B) are auto-downloaded
:: by ACE-Step on first launch if missing.
:: ----------------------------------------------------------
echo.
echo ============================================================
echo  ACE-Step 1.5 Checkpoint Selection
echo ============================================================
echo.
echo  Available checkpoints (all on https://huggingface.co/ACE-Step):
echo.
echo  [1] acestep-v15-base               ~14 GB  (recommended default checkpoint)
echo      Official ACE-Step 1.5 base model
echo.
echo  [2] acestep-v15-sft                ~14 GB  (instruction-tuned for prompts)
echo      Better prompt following, same ACE-Step 1.5 family
echo.
echo  [3] acestep-v15-turbo-continuous   ~14 GB  (fast generation variant)
echo      Turbo checkpoint focused on lower-latency generation
echo.
echo  NOTE: shared components (VAE, text encoder, language model)
echo  are downloaded automatically by ACE-Step on first launch.
echo.
echo  VRAM guidance:
echo    8 GB+  : Any option with CPU offload (slower)
echo    12 GB+ : Base model, standard quality
echo    16 GB+ : Base model, full speed
echo.
set /p CHOICE="Enter choice [1]: "
if "!CHOICE!"=="" set "CHOICE=1"

if "!CHOICE!"=="1" (
    set "REPO_ID=ACE-Step/acestep-v15-base"
    set "MODEL_NAME=acestep-v15-base"
)
if "!CHOICE!"=="2" (
    set "REPO_ID=ACE-Step/acestep-v15-sft"
    set "MODEL_NAME=acestep-v15-sft"
)
if "!CHOICE!"=="3" (
    set "REPO_ID=ACE-Step/acestep-v15-turbo-continuous"
    set "MODEL_NAME=acestep-v15-turbo-continuous"
)

if not defined REPO_ID (
    echo [install] Invalid choice. Using default acestep-v15-base.
    set "REPO_ID=ACE-Step/acestep-v15-base"
    set "MODEL_NAME=acestep-v15-base"
)
set "CHECKPOINT_SUBDIR=checkpoints\!MODEL_NAME!"

:: ----------------------------------------------------------
:: Migrate checkpoints downloaded by an older version of this
:: installer (which placed model files flat in checkpoints\)
:: into the checkpoints\<model_name>\ layout ACE-Step 1.5
:: expects - no re-download needed.
:: ----------------------------------------------------------
if exist "%AI_DIR%\checkpoints\DOWNLOAD_COMPLETE" (
    rem Identify which model the old flat download actually was from its
    rem MODEL_SOURCE.txt marker (repo_id=ACE-Step/<model_name>), falling
    rem back to the currently selected model if the marker is missing.
    set "OLD_MODEL=!MODEL_NAME!"
    if exist "%AI_DIR%\checkpoints\MODEL_SOURCE.txt" (
        for /f "tokens=2 delims=/" %%A in ('findstr /b /c:"repo_id=" "%AI_DIR%\checkpoints\MODEL_SOURCE.txt"') do set "OLD_MODEL=%%A"
    )
    echo [install] Migrating previously downloaded checkpoint into checkpoints\!OLD_MODEL!\ ...
    move "%AI_DIR%\checkpoints" "%AI_DIR%\_ckpt_migrate" >nul
    mkdir "%AI_DIR%\checkpoints"
    move "%AI_DIR%\_ckpt_migrate" "%AI_DIR%\checkpoints\!OLD_MODEL!" >nul
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
    --subdir "!CHECKPOINT_SUBDIR!" ^
    --no-default-ignores

if errorlevel 1 (
    echo.
    echo [install] ERROR: Checkpoint download failed.
    echo [install] Re-run this installer to resume the download.
    pause & exit /b 1
)

:generate_launcher
:: ----------------------------------------------------------
:: Determine GPU flags for the launcher (ACE-Step 1.5 flags)
:: ----------------------------------------------------------
set "GPU_FLAGS="
if "!GPU_DETECTED!"=="0" (
    set "GPU_FLAGS=--offload_to_cpu true"
)

:: ----------------------------------------------------------
:: Generate run_acestep.bat launcher
:: ----------------------------------------------------------
set "LAUNCHER=%SCRIPT_DIR%run_acestep.bat"
set "CHECKPOINT_ROOT=%AI_DIR%\checkpoints"
set "ENV_PATH=%VENV_DIR%\Scripts"
if "!PIP_DIRECT!"=="1" set "ENV_PATH=!DIRECT_DIR!;!DIRECT_DIR!Scripts"

(
    echo @echo off
    echo setlocal
    echo title ACE-Step 1.5 - !MODEL_NAME!
    echo.
    echo :: Put the installed Python environment on PATH
    echo set "PATH=!ENV_PATH!;%%PATH%%"
    echo.
    echo :: Point ACE-Step at the locally downloaded checkpoints.
    echo :: Missing shared components (VAE, text encoder, LM^) are
    echo :: auto-downloaded here on first launch.
    echo set "ACESTEP_CHECKPOINTS_DIR=!CHECKPOINT_ROOT!"
    echo.
    echo :: Launch ACE-Step 1.5 Gradio GUI
    echo :: Flags:
    echo ::   --config_path      : DiT model to load (folder name under checkpoints\^)
    echo ::   --port             : Gradio server port
    echo ::   --offload_to_cpu   : offload weights to CPU to save VRAM
    echo echo Starting ACE-Step on http://127.0.0.1:7860
    echo echo Close this window to stop the server.
    echo echo.
    echo acestep --config_path !MODEL_NAME! --port 7860 !GPU_FLAGS!
    echo.
    echo pause
) > "!LAUNCHER!"

echo.
echo ============================================================
echo  Installation complete!
echo ============================================================
echo.
echo  Model location : !CHECKPOINT_ROOT!\!MODEL_NAME!
echo  Launcher       : !LAUNCHER!
echo.
echo  Double-click run_acestep.bat to start the Gradio web UI.
echo  Then open http://127.0.0.1:7860 in your browser.
echo.
if "!GPU_DETECTED!"=="0" (
    echo  NOTE: No GPU detected. Generation will be slow.
    echo  CPU offload is enabled automatically.
    echo  For faster generation, use a CUDA-capable GPU.
    echo.
)
echo  Optional flags you can add to run_acestep.bat:
echo    --offload_to_cpu true   (lower VRAM usage)
echo    --lm_model_path acestep-5Hz-lm-0.6B  (smaller language model for low VRAM)
echo    --init_llm false        (DiT-only mode for very low VRAM)
echo.
pause
