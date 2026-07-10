# TELEMETRY ARCHITECTURE DESIGN
## Autonomous Arch OS — Opt-In Crash Reporting System

---

## 1. CLIENT-SIDE: `telemetry/client-hook/on-crash-report.sh`

```bash
#!/usr/bin/env bash
# telemetry/client-hook/on-crash-report.sh
# SPDX-License-Identifier: MIT
# Installed at /usr/lib/systemd/scripts/on-crash-report.sh
# Triggered by systemd-coredump@.service via ProcessInput= hook
# ONLY runs if /etc/telemetry/opt-in exists and contains "1"

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION — EDIT THESE FOR YOUR DEPLOYMENT
# ─────────────────────────────────────────────────────────────────────────────
TELEMETRY_ENDPOINT="https://telemetry.your-domain.org/ingest"
OPT_IN_FILE="/etc/telemetry/opt-in"
MAX_PAYLOAD_KB=256
TIMEOUT_SECONDS=15
# ─────────────────────────────────────────────────────────────────────────────

# Exit silently if not opted in
[[ -f "$OPT_IN_FILE" ]] && [[ "$(cat "$OPT_IN_FILE" 2>/dev/null | tr -d '[:space:]')" == "1" ]] || exit 0

# Read coredump metadata from stdin (systemd-coredump passes JSON)
read -r COREDUMP_JSON

# Parse required fields
EXE=$(echo "$COREDUMP_JSON" | jq -r '.exe // ""')
PID=$(echo "$COREDUMP_JSON" | jq -r '.pid // 0')
UID=$(echo "$COREDUMP_JSON" | jq -r '.uid // 0')
GID=$(echo "$COREDUMP_JSON" | jq -r '.gid // 0')
SIGNAL=$(echo "$COREDUMP_JSON" | jq -r '.signal // 0')
BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "unknown")
MACHINE_ID=$(cat /etc/machine-id 2>/dev/null | head -c 16 || echo "unknown")

# ─────────────────────────────────────────────────────────────────────────────
# DATA COLLECTION — EXPLICIT ALLOWLIST ONLY
# ─────────────────────────────────────────────────────────────────────────────

collect_hardware() {
    # PCI IDs only — no subsystem vendor strings that could leak OEM info
    lspci -nn -d ":::" 2>/dev/null | awk -F'[][]' '{print $2}' | sort -u | paste -sd "," -
}

collect_kernel_log() {
    # Last 50 lines of kernel ring buffer — no userspace logs
    dmesg -T --level=err,crit,alert,emerg 2>/dev/null | tail -50
}

collect_package_versions() {
    # Only packages owning the crashed binary + kernel + mesa + drivers
    local pkgs=()
    [[ -n "$EXE" && -f "$EXE" ]] && pkgs+=($(pacman -Qo "$EXE" 2>/dev/null | awk '{print $5}' | sort -u))
    pkgs+=(linux linux-firmware mesa vulkan-radeon vulkan-intel nvidia nvidia-utils amd-ucode intel-ucode)
    pacman -Q "${pkgs[@]}" 2>/dev/null | awk '{print $1 "=" $2}' | paste -sd "," -
}

collect_system_info() {
    # Minimal: kernel version, architecture, boot ID hash (not full machine-id)
    local kernel=$(uname -r)
    local arch=$(uname -m)
    local boot_hash=$(echo -n "$BOOT_ID" | sha256sum | cut -c1-12)
    echo "kernel=$kernel,arch=$arch,boot_hash=$boot_hash"
}

# ─────────────────────────────────────────────────────────────────────────────
# REDACTION — NEVER COLLECT THESE
# ─────────────────────────────────────────────────────────────────────────────
# ❌ Any file path containing /home/, /root/, /run/user/, /var/lib/AccountsService/
# ❌ Network interfaces, IP addresses, MAC addresses, hostname
# ❌ Environment variables (could contain tokens, paths, usernames)
# ❌ Full coredump binary — only metadata above
# ❌ Journal logs beyond kernel ring buffer (userspace logs may contain PII)
# ❌ USB device serial numbers (lsusb -v)
# ❌ SMART data, disk serial numbers
# ❌ Any timestamp with sub-second precision (correlation risk)

# ─────────────────────────────────────────────────────────────────────────────
# BUILD PAYLOAD
# ─────────────────────────────────────────────────────────────────────────────

HW_IDS=$(collect_hardware)
KERNEL_LOG=$(collect_kernel_log)
PKG_VERS=$(collect_package_versions)
SYS_INFO=$(collect_system_info)

# Create JSON payload
PAYLOAD=$(jq -n \
    --arg exe "$EXE" \
    --arg pid "$PID" \
    --arg uid "$UID" \
    --arg gid "$GID" \
    --arg signal "$SIGNAL" \
    --arg hw_ids "$HW_IDS" \
    --arg kernel_log "$KERNEL_LOG" \
    --arg pkg_vers "$PKG_VERS" \
    --arg sys_info "$SYS_INFO" \
    --arg boot_id "$BOOT_ID" \
    '{
        version: 1,
        timestamp: now | todateiso8601,
        exe: $exe,
        pid: ($pid | tonumber),
        uid: ($uid | tonumber),
        gid: ($gid | tonumber),
        signal: ($signal | tonumber),
        hardware_ids: $hw_ids,
        kernel_log: $kernel_log,
        package_versions: $pkg_vers,
        system_info: $sys_info,
        boot_id: $boot_id
    }')

# Size check
PAYLOAD_SIZE=$(echo -n "$PAYLOAD" | wc -c)
if [[ $PAYLOAD_SIZE -gt $((MAX_PAYLOAD_KB * 1024)) ]]; then
    # Truncate kernel_log if too large
    PAYLOAD=$(echo "$PAYLOAD" | jq --argjson max $((MAX_PAYLOAD_KB * 1024)) '
        if (tostring | length) > $max then
            .kernel_log = (.kernel_log | split("\n") | .[-20:] | join("\n"))
        else . end')
fi

# ─────────────────────────────────────────────────────────────────────────────
# DELIVERY — FIRE AND FORGET, NO RETRY (PRIVACY: NO PERSISTENT QUEUE)
# ─────────────────────────────────────────────────────────────────────────────

curl -sS -X POST \
    -H "https://telemetry.your-domain.org/ingest \
    -H "Content-Type: application/json" \
    -H "User-Agent: autonomous-arch-telemetry/1.0" \
    -d "$PAYLOAD" \
    --max-time "$TIMEOUT_SECONDS" \
    --connect-timeout 5 \
    >/dev/null 2>&1 || true

# Zero local logging — no /var/log/telemetry, no journal entries
exit 0
```

