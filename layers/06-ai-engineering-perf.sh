#!/usr/bin/env bash
#
# layers/06-ai-engineering-perf.sh
#
# What "beast for AI/engineering" actually decomposes into on this
# hardware — none of it is custom CPU/iGPU code, all of it is real,
# existing software correctly wired up:
#   - iGPU compute exposed to real frameworks (OpenVINO, PyTorch XPU) via
#     the Level Zero runtime, instead of the iGPU sitting unused outside
#     of display/video decode.
#   - A pluggable CPU scheduler (sched_ext) instead of accepting whatever
#     the default gives you under mixed compile+inference+desktop load.
#   - The actual 8GB bottleneck addressed where it's real: memory
#     pressure handling (earlyoom) and swappiness tuned for zram, not
#     "faster CPU/GPU" — RAM headroom is what running multiple heavy
#     things at once actually costs you here.
#   - Dev-workflow plumbing (ccache, containers/VMs, inotify/ulimits)
#     that engineering work needs regardless of AI workload.
#
# This is an enhancement layer on an already-bootable system — marked
# "soft" in the manifest. Individual package failures are logged and
# skipped rather than aborting the whole layer, since there's no reason
# a missing/renamed package for one piece should cost you all the others.
#
set -uo pipefail  # deliberately not -e — see per-step error handling below

ICARUS_LOG_DIR="${ICARUS_LOG_DIR:-/var/log/icarus}"
SENTINEL="${ICARUS_LOG_DIR}/layer-6-ai-engineering-perf.done"
PREV_SENTINEL="${ICARUS_LOG_DIR}/layer-5-ui-winhybrid.done"

log() { echo "[layer-6] $*"; }
warn() { echo "[layer-6] WARNING: $*" >&2; }
fatal() { echo "[layer-6] FATAL: $*" >&2; exit 1; }

[[ -f "$PREV_SENTINEL" ]] || fatal "Layer 5 sentinel not found (${PREV_SENTINEL})."

