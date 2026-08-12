# AI Model One-Click Installers

A collection of one-click Windows installers for popular AI models.
Each installer sets up a fully self-contained local environment — **your global Python is never touched**.

---

## Installers

### FLUX.2 — Image Generation (`install.bat`)

Downloads and configures [FLUX.2](https://huggingface.co/black-forest-labs) for local image generation.

**What it does:**

1. Installs **pyenv-win** + **Python 3.11** locally under `flux2-model\`
2. Creates an isolated virtual environment
3. Detects NVIDIA GPU and installs CUDA or CPU-only PyTorch
4. Installs `diffusers`, `transformers`, and `gradio`
5. Prompts you to choose a checkpoint:
   - `FLUX.2-klein-4B` (~8 GB, 4 GB+ VRAM)
   - `FLUX.2-standard-8B` (~16 GB, 8 GB+ VRAM)
   - `FLUX.1-dev` (~24 GB)
   - `FLUX.1-schnell` (~24 GB)
6. Downloads the checkpoint via `download_model.py` (resumable)
7. Generates `run_flux2.bat` launcher

**To run:**

```
install.bat
```

Then double-click `run_flux2.bat` to launch.

---

### ACE-Step — Music/Audio Generation (`install_acestep.bat`)

Downloads and configures [ACE-Step](https://github.com/ace-step/ACE-Step) for local music generation.

**What it does:**

1. Installs **pyenv-win** + **Python 3.10** locally under `acestep-model\`
2. Creates an isolated virtual environment
3. Detects NVIDIA GPU and installs CUDA 12.6 or CPU-only PyTorch
4. Installs ACE-Step from GitHub (`pip install git+https://...`) plus `gradio`
5. Prompts you to choose a checkpoint:

   | Option | Repo ID | Size | Notes |
   |--------|---------|------|-------|
   | 1 (default) | `ACE-Step/ACE-Step-v1-3.5B` | ~14 GB | Recommended base model |
   | 2 | `ACE-Step/ACE-Step-v1.5` | ~14 GB | Latest, improved quality (Jan 2026) |
   | 3 | `ACE-Step/ACE-Step-v1-chinese-rap-LoRA` | ~1 GB | RapMachine LoRA (requires base model) |

6. Downloads checkpoint via `download_model.py` (resumable)
7. Generates `run_acestep.bat` launcher pointing at the downloaded checkpoint

**To run:**

```
install_acestep.bat
```

Then double-click `run_acestep.bat` to open the Gradio UI at `http://127.0.0.1:7865`.

**No GPU?** The installer detects this automatically and enables `--cpu_offload true`. Generation will be slow but functional.

**License:**
- Code: [Apache-2.0](https://github.com/ace-step/ACE-Step/blob/main/LICENSE)
- Model weights: see the [model card](https://huggingface.co/ACE-Step/ACE-Step-v1-3.5B) on Hugging Face for the specific weight license.

---

## Resumable Downloads

All downloads go through `download_model.py`, which uses **aria2c** for fast parallel + resumable transfers.

If a download is interrupted, simply **re-run the installer** — it picks up where it left off.

A `DOWNLOAD_COMPLETE` marker file is written when all files are verified. The next run skips the download automatically.

---

## Generic Downloader (`download_model.py`)

A general-purpose Hugging Face downloader that any installer in this repo can reuse.

### Flags

| Flag | Default | Description |
|------|---------|-------------|
| `repo_id` | *(required)* | HF repo ID, e.g. `"black-forest-labs/FLUX.1-dev"` |
| `ai_dir` | *(required)* | Parent destination directory |
| `--subdir NAME` | `model` | Subdirectory under `ai_dir` where files land |
| `--repo-type {model,dataset,space}` | `model` | Repository type |
| `--revision REV` | `main` | Git revision / branch / tag |
| `--allow PATTERN` | *(none)* | Glob allow-list (repeatable); only matching files downloaded |
| `--ignore PATTERN` | *(none)* | Extra glob ignore patterns (repeatable) |
| `--include-default-ignores` | auto | Always apply built-in media/GGUF ignore list |
| `--no-default-ignores` | — | Skip built-in ignore list even without `--allow` |
| `--threads N` | `8` | aria2c connections per server |
| `--concurrent N` | `4` | aria2c concurrent downloads |
| `--token TOKEN` | *(env/cli)* | Explicit HF token (falls back to `HF_TOKEN` env var) |
| `--no-aria2` | — | Skip aria2c, use `snapshot_download` directly |
| `--force` | — | Re-download even if `DOWNLOAD_COMPLETE` marker exists |

**Default ignore behavior:**
- When `--allow` is **not** given: built-in media/GGUF patterns are applied (skips `*.gguf`, `*.mp4`, images, etc.)
- When `--allow` **is** given: default ignores are skipped (so your explicit list is respected)
- Override with `--include-default-ignores` / `--no-default-ignores`

### Example Invocations

```bash
# 1. Download a model (default subdir "model/"):
python download_model.py "black-forest-labs/FLUX.1-dev" "ai-model"

# 2. Download only .safetensors files to a custom subdir:
python download_model.py "stabilityai/stable-diffusion-xl-base-1.0" "ai" \
    --subdir sd_xl --allow "*.safetensors"

# 3. Download a dataset:
python download_model.py "HuggingFaceH4/ultrachat_200k" "datasets" \
    --repo-type dataset --subdir ultrachat

# 4. Download ACE-Step checkpoints:
python download_model.py "ACE-Step/ACE-Step-v1-3.5B" "ai" --subdir checkpoints
```

### Importable API

```python
from download_model import download_repo

ok = download_repo(
    repo_id="ACE-Step/ACE-Step-v1-3.5B",
    dest="ai",
    subdir="checkpoints",
    repo_type="model",
    allow=["*.safetensors", "*.json"],   # optional allow-list
)
```

---

## Requirements

- **Windows 10/11** (installers are `.bat` files)
- **Internet connection**
- **Git** (for `pip install git+https://...`)
- Disk space per model (see size column above)
- NVIDIA GPU recommended; CPU-only is supported but slow