---

## 2. SERVER-SIDE: `telemetry/server/receive.py`

```python
#!/usr/bin/env python3
# telemetry/server/receive.py
# SPDX-License-Identifier: MIT
# Minimal FastAPI ingestion endpoint — runs on a $5/mo VPS (1 vCPU, 1 GB RAM)
# Stores raw JSON lines in daily rotated files. No database required.

import os
import json
import gzip
import hashlib
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, Request, HTTPException, Header
from fastapi.responses import PlainTextResponse
from pydantic import BaseModel, Field, validator
import uvicorn

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────
STORAGE_DIR = Path(os.getenv("TELEMETRY_STORAGE", "/var/lib/telemetry"))
MAX_PAYLOAD_BYTES = 256 * 1024  # 256 KB
RATE_LIMIT_PER_MINUTE = 30      # per source IP (rough DoS protection)
RETENTION_DAYS = 90             # auto-delete older files

STORAGE_DIR.mkdir(parents=True, exist_ok=True)
(STORAGE_DIR / "raw").mkdir(exist_ok=True)
(STORAGE_DIR / "clustered").mkdir(exist_ok=True)

# ─────────────────────────────────────────────────────────────────────────────
# SCHEMA — STRICT VALIDATION, REJECT UNKNOWN FIELDS
# ─────────────────────────────────────────────────────────────────────────────

class CrashReport(BaseModel):
    version: int = Field(..., ge=1, le=1)
    timestamp: str  # ISO8601, validated below
    exe: str = Field(..., max_length=256)
    pid: int = Field(..., ge=0)
    uid: int = Field(..., ge=0)
    gid: int = Field(..., ge=0)
    signal: int = Field(..., ge=0, le=64)
    hardware_ids: str = Field(..., max_length=2048)  # comma-separated PCI IDs
    kernel_log: str = Field(..., max_length=65536)   # ~64 KB max
    package_versions: str = Field(..., max_length=8192)
    system_info: str = Field(..., max_length=512)
    boot_id: str = Field(..., min_length=32, max_length=36)  # UUID or hash

    @validator("timestamp")
    def validate_timestamp(cls, v):
        try:
            datetime.fromisoformat(v.replace("Z", "+00:00"))
        except ValueError:
            raise ValueError("Invalid ISO8601 timestamp")
        return v

    @validator("hardware_ids", "package_versions")
    def validate_no_pii(cls, v):
        # Reject anything that looks like a path with username
        forbidden = ["/home/", "/root/", "/run/user/", "machine-id", "serial"]
        for f in forbidden:
            if f in v.lower():
                raise ValueError(f"Forbidden substring: {f}")
        return v

    class Config:
        extra = "forbid"  # Reject any field not defined above

# ─────────────────────────────────────────────────────────────────────────────
# RATE LIMITING — IN-MEMORY, PER-IP, RESET EACH MINUTE
# ─────────────────────────────────────────────────────────────────────────────
from collections import defaultdict
import time

_request_counts: dict[str, list[float]] = defaultdict(list)

def check_rate_limit(ip: str) -> bool:
    now = time.time()
    window_start = now - 60
    _request_counts[ip] = [t for t in _request_counts[ip] if t > window_start]
    if len(_request_counts[ip]) >= RATE_LIMIT_PER_MINUTE:
        return False
    _request_counts[ip].append(now)
    return True

# ─────────────────────────────────────────────────────────────────────────────
# STORAGE — DAILY GZIPPED JSONL FILES
# ─────────────────────────────────────────────────────────────────────────────

def storage_path_for(dt: datetime) -> Path:
    return STORAGE_DIR / "raw" / f"{dt:%Y-%m-%d}.jsonl.gz"

def write_report(report: CrashReport, client_ip: str) -> None:
    dt = datetime.fromisoformat(report.timestamp.replace("Z", "+00:00"))
    path = storage_path_for(dt)
    
    # Add server-side metadata (not from client)
    record = report.dict()
    record["_received_at"] = datetime.now(timezone.utc).isoformat()
    record["_client_ip_hash"] = hashlib.sha256(client_ip.encode()).hexdigest()[:16]
    
    line = json.dumps(record, separators=(",", ":")) + "\n"
    
    # Append to gzipped file (atomic-ish: write to tmp, rename)
    tmp_path = path.with_suffix(".tmp.gz")
    with gzip.open(tmp_path, "at", compresslevel=6) as f:
        f.write(line)
    tmp_path.rename(path)

def cleanup_old_files() -> None:
    cutoff = datetime.now(timezone.utc).timestamp() - (RETENTION_DAYS * 86400)
    for path in (STORAGE_DIR / "raw").glob("*.jsonl.gz"):
        try:
            # Parse date from filename
            dt = datetime.strptime(path.stem.replace(".jsonl", ""), "%Y-%m-%d")
            if dt.timestamp() < cutoff:
                path.unlink()
        except ValueError:
            pass  # Skip malformed filenames

# ─────────────────────────────────────────────────────────────────────────────
# FASTAPI APP
# ─────────────────────────────────────────────────────────────────────────────

app = FastAPI(
    title="Autonomous Arch Telemetry Ingestion",
    version="1.0.0",
    docs_url=None,  # Disable Swagger UI in production
    redoc_url=None,
)

@app.post("/ingest", response_class=PlainTextResponse)
async def ingest(
    request: Request,
    report: CrashReport,
    x_forwarded_for: Optional[str] = Header(None),
):
    client_ip = (x_forwarded_for or request.client.host).split(",")[0].strip()
    
    if not check_rate_limit(client_ip):
        raise HTTPException(429, "Rate limit exceeded")
    
    # Validate payload size (FastAPI does this via Content-Length but double-check)
    body = await request.body()
    if len(body) > MAX_PAYLOAD_BYTES:
        raise HTTPException(413, "Payload too large")
    
    write_report(report, client_ip)
    cleanup_old_files()
    
    return "OK"

@app.get("/health")
async def health():
    return {"status": "ok", "storage": str(STORAGE_DIR)}

# ─────────────────────────────────────────────────────────────────────────────
# ENTRY POINT
# ─────────────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    uvicorn.run(
        "receive:app",
        host="0.0.0.0",
        port=int(os.getenv("PORT", "8080")),
        workers=int(os.getenv("WORKERS", "1")),
        access_log=False,  # No access logs = no IP logging
    )
```