try_install() {
    # $@ = package names. Logs and continues on failure instead of
    # aborting the layer — see the file header for why.
    if ! pacman -S --noconfirm --needed "$@"; then
        warn "Failed to install one or more of: $* — continuing without it/them."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# 1. iGPU compute runtime — this is what actually exposes the Iris Xe to
#    anything beyond display/video decode. Without this, OpenVINO/PyTorch
#    XPU below have nothing to talk to.
# ---------------------------------------------------------------------------
log "Installing Intel GPU compute runtime (Level Zero + OpenCL)..."
try_install intel-compute-runtime level-zero-loader clinfo

# ---------------------------------------------------------------------------
# 2. Python AI stack, in a venv (Arch's system Python is externally
#    managed — PEP 668 — so this isn't optional plumbing, it's required).
#    Owned by icarus, not root, since that's who'll actually use it.
# ---------------------------------------------------------------------------
log "Setting up the AI venv..."
try_install python python-pip
if id icarus &>/dev/null; then
    AI_VENV="/home/icarus/.venvs/ai"
    sudo -u icarus mkdir -p "$(dirname "$AI_VENV")"
    if sudo -u icarus python -m venv "$AI_VENV"; then
        sudo -u icarus bash -c "
            source '${AI_VENV}/bin/activate'
            pip install --upgrade pip
            pip install openvino openvino-dev
            pip install torch --index-url https://download.pytorch.org/whl/xpu
        " || warn "One or more pip installs into ${AI_VENV} failed — check network access and retry manually: source ${AI_VENV}/bin/activate && pip install openvino torch --index-url https://download.pytorch.org/whl/xpu"
        log "AI venv ready at ${AI_VENV} — activate with: source ${AI_VENV}/bin/activate"
    else
        warn "Could not create the AI venv at ${AI_VENV}."
    fi
else
    warn "User 'icarus' not found — skipping AI venv setup."
fi

# ---------------------------------------------------------------------------
# 3. llama.cpp + OpenVINO backend — NOT auto-built here. Intel's OpenVINO
#    backend for llama.cpp is genuinely new (OpenVINO 2026.1, June 2026)
#    and the exact CMake flags are a moving target. Baking a fragile
#    from-source build into an unattended layer script is worse than
#    giving you a documented recipe to run yourself once you have live
#    network access and can watch it for errors.
# ---------------------------------------------------------------------------
if id icarus &>/dev/null; then
    mkdir -p /home/icarus/bin
    cat > /home/icarus/bin/build-llamacpp-openvino.sh << 'EOF'
#!/usr/bin/env bash
# Run this yourself, interactively, with network access. Not auto-run by
# the installer — see 06-ai-engineering-perf.sh for why.
set -euo pipefail
cd "$HOME"
[[ -d llama.cpp ]] || git clone https://github.com/ggml-org/llama.cpp.git
cd llama.cpp
git pull
source "$HOME/.venvs/ai/bin/activate"
cmake -B build -DGGML_OPENVINO=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release -j"$(nproc)"
echo "Built. Binaries are under llama.cpp/build/bin/"
echo "Check the current llama.cpp README for the exact OpenVINO CMake flag"
echo "name — it's new enough that it may have changed since this was written."
EOF
    chmod +x /home/icarus/bin/build-llamacpp-openvino.sh
    chown -R icarus:icarus /home/icarus/bin
    log "llama.cpp+OpenVINO build recipe written to /home/icarus/bin/build-llamacpp-openvino.sh — run it yourself when ready."
fi

# ---------------------------------------------------------------------------
# 4. sched_ext — pluggable CPU scheduler. Genuinely load-bearing for mixed
#    compile+inference+desktop workloads; requires CONFIG_SCHED_CLASS_EXT
#    in the kernel (added to pkgs/linux-icarus/PKGBUILD alongside this).
#    scx_bpfland is the default here: cache-aware, good general desktop
#    behavior. Switch it anytime via /etc/default/scx — no rebuild needed.
# ---------------------------------------------------------------------------
log "Installing sched_ext schedulers (scx-scheds)..."
if try_install scx-scheds; then
    mkdir -p /etc/default
    cat > /etc/default/scx << 'EOF'
SCX_SCHEDULER=scx_bpfland
SCX_FLAGS=
EOF
    systemctl enable scx.service
    log "scx.service enabled with scx_bpfland as default. Switch schedulers anytime:"
    log "  systemctl set-environment SCX_SCHEDULER_OVERRIDE=scx_lavd && systemctl restart scx.service"
    log "If it fails to load with a BPF permission error, check 'zcat /proc/config.gz | grep SCHED_CLASS_EXT' first — that's the kernel config this depends on."
fi

# ---------------------------------------------------------------------------
# 5. The actual 8GB bottleneck: memory pressure, not raw CPU/GPU speed.
#    earlyoom kills the right thing before a hard freeze; swappiness is
#    tuned high because zram (already configured in Layer 3b) is fast
#    compressed RAM, not slow disk — the usual low-swappiness advice
#    assumes disk-backed swap and doesn't apply here.
# ---------------------------------------------------------------------------
log "Installing earlyoom and tuning swappiness for zram..."
if try_install earlyoom; then
    systemctl enable earlyoom.service
fi
cat > /etc/sysctl.d/99-icarus-memory.conf << 'EOF'
# High swappiness is correct here specifically because swap is zram
# (fast, compressed RAM), not disk. Reclaiming file cache before
# swapping to zram is the wrong tradeoff on this hardware.
vm.swappiness=150
EOF
sysctl -p /etc/sysctl.d/99-icarus-memory.conf 2>/dev/null || true

# ---------------------------------------------------------------------------
# 6. Thermal management — the CPU and iGPU share one thermal budget.
#    Bad thermal handling throttles both under sustained AI/compile load,
#    which will look like "the hardware just isn't fast enough" when it's
#    actually a missing/misconfigured thermald.
# ---------------------------------------------------------------------------
log "Installing thermald..."
if try_install thermald; then
    systemctl enable thermald.service
fi

# ---------------------------------------------------------------------------
# 7. Dev-workflow plumbing.
# ---------------------------------------------------------------------------
log "Installing dev tooling (ccache, podman, QEMU/KVM)..."
try_install ccache
try_install podman
try_install qemu-desktop libvirt virt-manager dnsmasq
if pacman -Qi libvirt &>/dev/null; then
    systemctl enable libvirtd.service
    id icarus &>/dev/null && usermod -aG libvirt icarus
fi

log "Raising inotify watch limits and file descriptor ulimits for large codebases..."
cat > /etc/sysctl.d/99-icarus-devtools.conf << 'EOF'
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=512
EOF
sysctl -p /etc/sysctl.d/99-icarus-devtools.conf 2>/dev/null || true

mkdir -p /etc/security/limits.d
cat > /etc/security/limits.d/99-icarus-devtools.conf << 'EOF'
icarus soft nofile 1048576
icarus hard nofile 1048576
EOF

# ---------------------------------------------------------------------------
# 8. I/O scheduler for the USB flash boot medium. Matched by USB bus
#    rather than a hardcoded device name, since /dev/sdX can shift.
# ---------------------------------------------------------------------------
log "Setting I/O scheduler for USB storage..."
cat > /etc/udev/rules.d/60-icarus-io-scheduler.rules << 'EOF'
ACTION=="add|change", SUBSYSTEMS=="usb", KERNEL=="sd[a-z]", ATTR{queue/scheduler}="mq-deadline"
EOF

# ---------------------------------------------------------------------------
# 9. One-command profile switch, tying power-profiles-daemon (Layer 5)
#    and the scx scheduler together instead of juggling both by hand.
# ---------------------------------------------------------------------------
cat > /usr/local/bin/icarus-perf << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
    compute)
        powerprofilesctl set performance
        systemctl set-environment SCX_SCHEDULER_OVERRIDE=scx_rusty
        systemctl restart scx.service
        echo "Profile: compute (performance power + scx_rusty for throughput/load-balancing)"
        ;;
    desktop)
        powerprofilesctl set balanced
        systemctl set-environment SCX_SCHEDULER_OVERRIDE=scx_bpfland
        systemctl restart scx.service
        echo "Profile: desktop (balanced power + scx_bpfland for interactivity)"
        ;;
    battery)
        powerprofilesctl set power-saver
        systemctl set-environment SCX_SCHEDULER_OVERRIDE=scx_lavd
        systemctl restart scx.service
        echo "Profile: battery (power-saver + scx_lavd core compaction)"
        ;;
    *)
        echo "Usage: icarus-perf {compute|desktop|battery}"
        exit 1
        ;;
esac
EOF
chmod +x /usr/local/bin/icarus-perf
log "Installed 'icarus-perf {compute|desktop|battery}' for one-command profile switching."

mkdir -p "$ICARUS_LOG_DIR"
touch "$SENTINEL"
log "Layer 6 complete. Sentinel written: ${SENTINEL}"
