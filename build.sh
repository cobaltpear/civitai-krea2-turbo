#!/bin/sh
# Krea 2 Turbo Universal (any Krea 2 Turbo model from Civitai or Hugging Face) — everything the worker image needs. The Dockerfile in your copy downloads this file
# from the original repo on every build, so fixes made there reach you with a rebuild.
set -eu
# civitai.env in your copy (made by Cobalt Pear's «Add your token» link) wins over the two Dockerfile lines
if [ -f /setup/civitai.env ]; then
  for k in CIVITAI_TOKEN CIVITAI_MODEL HF_TOKEN; do
    v=$(sed -n "s/^[[:space:]]*$k[[:space:]]*=//p" /setup/civitai.env | tr -d '\r"'"'"' ' | head -n 1)
    [ -z "$v" ] || eval "$k=\$v"
  done
fi
export CIVITAI_TOKEN CIVITAI_MODEL HF_TOKEN
case "${CIVITAI_MODEL:-}" in ""|PASTE_*) echo "ERROR: put the model in civitai.env (or at the top of the Dockerfile) — its Civitai page link or version number, or its Hugging Face link" >&2; exit 1;; esac

# Find the one file the link means, check it is a Krea 2 model, then download it and check its SHA-256.
# Civitai: its API names the file. Hugging Face: the repo's single-file model (a .safetensors at its top, not the diffusers folders).
# The model is always saved as diffusion_models/model.safetensors — the pack's workflow loads that name.
python3 - <<'PY'
import hashlib, json, os, re, struct, sys, urllib.request
token, link, hf_token = os.environ.get("CIVITAI_TOKEN", ""), os.environ["CIVITAI_MODEL"].strip(), os.environ.get("HF_TOKEN", "")
def fail(msg): sys.exit("ERROR: " + msg)
def is_krea2(keys): return any(re.sub(r"^(model\.)?diffusion_model\.", "", k).startswith("txtfusion.") for k in keys)
def download(url, dest, sha, name, headers={}):
    h = hashlib.sha256()
    with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "cobaltpear", **headers}), timeout=600) as r, open(dest, "wb") as out:
        while chunk := r.read(1 << 22): h.update(chunk); out.write(chunk)
    if sha and h.hexdigest() != sha: fail(f"{name} does not match its SHA-256 — try the build again")
    print("SHA-256 OK" if sha else "No SHA-256 listed for this file — not checked")
dest = "/comfyui/models/diffusion_models/model.safetensors"
hf = None if "civitai.com" in link or re.fullmatch(r"\d+", link) else \
    re.fullmatch(r"(?:https?://huggingface\.co/)?([\w.-]+/[\w.-]+)(?:/(?:blob|resolve|tree)/[^/]+(?:/(.+?))?)?/?(?:\?.*)?", link)
if hf:
    repo, want = hf.group(1), hf.group(2)
    auth = {"Authorization": "Bearer " + hf_token} if hf_token and not hf_token.startswith("PASTE_") else {}
    def get(url, **kw):
        try: return urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "cobaltpear", **auth, **kw}), timeout=60)
        except urllib.error.HTTPError as e:
            fail(f"Hugging Face answered {e.code} for {repo}" + (" — it is gated: accept its license on its page and put HF_TOKEN=<a Read token> in civitai.env" if e.code in (401, 403) else ""))
    info = json.load(get(f"https://huggingface.co/api/models/{repo}?blobs=true"))
    files = [f for f in info.get("siblings", []) if f["rfilename"].endswith(".safetensors") and (f["rfilename"] == want if want else "/" not in f["rfilename"])]
    files = [f for f in files if f.get("size", 0) > 3e+09 or want]  # a whole model, not a VAE or a LoRA
    if not files: fail(f"{repo} has no single-file checkpoint (.safetensors) at its top — it only has diffusers folders, which this worker can't load")
    f = min(files, key=lambda f: f.get("size", 0))  # fp16 rather than fp32
    url = f"https://huggingface.co/{repo}/resolve/main/{f['rfilename']}"
    head = get(url, Range="bytes=0-7").read(); n = struct.unpack("<Q", head)[0]
    keys = list(json.loads(get(url, Range=f"bytes=8-{7 + n}").read()))
    if not is_krea2(keys): fail(f"{f['rfilename']} is not a Krea 2 model — this worker takes Krea 2 Turbo models only")
    print(f"Hugging Face: {repo} — {f['rfilename']}")
    print(f"Downloading {f['rfilename']} ({f.get('size', 0) / 1e9:.1f} GB)")
    download(url, dest, (f.get("lfs") or {}).get("sha256", ""), f["rfilename"], auth)
    json.dump({"repo": repo, "name": repo.split("/")[-1], "file": f["rfilename"], "base": "Krea 2 Turbo"}, open("/comfyui/models/diffusion_models/model.json", "w"))
    sys.exit(0)
if not token or token.startswith("PASTE_"): fail("put your Civitai token in civitai.env (or at the top of the Dockerfile)")
# the whole model as one .safetensors that plain ComfyUI loads: INT8 first, then FP8 (not GGUF, NVFP4, INT4, MXFP8, BF16)
def rank(f):
    fp, name = (f.get("metadata", {}).get("fp") or "").lower(), f["name"].lower()
    if f.get("type") not in ("Model", "Diffusion Model") or not name.endswith(".safetensors") or f.get("sizeKB", 0) < 10e6: return None
    if re.search(r"nvfp4|int4|gguf|mxfp|w[0-7]a\d", name) or fp in ("nvfp4", "int4", "mxfp8"): return None
    return 0 if fp == "int8" or "int8" in name else 1 if fp == "fp8" or "fp8" in name else None