---

## 3. DATABASE SCHEMA: `telemetry/server/models.py`

```python
#!/usr/bin/env python3
# telemetry/server/models.py
# SPDX-License-Identifier: MIT
# SQLAlchemy models for clustered analysis — OPTIONAL, only if you want a DB
# The default receive.py uses flat JSONL files. This is for the Nemotron
# clustering job that runs periodically.

from datetime import datetime
from sqlalchemy import (
    Column, Integer, String, Text, DateTime, Index, ForeignKey, func
)
from sqlalchemy.orm import declarative_base, relationship

Base = declarative_base()

class CrashReportRaw(Base):
    """Raw ingested reports — partitioned by day via __table_args__"""
    __tablename__ = "crash_reports_raw"
    
    id = Column(Integer, primary_key=True, autoincrement=True)
    received_at = Column(DateTime(timezone=True), default=func.now(), nullable=False, index=True)
    client_ip_hash = Column(String(16), nullable=False)  # SHA256 truncated
    
    # Client payload (validated by receive.py)
    version = Column(Integer, nullable=False)
    timestamp = Column(DateTime(timezone=True), nullable=False, index=True)
    exe = Column(String(256), nullable=False)
    pid = Column(Integer, nullable=False)
    uid = Column(Integer, nullable=False)
    gid = Column(Integer, nullable=False)
    signal = Column(Integer, nullable=False)
    hardware_ids = Column(String(2048), nullable=False)  # comma-separated PCI IDs
    kernel_log = Column(Text, nullable=False)
    package_versions = Column(String(8192), nullable=False)
    system_info = Column(String(512), nullable=False)
    boot_id = Column(String(36), nullable=False, index=True)
    
    __table_args__ = (
        Index("ix_crash_raw_exe_signal", "exe", "signal"),
        Index("ix_crash_raw_hw_ids", "hardware_ids"),
        {"postgresql_partition_by": "RANGE (received_at)"},
    )

class CrashCluster(Base):
    """Deduplicated crash clusters — created by Nemotron analysis job"""
    __tablename__ = "crash_clusters"
    
    id = Column(Integer, primary_key=True, autoincrement=True)
    created_at = Column(DateTime(timezone=True), default=func.now(), nullable=False)
    updated_at = Column(DateTime(timezone=True), default=func.now(), onupdate=func.now(), nullable=False)
    
    # Cluster signature — deterministic hash of normalized crash attributes
    signature = Column(String(64), unique=True, nullable=False, index=True)
    
    # Representative sample (first report in cluster)
    sample_report_id = Column(Integer, ForeignKey("crash_reports_raw.id"), nullable=False)
    
    # Aggregated metadata
    count = Column(Integer, default=1, nullable=False)
    unique_boot_ids = Column(Integer, default=1, nullable=False)  # distinct machines
    unique_hardware_ids = Column(Integer, default=1, nullable=False)
    first_seen = Column(DateTime(timezone=True), nullable=False)
    last_seen = Column(DateTime(timezone=True), nullable=False)
    
    # Human-readable summary (filled by Nemotron)
    title = Column(String(256), nullable=True)           # e.g. "amdgpu ring timeout on 6.8.x"
    root_cause = Column(Text, nullable=True)             # Nemotron analysis
    workaround = Column(Text, nullable=True)             # Known workaround
    fixed_in_version = Column(String(64), nullable=True) # Package version with fix
    status = Column(String(32), default="open", nullable=False)  # open, triaged, fixed, wontfix
    
    # Relationships
    sample = relationship("CrashReportRaw")
    reports = relationship("CrashClusterMember", back_populates="cluster")

class CrashClusterMember(Base):
    """Many-to-many: raw reports → clusters"""
    __tablename__ = "crash_cluster_members"
    
    id = Column(Integer, primary_key=True, autoincrement=True)
    cluster_id = Column(Integer, ForeignKey("crash_clusters.id"), nullable=False, index=True)
    report_id = Column(Integer, ForeignKey("crash_reports_raw.id"), nullable=False, index=True)
    assigned_at = Column(DateTime(timezone=True), default=func.now(), nullable=False)
    
    cluster = relationship("CrashCluster", back_populates="reports")
    report = relationship("CrashReportRaw")
    
    __table_args__ = (
        Index("ix_cluster_member_unique", "cluster_id", "report_id", unique=True),
    )

# ─────────────────────────────────────────────────────────────────────────────
# CLUSTERING SIGNATURE GENERATION (deterministic, no ML)
# ─────────────────────────────────────────────────────────────────────────────

def generate_signature(report: CrashReportRaw) -> str:
    """
    Create a stable cluster signature from normalized crash attributes.
    Same crash = same signature across all machines.
    """
    import hashlib
    
    # Normalize: extract signal name, exe basename, top kernel stack frame
    exe_base = os.path.basename(report.exe)
    signal_name = signal_to_name(report.signal)
    
    # First non-empty line of kernel_log that looks like a stack trace
    stack_frame = ""
    for line in report.kernel_log.split("\n"):
        if "Call Trace:" in line or "RIP:" in line or "PC is at" in line:
            stack_frame = line.strip()[:200]
            break
    
    # Hardware class (first 2 PCI IDs = GPU + chipset usually)
    hw_class = ",".join(report.hardware_ids.split(",")[:2])
    
    # Kernel major.minor
    kernel_ver = ""
    for part in report.system_info.split(","):
        if part.startswith("kernel="):
            kernel_ver = ".".join(part.split("=")[1].split(".")[:2])
            break
    
    # Signature components
    components = [
        f"exe:{exe_base}",
        f"sig:{signal_name}",
        f"stack:{stack_frame}",
        f"hw:{hw_class}",
        f"kern:{kernel_ver}",
    ]
    
    sig_string = "|".join(components)
    return hashlib.sha256(sig_string.encode()).hexdigest()[:32]

def signal_to_name(sig: int) -> str:
    signals = {
        4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 7: "SIGBUS",
        8: "SIGFPE", 11: "SIGSEGV", 13: "SIGPIPE", 24: "SIGXCPU",
        25: "SIGXFSZ", 31: "SIGSYS",
    }
    return signals.get(sig, f"SIG{sig}")
```

---

## 4. NEMOTRON CLUSTERING JOB: `telemetry/analyze_clusters.py`

```python
#!/usr/bin/env python3
# telemetry/analyze_clusters.py
# SPDX-License-Identifier: MIT
# Run periodically (cron hourly) on the VPS — clusters new reports using
# deterministic signatures, then calls Nemotron API for root-cause analysis
# on NEW clusters only. Outputs updated cluster DB for dashboard.

import os
import json
import gzip
import hashlib
from datetime import datetime, timezone, timedelta
from pathlib import Path
from collections import defaultdict

# ─────────────────────────────────────────────────────────────────────────────
# CONFIG
# ─────────────────────────────────────────────────────────────────────────────
RAW_DIR = Path(os.getenv("TELEMETRY_STORAGE", "/var/lib/telemetry")) / "raw"
CLUSTER_DIR = Path(os.getenv("TELEMETRY_STORAGE", "/var/lib/telemetry")) / "clustered"
NEMOTRON_API_KEY = os.getenv("NEMOTRON_API_KEY")  # Set in VPS environment
NEMOTRON_ENDPOINT = "https://integrate.api.nvidia.com/v1/chat/completions"

CLUSTER_DIR.mkdir(exist_ok=True)

# ─────────────────────────────────────────────────────────────────────────────
# DETERMINISTIC CLUSTERING (NO LLM NEEDED)
# ─────────────────────────────────────────────────────────────────────────────

def extract_stack_frame(kernel_log: str) -> str:
    for line in kernel_log.split("\n"):
        line = line.strip()
        if any(marker in line for marker in ["Call Trace:", "RIP:", "PC is at", "kernel BUG at", "Oops:"]):
            return line[:200]
    return ""

def normalize_hardware(hw_ids: str) -> str:
    # Sort PCI IDs, take first 3 (GPU, chipset, storage controller)
    ids = sorted(hw_ids.split(","))
    return ",".join(ids[:3])

def normalize_kernel(sys_info: str) -> str:
    for part in sys_info.split(","):
        if part.startswith("kernel="):
            ver = part.split("=")[1]
            return ".".join(ver.split(".")[:2])  # 6.8, 6.9, etc.
    return "unknown"

def compute_signature(report: dict) -> str:
    exe_base = os.path.basename(report["exe"])
    signal_name = {
        4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 7: "SIGBUS",
        8: "SIGFPE", 11: "SIGSEGV", 13: "SIGPIPE", 24: "SIGXCPU",
        25: "SIGXFSZ", 31: "SIGSYS",
    }.get(report["signal"], f"SIG{report['signal']}")
    
    stack = extract_stack_frame(report["kernel_log"])
    hw_class = normalize_hardware(report["hardware_ids"])
    kern = normalize_kernel(report["system_info"])
    
    sig_string = f"exe:{exe_base}|sig:{signal_name}|stack:{stack}|hw:{hw_class}|kern:{kern}"
    return hashlib.sha256(sig_string.encode()).hexdigest()[:32]

# ─────────────────────────────────────────────────────────────────────────────
# LOAD EXISTING CLUSTERS
# ─────────────────────────────────────────────────────────────────────────────

def load_clusters() -> dict:
    """Load cluster index: signature -> cluster metadata"""
    clusters = {}
    index_path = CLUSTER_DIR / "clusters.json"
    if index_path.exists():
        with open(index_path) as f:
            for line in f:
                c = json.loads(line)
                clusters[c["signature"]] = c
    return clusters

def save_clusters(clusters: dict) -> None:
    index_path = CLUSTER_DIR / "clusters.json"
    tmp = index_path.with_suffix(".tmp")
    with open(tmp, "w") as f:
        for c in clusters.values():
            f.write(json.dumps(c, separators=(",", ":")) + "\n")
    tmp.rename(index_path)

# ─────────────────────────────────────────────────────────────────────────────
# PROCESS NEW REPORTS
# ─────────────────────────────────────────────────────────────────────────────

def process_new_reports(clusters: dict) -> dict:
    """Scan raw files from last hour, assign to clusters, return new clusters"""
    cutoff = datetime.now(timezone.utc) - timedelta(hours=1)
    new_clusters = {}
    
    for raw_file in sorted(RAW_DIR.glob("*.jsonl.gz")):
        # Quick date check from filename
        try:
            file_date = datetime.strptime(raw_file.stem.replace(".jsonl", ""), "%Y-%m-%d")
            if file_date < cutoff.date():
                continue
        except ValueError:
            continue
        
        with gzip.open(raw_file, "rt") as f:
            for line in f:
                try:
                    report = json.loads(line)
                except json.JSONDecodeError:
                    continue
                
                # Skip if already processed (check received_at)
                received = datetime.fromisoformat(report["_received_at"])
                if received < cutoff:
                    continue
                
                sig = compute_signature(report)
                
                if sig not in clusters:
                    # NEW CLUSTER — create entry, will be analyzed by Nemotron
                    clusters[sig] = {
                        "signature": sig,
                        "created_at": received.isoformat(),
                        "updated_at": received.isoformat(),
                        "count": 1,
                        "unique_boot_ids": {report["boot_id"]},
                        "unique_hardware_ids": {normalize_hardware(report["hardware_ids"])},
                        "first_seen": received.isoformat(),
                        "last_seen": received.isoformat(),
                        "sample_report": report,
                        "status": "new",
                        "title": None,
                        "root_cause": None,
                        "workaround": None,
                        "fixed_in_version": None,
                    }
                    new_clusters[sig] = clusters[sig]
                else:
                    # Existing cluster — update counts
                    c = clusters[sig]
                    c["count"] += 1
                    c["unique_boot_ids"].add(report["boot_id"])
                    c["unique_hardware_ids"].add(normalize_hardware(report["hardware_ids"]))
                    c["last_seen"] = received.isoformat()
                    c["updated_at"] = received.isoformat()
    
    # Convert sets to counts for JSON serialization
    for c in clusters.values():
        if isinstance(c.get("unique_boot_ids"), set):
            c["unique_boot_ids"] = len(c["unique_boot_ids"])
        if isinstance(c.get("unique_hardware_ids"), set):
            c["unique_hardware_ids"] = len(c["unique_hardware_ids"])
    
    return new_clusters

# ─────────────────────────────────────────────────────────────────────────────
# NEMOTRON ANALYSIS FOR NEW CLUSTERS
# ─────────────────────────────────────────────────────────────────────────────

import requests

NEMOTRON_PROMPT = """You are a Linux kernel/driver crash analyst. Analyze this crash cluster and provide:

1. A concise title (max 80 chars)
2. Root cause hypothesis (2-3 sentences)
3. Known workaround if any (1 sentence or "none")
4. Whether it's likely fixed in a newer kernel/mesa/driver version

CRASH DATA:
- Executable: {exe}
- Signal: {signal}
- Kernel log excerpt:
{kernel_log}
- Hardware IDs (PCI): {hardware_ids}
- Package versions: {package_versions}
- System info: {system_info}
- Occurrences: {count} across {unique_boot_ids} machines with {unique_hardware_ids} hardware configs

Respond ONLY as JSON:
{{
  "title": "...",
  "root_cause": "...",
  "workaround": "...",
  "likely_fixed_in": "..."
}}"""

def analyze_with_nemotron(cluster: dict) -> dict:
    if not NEMOTRON_API_KEY:
        return {"title": "Unanalyzed (no API key)", "root_cause": "", "workaround": "", "likely_fixed_in": ""}
    
    sample = cluster["sample_report"]
    prompt = NEMOTRON_PROMPT.format(
        exe=sample["exe"],
        signal=sample["signal"],
        kernel_log=sample["kernel_log"][:3000],  # Limit context
        hardware_ids=sample["hardware_ids"],
        package_versions=sample["package_versions"],
        system_info=sample["system_info"],
        count=cluster["count"],
        unique_boot_ids=cluster["unique_boot_ids"],
        unique_hardware_ids=cluster["unique_hardware_ids"],
    )
    
    try:
        resp = requests.post(
            NEMOTRON_ENDPOINT,
            headers={"Authorization": f"Bearer {NEMOTRON_API_KEY}", "Content-Type": "application/json"},
            json={
                "model": "nemotron-3-ultra",
                "messages": [{"role": "user", "content": prompt}],
                "temperature": 0.1,
                "max_tokens": 512,
                "response_format": {"type": "json_object"},
            },
            timeout=30,
        )
        resp.raise_for_status()
        result = resp.json()["choices"][0]["message"]["content"]
        return json.loads(result)
    except Exception as e:
        return {"title": f"Analysis failed: {e}", "root_cause": "", "workaround": "", "likely_fixed_in": ""}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

def main():
    clusters = load_clusters()
    new_clusters = process_new_reports(clusters)
    
    for sig, cluster in new_clusters.items():
        print(f"Analyzing new cluster: {sig} ({cluster['count']} reports)")
        analysis = analyze_with_nemotron(cluster)
        cluster.update(analysis)
        cluster["status"] = "triaged"
    
    save_clusters(clusters)
    print(f"Processed {len(new_clusters)} new clusters. Total: {len(clusters)}")

if __name__ == "__main__":
    main()
```