def usable(v): return sorted((f for f in v.get("files", []) if rank(f) is not None), key=lambda f: (rank(f), f.get("sizeKB", 0)))
def signed(f): return f["downloadUrl"] + ("&" if "?" in f["downloadUrl"] else "?") + "token=" + token
def part(f, a, b): return urllib.request.urlopen(urllib.request.Request(signed(f), headers={"Range": f"bytes={a}-{b}", "User-Agent": "cobaltpear"}), timeout=120).read()
def opens(f):
    try: part(f, 0, 7); return True
    except urllib.error.HTTPError as e:
        if e.code in (401, 403): return False
        raise
def get(path):
    req = urllib.request.Request("https://civitai.com/api/v1/" + path, headers={"Authorization": "Bearer " + token, "User-Agent": "cobaltpear"})
    try: return json.load(urllib.request.urlopen(req, timeout=60))
    except Exception as e: fail(f"could not ask Civitai about {link!r} ({e})")
m = re.search(r"modelVersionId=(\d+)", link) or re.fullmatch(r"(\d+)", link)
if m: version = get(f"model-versions/{m.group(1)}")
else:
    m = re.search(r"/models/(\d+)", link) or fail(f"CIVITAI_MODEL {link!r} is not a Civitai model link")
    vs = get(f"models/{m.group(1)}")["modelVersions"]
    mine = [v for v in vs if v.get("baseModel") == "Krea 2 Turbo"] or fail("no version of this model is Krea 2 Turbo" + (" — its versions are Krea 2: use cobaltpear/civitai-krea2 for it" if any(v.get("baseModel") == "Krea 2" for v in vs) else ""))
    version = next((v for v in mine if usable(v) and opens(usable(v)[0])), None) or fail("no version of this model has an INT8 or FP8 .safetensors file your token can download (Early Access versions need Buzz on Civitai)")   # the newest one
    version = get(f"model-versions/{version['id']}")
base, kind = version.get("baseModel", ""), version.get("model", {}).get("type", "")
print(f"Civitai: {version.get('model', {}).get('name')} — {version.get('name')} (version {version['id']}, {base}, {kind})")
if kind != "Checkpoint": fail(f"this is a {kind}, not a Checkpoint")
if base == "Krea 2": fail("this model's base is Krea 2 — use cobaltpear/civitai-krea2 for it (this worker takes Krea 2 Turbo models only)")
if base != "Krea 2 Turbo": fail(f"this model's base is {base} — this worker takes Krea 2 Turbo models only")
files = usable(version)
if not files: fail("no INT8 or FP8 .safetensors file of the whole model in this version (GGUF, NVFP4, INT4 and BF16 files are not taken) — pick another version")
f = files[0]
if not opens(f): fail("Civitai won't let your token download this version — it may be in Early Access (pay with Buzz on its page) — pick another version")
n = struct.unpack("<Q", part(f, 0, 7))[0]
if not is_krea2(json.loads(part(f, 8, 7 + n))): fail(f"{f['name']} is not a Krea 2 model inside, though Civitai lists it as {base} — pick another version")
print(f"Downloading {f['name']} ({f.get('sizeKB', 0) / 1e6:.1f} GB)")
download(signed(f), dest, f.get("hashes", {}).get("SHA256", "").lower(), f["name"])
json.dump({"version": version["id"], "name": version.get("model", {}).get("name"), "file": f["name"], "base": base}, open("/comfyui/models/diffusion_models/model.json", "w"))
PY

# the text encoder and VAE every Krea 2 model uses (Comfy-Org repack), pinned by SHA-256
file() {
  wget -q -O "$1" "$2"
  echo "$3  $1" | sha256sum -c - || { echo "ERROR: $1 changed upstream — wait for an update of the original repo, then rebuild" >&2; exit 1; }
}

HF=https://huggingface.co/Comfy-Org/Krea-2/resolve/eb1eddd3983a54678545a9b2c178c5853b30f7be
file /comfyui/models/text_encoders/qwen3vl_4b_fp8_scaled.safetensors "$HF/text_encoders/qwen3vl_4b_fp8_scaled.safetensors" \
  54bd5144df0bbc25dd6ccadfcb826b521445a1b06ae5a42570bdd2974ca87094
file /comfyui/models/vae/qwen_image_vae.safetensors "$HF/vae/qwen_image_vae.safetensors" \
  a70580f0213e67967ee9c95f05bb400e8fb08307e017a924bf3441223e023d1f

# Krea 2 needs a newer ComfyUI than the base image has (INT8 files load natively)
cd /comfyui
git fetch --depth 1 https://github.com/Comfy-Org/ComfyUI.git tag v0.43.1
git checkout -f v0.43.1
uv pip install --python /opt/venv/bin/python -r requirements.txt "transformers>=4.50.3,<5" "huggingface-hub<1.0"
timeout 300 /opt/venv/bin/python main.py --quick-test-for-ci --cpu