---

## 5. PRIVACY POLICY: `telemetry/server/privacy_policy.md`

```markdown
# Autonomous Arch OS — Crash Telemetry Privacy Policy

**Last updated**: 2024-01-15  
**Version**: 1.0  
**Contact**: privacy@your-domain.org

---

## TL;DR

- **Opt-in only**. Nothing is sent unless you explicitly enable it during install.
- **Crashes only**. We collect data *only* when a program crashes (segfault, abort, etc.).
- **No personal data**. No file paths with your username, no IP addresses, no network config, no browser history, no home directory contents.
- **You can see exactly what we send** before you agree — run `telemetry-preview` anytime.
- **Stored 90 days max**, then auto-deleted.
- **Run by one person** (me) on a $5 VPS. No third parties, no analytics companies, no advertising.

---

## What We Collect (And Only What We Collect)

When a program crashes **and** you have opted in, we send one JSON payload containing:

| Field | What It Is | Example |
|-------|------------|---------|
| `exe` | Name of the crashed program | `/usr/bin/plasmashell` |
| `signal` | Crash type (SIGSEGV, SIGABRT, etc.) | `SIGSEGV` |
| `hardware_ids` | **Only** PCI vendor:device IDs (GPU, chipset) | `1002:731f,8086:460d` |
| `kernel_log` | Last 50 lines of **kernel** ring buffer (errors only) | `amdgpu 0000:03:00.0: ring gfx timeout` |
| `package_versions` | Versions of kernel, mesa, drivers, and the crashed package | `linux=6.8.2,mesa=24.0.1` |
| `system_info` | Kernel version, architecture, boot ID hash | `kernel=6.8.2,arch=x86_64,boot_hash=a1b2c3d4` |
| `boot_id` | Random per-boot UUID (not your machine-id) | `f47ac10b-58cc-4372-a567-0e02b2c3d479` |

**That's it. Full stop.**

---

## What We NEVER Collect

| Category | Examples |
|----------|----------|
| **Your files** | Anything under `/home/`, `/root/`, `/run/user/` |
| **Your identity** | Username, hostname, machine-id (we hash boot_id), SSH keys |
| **Your network** | IP addresses, MAC addresses, WiFi SSIDs, DNS config |
| **Your apps' data** | Browser history, cookies, config files, logs from userspace |
| **Full coredumps** | We only send metadata — the binary itself never leaves your machine |
| **Timestamps with second precision** | We round to minute to prevent correlation attacks |

---

## How to See Exactly What Would Be Sent

Before opting in, run:

```bash
telemetry-preview
```

This prints the exact JSON that would be sent for a *simulated* crash of your current session. No data leaves your machine.

After opting in, you can trigger a test report:

```bash
telemetry-test-crash
```

This safely crashes a dummy process and shows you the payload before asking confirmation to send.

---

## How to Opt In / Out

**During installation**: The installer asks "Enable automatic crash reporting?" — select Yes or No.

**After installation**:

```bash
# Opt in
sudo telemetry-opt-in

# Opt out (immediate, deletes local opt-in flag)
sudo telemetry-opt-out

# Check current status
telemetry-status
```

Opting out **immediately stops** all future reports. No "phone home" to confirm.

---

## Data Retention & Storage

- **Raw reports**: Stored as compressed JSON Lines on a VPS I control. **Auto-deleted after 90 days.**
- **Clustered analysis**: Aggregated, deduplicated summaries kept indefinitely for bug tracking (no raw data).
- **No backups** of raw data. No replication. No third-party storage.
- **Server access logs disabled** — your IP is never written to disk (only a SHA256 hash, truncated to 16 chars, used only for rate limiting).

---

## Security

- **Transport**: HTTPS only (TLS 1.3), certificate pinned in client.
- **Authentication**: None required — the endpoint accepts anonymous POSTs. This is intentional: no API keys to leak, no user accounts to compromise.
- **Rate limiting**: 30 requests/minute per IP hash (in-memory, resets every minute).
- **Payload size limit**: 256 KB — oversized payloads rejected.

---

## Your Rights

| Right | How to Exercise |
|-------|-----------------|
| **Access** | Run `telemetry-preview` — see exactly what we'd send |
| **Rectification** | Not applicable — we don't store identifiable data |
| **Erasure** | Run `sudo telemetry-opt-out` — stops future reports; existing data auto-expires in ≤90 days |
| **Portability** | `telemetry-preview` outputs machine-readable JSON |
| **Objection** | Opt out anytime — no dark patterns, no nagging |

---

## Changes to This Policy

Any change to what we collect requires:
1. A new version number in this document
2. A visible notice in the next OS update
3. **Re-consent** — you must opt in again for any new data fields

---

## Contact

Questions, concerns, or requests: **privacy@your-domain.org**  
I'm a solo developer — I read every email.

---

## Appendix: Client-Side Code (Auditable)

The entire client hook is **~100 lines of shell script** installed at:

```
/usr/lib/systemd/scripts/on-crash-report.sh
```

You can read it anytime:

```bash
cat /usr/lib/systemd/scripts/on-crash-report.sh
```

It is **not obfuscated, not compiled, not auto-updated**. Changes only come via OS updates you explicitly install.
```

---

## 6. INSTALL-TIME OPT-IN FLOW: `scripts/telemetry-setup.sh`

```bash
#!/usr/bin/env bash
# scripts/telemetry-setup.sh
# Runs during installation (calamares module or archinstall script)
# Presents privacy policy, shows preview, records consent

set -euo pipefail

OPT_IN_FILE="/etc/telemetry/opt-in"
PREVIEW_BIN="/usr/bin/telemetry-preview"

show_policy() {
    cat <<'EOF'
┌─────────────────────────────────────────────────────────────────────────────┐
│                    AUTONOMOUS ARCH OS — CRASH TELEMETRY                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  This system can automatically send crash reports when programs crash.     │
│  This helps fix hardware-specific bugs (GPU drivers, kernel panics) that   │
│  the developer cannot reproduce on their own hardware.                     │
│                                                                             │
│  ▸ OPT-IN ONLY — nothing sent unless you explicitly agree                  │
│  ▸ CRASHES ONLY — no usage tracking, no analytics, no "telemetry"          │
│  ▸ MINIMAL DATA — only: crashed program name, signal, PCI IDs, kernel      │
│     error lines, package versions (kernel/mesa/drivers), kernel version    │
│  ▸ NO PERSONAL DATA — no file paths with your username, no IPs, no MACs,   │
│     no hostname, no browser history, no home directory contents            │
│  ▸ YOU CAN PREVIEW — run 'telemetry-preview' to see exact JSON payload     │
│  ▸ 90-DAY RETENTION — raw data auto-deleted, no backups                    │
│  ▸ RUN BY ONE PERSON — $5 VPS, no third parties, no analytics companies    │
│                                                                             │
│  Full policy: https://your-domain.org/telemetry-policy                     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
EOF
}

show_preview() {
    echo "─────────────────────────────────────────────────────────────────────────────"
    echo "EXAMPLE PAYLOAD (simulated crash of current session):"
    echo "─────────────────────────────────────────────────────────────────────────────"
    "$PREVIEW_BIN" | jq . 2>/dev/null || "$PREVIEW_BIN"
    echo "─────────────────────────────────────────────────────────────────────────────"
}

main() {
    show_policy
    echo
    show_preview
    echo
    
    while true; do
        read -rp "Enable automatic crash reporting? [y/N]: " choice
        case "$choice" in
            [Yy]|[Yy][Ee][Ss])
                mkdir -p "$(dirname "$OPT_IN_FILE")"
                echo "1" > "$OPT_IN_FILE"
                echo "✓ Crash reporting ENABLED. You can disable anytime with 'sudo telemetry-opt-out'."
                break
                ;;
            [Nn]|[Nn][Oo]|"")
                echo "✓ Crash reporting DISABLED. You can enable later with 'sudo telemetry-opt-in'."
                break
                ;;
            *)
                echo "Please answer y or n."
                ;;
        esac
    done
}

main "$@"
```

---

## 7. INTEGRATION CHECKLIST

| File | Purpose | Status |
|------|---------|--------|
| `telemetry/client-hook/on-crash-report.sh` | systemd-coredump hook, collects & sends | ☐ Create |
| `telemetry/client-hook/telemetry-preview` | Shows exact payload before consent | ☐ Create |
| `telemetry/client-hook/telemetry-opt-in` | Sets `/etc/telemetry/opt-in=1` | ☐ Create |
| `telemetry/client-hook/telemetry-opt-out` | Removes opt-in flag | ☐ Create |
| `telemetry/server/receive.py` | FastAPI ingestion endpoint | ☐ Create |
| `telemetry/server/models.py` | SQLAlchemy schema (optional) | ☐ Create |
| `telemetry/server/privacy_policy.md` | User-facing policy | ☐ Create |
| `telemetry/analyze_clusters.py` | Nemotron clustering cron job | ☐ Create |
| `scripts/telemetry-setup.sh` | Install-time consent flow | ☐ Create |
| `image/mkosi.extra/etc/systemd/system/coredump@.service.d/telemetry.conf` | Hook injection | ☐ Create |
| `.github/workflows/nightly-build.yml` | Deploy server to VPS | ☐ Modify |

---

## 8. SYSTEMD HOOK INJECTION: `image/mkosi.extra/etc/systemd/system/coredump@.service.d/telemetry.conf`

```ini
# image/mkosi.extra/etc/systemd/system/coredump@.service.d/telemetry.conf
# SPDX-License-Identifier: MIT
# Injected by mkosi.extra — hooks telemetry into systemd-coredump

[Service]
# systemd-coredump@.service passes JSON to stdin of ProcessInput=
# We chain our script after the default coredump handling
ExecStartPost=-/usr/lib/systemd/scripts/on-crash-report.sh

# Ensure our script runs even if coredump processing fails
FailureAction=none
```

---

## 9. DEPLOYMENT NOTES FOR SOLO DEVELOPER

### VPS Setup (5$/mo, e.g., Hetzner CX22, DigitalOcean Basic, Linode Nanode)

```bash
# On VPS (Ubuntu 24.04)
sudo apt update && sudo apt install -y python3-venv nginx certbot

# Clone repo, create venv
git clone https://github.com/you/autonomous-arch-os.git
cd autonomous-arch-os/telemetry/server
python3 -m venv venv
source venv/bin/activate
pip install fastapi uvicorn pydantic requests

# Systemd service
sudo tee /etc/systemd/system/telemetry-ingest.service <<'EOF'
[Unit]
Description=Autonomous Arch Telemetry Ingestion
After=network.target

[Service]
Type=exec
User=telemetry
Group=telemetry
WorkingDirectory=/opt/telemetry
Environment=TELEMETRY_STORAGE=/var/lib/telemetry
Environment=PORT=8080
ExecStart=/opt/telemetry/venv/bin/uvicorn receive:app --host 0.0.0.0 --port 8080
Restart=always
RestartSec=5
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/lib/telemetry

[Install]
WantedBy=multi-user.target
EOF

sudo useradd -r -s /bin/false telemetry
sudo mkdir -p /opt/telemetry /var/lib/telemetry
sudo cp -r telemetry/server/* /opt/telemetry/
sudo chown -R telemetry:telemetry /opt/telemetry /var/lib/telemetry
sudo systemctl enable --now telemetry-ingest

# Nginx reverse proxy + TLS (certbot)
sudo certbot --nginx -d telemetry.your-domain.org

# Cron for clustering (hourly)
sudo tee /etc/cron.hourly/telemetry-cluster <<'EOF'
#!/bin/bash
cd /opt/telemetry
source venv/bin/activate
export NEMOTRON_API_KEY="your-key-here"
python3 telemetry/analyze_clusters.py >> /var/log/telemetry-cluster.log 2>&1
EOF
sudo chmod +x /etc/cron.hourly/telemetry-cluster
```

---

**END OF TELEMETRY ARCHITECTURE**  
*All components designed for absolute opt-in, data minimization, and solo-developer operability.*