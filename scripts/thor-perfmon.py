#!/usr/bin/env python3
"""thor-perfmon — system performance recorder for Jetson Thor robots.

Captures the metrics a real systems testbench wants to see while your
application is running. Single source of truth per metric, minimum
external deps (stdlib + matplotlib for plotting).

Sources
  CPU + ctx switches:  /proc/stat                (deltas; user/sys/iowait/idle)
  Load average:        /proc/loadavg
  Memory detail:       /proc/meminfo             (used/cached/buffers/anon/
                                                  slab/pagetables/dirty/wb/swap)
  Page faults + VM:    /proc/vmstat              (deltas; pgfault/pgmajfault/
                                                  pgpgin-out/pswpin-out)
  Disk I/O:            /proc/diskstats           (deltas; MB/s + IOPS, summed
                                                  across non-loop/non-ram devices)
  GPU / EMC / temp /   tegrastats                (per-core CPU clocks too)
   power
  Cache + branches +   perf stat -a -I <ms>      (optional; needs perf binary
   instructions                                   AND kernel.perf_event_paranoid
                                                  ≤ 1 for system-wide events)
  Per-process          /proc/<pid>/{stat,io,...} (optional, --pid)

Usage
  Run system-wide while your application is in another terminal:
      sudo thor-perfmon.py --duration 120 --out /tmp/run1
  Scope to a single process tree:
      sudo thor-perfmon.py --pid $(pidof dma_main) --duration 60
  Headless (no plot):
      sudo thor-perfmon.py --duration 60 --no-plot

Ctrl-C stops cleanly; CSV is flushed and plots render from whatever was
captured. Everything is one file so `scp` it once and run.
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

# ---------------------------------------------------------------------
# Regexes for tegrastats line parsing.
# ---------------------------------------------------------------------
_RE_RAM = re.compile(r"RAM (\d+)/(\d+)MB")
_RE_CPU_BLOCK = re.compile(r"CPU \[([^\]]+)\]")
_RE_GR3D = re.compile(r"GR3D_FREQ\s*@?\[?([0-9,]+)\]?")
_RE_EMC = re.compile(r"EMC_FREQ (\d+)%@(\d+)")
_RE_TJ = re.compile(r"tj@([\d.]+)C")
_RE_VIN = re.compile(r"\bVIN (\d+)mW/(\d+)mW")
_RE_VDD_GPU = re.compile(r"VDD_GPU (-?\d+)mW/(-?\d+)mW")


class TegraStats:
    """Optional sampler. On a Jetson with `tegrastats` installed, spawns
    `tegrastats --interval <ms>`; otherwise stays inert and .latest()
    returns {}. Mirrors PerfStat's pump/latest contract — main loop
    paces itself, this class just hands off the freshest parse."""

    def __init__(self, interval_ms: int):
        self.proc: subprocess.Popen | None = None
        self.ok = False
        self._latest: dict = {}
        if not shutil.which("tegrastats"):
            return
        try:
            self.proc = subprocess.Popen(
                ["tegrastats", "--interval", str(interval_ms)],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, bufsize=1,
            )
            self.ok = True
        except Exception:
            self.proc = None
            return
        # Prime: tegrastats emits its first line ~1s after spawn (or
        # one --interval). Block briefly so the first parsed row is
        # available before the main loop writes the first CSV row;
        # otherwise tegrastats columns get locked OUT of the header.
        self._prime(timeout_s=max(2.0, interval_ms / 1000.0 + 0.5))

    def _prime(self, timeout_s: float) -> None:
        import select
        if self.proc is None or self.proc.stdout is None:
            return
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            r, _, _ = select.select([self.proc.stdout], [], [],
                                     max(0.0, deadline - time.monotonic()))
            if not r:
                break
            line = self.proc.stdout.readline()
            if not line:
                break
            row = parse_tegrastats(line)
            if row is not None:
                self._latest = row
                return  # got one; columns are now known
        # Timed out without a parseable line — tegrastats is alive but
        # producing nothing useful; downgrade so the rest of the run
        # behaves as if tegrastats wasn't available.
        if not self._latest:
            self.ok = False
            self.stop()

    def pump(self) -> None:
        if not self.ok or self.proc is None or self.proc.stdout is None:
            return
        import select
        # Drain everything pending, keep the most recent parseable row.
        while True:
            r, _, _ = select.select([self.proc.stdout], [], [], 0)
            if not r:
                break
            line = self.proc.stdout.readline()
            if not line:
                break
            row = parse_tegrastats(line)
            if row is not None:
                self._latest = row

    def latest(self) -> dict:
        return dict(self._latest)

    def stop(self) -> None:
        if self.proc and self.proc.poll() is None:
            try:
                self.proc.terminate()
                self.proc.wait(timeout=2)
            except Exception:
                try: self.proc.kill()
                except Exception: pass


def parse_tegrastats(line: str) -> dict | None:
    """Parse one tegrastats line into a flat dict."""
    if "RAM " not in line or "CPU [" not in line:
        return None
    out: dict = {}
    if (m := _RE_RAM.search(line)):
        out["tg_ram_used_mb"] = int(m.group(1))
        out["tg_ram_total_mb"] = int(m.group(2))
    if (m := _RE_CPU_BLOCK.search(line)):
        cores = m.group(1).split(",")
        loads, freqs = [], []
        for c in cores:
            mc = re.match(r"(\d+)%@(\d+)", c.strip())
            if mc:
                loads.append(int(mc.group(1)))
                freqs.append(int(mc.group(2)))
            else:
                loads.append(0)
                freqs.append(0)
        for i, (ld, fr) in enumerate(zip(loads, freqs)):
            out[f"tg_cpu{i}_pct"] = ld
            out[f"tg_cpu{i}_mhz"] = fr
    if (m := _RE_GR3D.search(line)):
        gpcs = [int(x) for x in m.group(1).split(",") if x]
        out["gpu_pct"] = round(sum(gpcs) / len(gpcs), 1) if gpcs else 0.0
        out["gpu_max_pct"] = max(gpcs) if gpcs else 0
    if (m := _RE_EMC.search(line)):
        out["emc_pct"] = int(m.group(1))
        out["emc_mhz"] = int(m.group(2))
    if (m := _RE_TJ.search(line)):
        out["tj_c"] = float(m.group(1))
    if (m := _RE_VIN.search(line)):
        out["vin_mw"] = int(m.group(1))
    if (m := _RE_VDD_GPU.search(line)):
        out["vdd_gpu_mw"] = int(m.group(1))
    return out


# ---------------------------------------------------------------------
# /proc snapshot helpers — capture cumulative counters; deltas are
# computed by the caller between consecutive samples.
# ---------------------------------------------------------------------

def snap_proc_stat() -> dict:
    """Cumulative counters from /proc/stat:
    user, nice, system, idle, iowait, irq, softirq, steal (jiffies),
    plus ctxt (context switches), processes (forks), procs_running."""
    out = {}
    with open("/proc/stat") as f:
        for line in f:
            parts = line.split()
            if not parts:
                continue
            if parts[0] == "cpu":  # aggregate line
                vals = [int(x) for x in parts[1:11]]  # user..guest_nice
                names = ["user", "nice", "system", "idle", "iowait",
                         "irq", "softirq", "steal", "guest", "guest_nice"]
                for n, v in zip(names, vals[: len(names)]):
                    out[f"cpu_{n}_jif"] = v
            elif parts[0] == "ctxt":
                out["ctxt"] = int(parts[1])
            elif parts[0] == "processes":
                out["forks"] = int(parts[1])
            elif parts[0] == "procs_running":
                out["procs_running"] = int(parts[1])
            elif parts[0] == "intr":
                out["intr"] = int(parts[1])
    return out


def snap_meminfo() -> dict:
    out = {}
    keys = {
        "MemTotal": "mem_total_kb", "MemFree": "mem_free_kb",
        "MemAvailable": "mem_avail_kb", "Buffers": "mem_buffers_kb",
        "Cached": "mem_cached_kb", "SwapCached": "mem_swapcached_kb",
        "Active": "mem_active_kb", "Inactive": "mem_inactive_kb",
        "AnonPages": "mem_anon_kb", "Mapped": "mem_mapped_kb",
        "Shmem": "mem_shmem_kb", "Slab": "mem_slab_kb",
        "SReclaimable": "mem_sreclaim_kb", "PageTables": "mem_pagetables_kb",
        "Dirty": "mem_dirty_kb", "Writeback": "mem_writeback_kb",
        "SwapTotal": "swap_total_kb", "SwapFree": "swap_free_kb",
    }
    with open("/proc/meminfo") as f:
        for line in f:
            name, _, rest = line.partition(":")
            if name in keys:
                out[keys[name]] = int(rest.strip().split()[0])
    return out


def snap_vmstat() -> dict:
    keys = {
        "pgfault", "pgmajfault", "pgpgin", "pgpgout",
        "pswpin", "pswpout", "oom_kill",
        "pgreuse", "pgsteal_kswapd", "pgsteal_direct",
        "allocstall_movable", "allocstall_normal", "allocstall_dma",
    }
    out = {}
    with open("/proc/vmstat") as f:
        for line in f:
            k, _, v = line.partition(" ")
            if k in keys:
                out[k] = int(v.strip())
    return out


def snap_diskstats() -> dict:
    """Sum read/write sectors + IOs across real block devices.
    Skips loop, ram, and partition entries — major:minor 7 is loop,
    1 is ramdisk; partitions are filtered by name pattern."""
    rd_ios = wr_ios = rd_sect = wr_sect = 0
    try:
        with open("/proc/diskstats") as f:
            for line in f:
                p = line.split()
                if len(p) < 14:
                    continue
                major, minor, name = int(p[0]), int(p[1]), p[2]
                if major in (1, 7):  # ram, loop
                    continue
                # Skip partitions: nvme0n1p1, sda1, mmcblk0p2, dm-* OK
                if re.match(r"^(nvme\d+n\d+p\d+|sd[a-z]+\d+|mmcblk\d+p\d+)$",
                            name):
                    continue
                rd_ios += int(p[3])
                rd_sect += int(p[5])
                wr_ios += int(p[7])
                wr_sect += int(p[9])
    except FileNotFoundError:
        pass
    # 512-byte sectors → bytes
    return {
        "disk_read_ios": rd_ios, "disk_write_ios": wr_ios,
        "disk_read_kb": rd_sect // 2, "disk_write_kb": wr_sect // 2,
    }


def snap_loadavg() -> dict:
    with open("/proc/loadavg") as f:
        parts = f.read().split()
    return {"load_1m": float(parts[0]), "load_5m": float(parts[1]),
            "load_15m": float(parts[2])}


def snap_pid(pid: int) -> dict:
    """Best-effort per-pid snapshot. Missing fields just silently empty."""
    out = {}
    base = Path(f"/proc/{pid}")
    if not base.exists():
        return out
    try:
        with (base / "stat").open() as f:
            s = f.read()
        # comm is bracketed. Take the SUFFIX after the last ')'
        rest = s.rsplit(")", 1)[1].split()
        # offsets per `man 5 proc` (after-comm fields are 1-indexed from 0):
        #   0=state 11=utime 12=stime 13=cutime 14=cstime
        #   17=num_threads 21=starttime 22=vsize 23=rss(pages)
        out["pid_state"] = rest[0]
        out["pid_utime_jif"] = int(rest[11])
        out["pid_stime_jif"] = int(rest[12])
        out["pid_threads"] = int(rest[17])
        out["pid_rss_pages"] = int(rest[23])
    except Exception:
        pass
    try:
        with (base / "io").open() as f:
            for line in f:
                k, _, v = line.partition(":")
                k = k.strip()
                v = int(v.strip()) if v.strip().isdigit() else 0
                if k in ("rchar", "wchar", "read_bytes", "write_bytes"):
                    out[f"pid_io_{k}"] = v
    except Exception:
        pass
    try:
        with (base / "status").open() as f:
            for line in f:
                if line.startswith("voluntary_ctxt_switches"):
                    out["pid_ctxsw_vol"] = int(line.split()[1])
                elif line.startswith("nonvoluntary_ctxt_switches"):
                    out["pid_ctxsw_invol"] = int(line.split()[1])
    except Exception:
        pass
    return out


# ---------------------------------------------------------------------
# perf stat — optional. Background subprocess emits CSV-ish counters
# every <interval> ms; we read them and pick up the latest value.
# ---------------------------------------------------------------------

PERF_EVENTS = [
    "cycles", "instructions",
    "cache-references", "cache-misses",
    "branches", "branch-misses",
    "page-faults", "context-switches",
]


class PerfStat:
    """Spawn `perf stat -a -I <ms> -e <events> -x ;` and harvest the
    most recent value for each event. perf prints lines like:
        <ts>;<value>;<unit>;<event>;<runtime>;<pct>;<...>
    We track the last value seen for each event name. If perf isn't
    available or fails to start, .ok stays False and .latest() returns {}.
    """

    def __init__(self, interval_ms: int, pid: int | None = None,
                 events: list[str] = PERF_EVENTS):
        self.events = events
        self._latest: dict[str, float] = {}
        self.proc: subprocess.Popen | None = None
        self.ok = False
        self.unavailable_reason: str = ""
        if not shutil.which("perf"):
            self.unavailable_reason = "perf binary not in PATH"
            return
        # Pre-flight: try the events once with a no-op, capture stderr.
        # Catches the common 'paranoid=2 blocks system-wide events' case
        # before we commit to a long-running subprocess that would
        # silently produce no data.
        scope = ["-p", str(pid)] if pid is not None else ["-a"]
        try:
            probe = subprocess.run(
                ["perf", "stat", "-x", ";", "-e", ",".join(events)] + scope
                + ["--", "/bin/true"],
                capture_output=True, text=True, timeout=5,
            )
        except Exception as exc:
            self.unavailable_reason = f"perf probe failed to spawn: {exc}"
            return
        err = probe.stderr or ""
        err_lower = err.lower()
        access_blocked = (
            "access to performance monitoring" in err_lower
            or ("permission" in err_lower and "denied" in err_lower)
            or "operation not permitted" in err_lower
        )
        if probe.returncode != 0 or access_blocked:
            # Pick the first informative line — skip bare 'Error:' and
            # the perf_event_paranoid help dump.
            skip_prefixes = ("error:", "perf_event_paranoid", ">=",
                             "  -1:", "  ", "to make ", "more information")
            first_msg = next(
                (l.strip() for l in err.splitlines()
                 if l.strip() and not l.strip().lower().startswith(skip_prefixes)),
                "perf stat refused to count events"
            )
            self.unavailable_reason = first_msg
            return
        cmd = ["perf", "stat", "-x", ";", "-I", str(interval_ms), "-e",
               ",".join(events)] + scope
        try:
            self.proc = subprocess.Popen(
                cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                text=True, bufsize=1,
            )
            self.ok = True
        except Exception as exc:
            self.unavailable_reason = f"perf failed to spawn: {exc}"
            self.proc = None

    def pump(self) -> None:
        """Drain whatever new lines perf emitted since last call.
        On hybrid CPUs (Intel P+E cores) perf splits each event per
        cluster (e.g. 'cpu_atom/cycles/' and 'cpu_core/cycles/'); we
        normalize to the bare event name and sum across clusters per
        sample window so the CSV column set stays stable."""
        if not self.ok or self.proc is None or self.proc.stderr is None:
            return
        import select
        # Group readings within the same interval window. Each line:
        #   <ts>;<value>;<unit>;<event>;<runtime>;<pct>;<rate>;<unit2>
        # Lines emitted in one interval share the same <ts>.
        wanted = set(self.events)
        new_window: dict[str, float] = {}
        last_ts = None
        while True:
            r, _, _ = select.select([self.proc.stderr], [], [], 0)
            if not r:
                break
            line = self.proc.stderr.readline()
            if not line:
                break
            parts = line.split(";")
            if len(parts) < 4:
                continue
            ts_field = parts[0].strip()
            val_str = parts[1].strip()
            ev_raw = parts[3].strip()
            if val_str in ("<not counted>", "<not supported>", ""):
                continue
            # Normalize 'cpu_atom/cycles/' -> 'cycles', 'cycles' -> 'cycles'.
            ev = ev_raw.split("/")[-2] if "/" in ev_raw else ev_raw
            if ev not in wanted:
                continue
            try:
                val = float(val_str.replace(",", ""))
            except ValueError:
                continue
            # New interval — flush the previous one to _latest.
            if last_ts is not None and ts_field != last_ts and new_window:
                self._latest.update(new_window)
                new_window = {}
            last_ts = ts_field
            # Sum across clusters within the window (atom + core).
            new_window[ev] = new_window.get(ev, 0.0) + val
        if new_window:
            self._latest.update(new_window)

    def latest(self) -> dict:
        out = {}
        for ev, v in self._latest.items():
            key = f"perf_{ev.replace('-', '_')}"
            out[key] = int(v) if isinstance(v, float) and v.is_integer() else v
        return out

    def expected_columns(self) -> list[str]:
        """Return the column names we expect to populate. Used by the
        CSV writer to lock the header before perf has emitted its first
        interval (which doesn't land until ~t=1s after start)."""
        if not self.ok:
            return []
        return [f"perf_{ev.replace('-', '_')}" for ev in self.events]

    def stop(self) -> None:
        if self.proc and self.proc.poll() is None:
            try:
                self.proc.terminate()
                self.proc.wait(timeout=2)
            except Exception:
                try:
                    self.proc.kill()
                except Exception:
                    pass


# ---------------------------------------------------------------------
# Sample assembly: combine all sources + compute deltas.
# ---------------------------------------------------------------------

def cpu_pct_from_jif(prev: dict, cur: dict) -> dict:
    """Convert /proc/stat jiffy deltas into percentages."""
    out = {}
    fields = ("user", "nice", "system", "idle", "iowait", "irq",
              "softirq", "steal")
    deltas = {f: cur.get(f"cpu_{f}_jif", 0) - prev.get(f"cpu_{f}_jif", 0)
              for f in fields}
    total = sum(deltas.values())
    if total <= 0:
        return out
    for f in fields:
        out[f"cpu_{f}_pct"] = round(100.0 * deltas[f] / total, 2)
    out["cpu_busy_pct"] = round(100.0 * (total - deltas["idle"]) / total, 2)
    return out


def diff_per_sec(prev: dict, cur: dict, keys: list[str], dt_s: float,
                 prefix: str = "") -> dict:
    out = {}
    if dt_s <= 0:
        return out
    for k in keys:
        if k in prev and k in cur:
            out[f"{prefix}{k}_per_s"] = round((cur[k] - prev[k]) / dt_s, 2)
    return out


# ---------------------------------------------------------------------
# CSV writer — column order locked from first row (other rows fill
# missing fields with empty string).
# ---------------------------------------------------------------------

class CsvWriter:
    def __init__(self, path: Path, extra_columns: list[str] | None = None):
        self.path = path
        self._fh = None
        self._writer: csv.DictWriter | None = None
        self._fieldnames: list[str] = []
        # Columns the caller knows will appear later but won't be in
        # the first row (e.g. perf-stat counters that lag by ~1s).
        self._extra_columns = list(extra_columns or [])

    def write(self, row: dict) -> None:
        if self._writer is None:
            base = ["ts"] + [k for k in row.keys()
                             if k != "ts" and not k.startswith("_")]
            extras = [c for c in self._extra_columns if c not in base]
            self._fieldnames = base + extras
            self._fh = self.path.open("w", newline="")
            self._writer = csv.DictWriter(self._fh, fieldnames=self._fieldnames)
            self._writer.writeheader()
        clean = {k: row.get(k, "") for k in self._fieldnames}
        self._writer.writerow(clean)
        self._fh.flush()

    def close(self) -> None:
        if self._fh:
            self._fh.close()
            self._fh = None


# ---------------------------------------------------------------------
# Plotting — multi-panel grid. Lazy matplotlib import so the tool
# remains useful headless without matplotlib installed.
# ---------------------------------------------------------------------

def render_plot(csv_path: Path, png_path: Path) -> None:
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("[perfmon] matplotlib unavailable — skipping plot",
              file=sys.stderr)
        return

    rows = list(csv.DictReader(csv_path.open()))
    if not rows:
        print(f"[perfmon] no rows in {csv_path}, skipping plot", file=sys.stderr)
        return

    t0 = dt.datetime.fromisoformat(rows[0]["ts"])
    xs = [(dt.datetime.fromisoformat(r["ts"]) - t0).total_seconds() for r in rows]

    def col(name: str, default=float("nan")) -> list:
        return [float(r[name]) if r.get(name) not in ("", None) else default
                for r in rows]

    has = lambda k: k in rows[0]
    fig, axes = plt.subplots(3, 2, figsize=(14, 11), sharex=True)
    fig.suptitle(f"thor-perfmon  {csv_path.name}  ({len(rows)} samples)",
                 fontsize=11)

    # 1. CPU breakdown + load avg
    ax = axes[0][0]
    if has("cpu_busy_pct"):
        ax.plot(xs, col("cpu_busy_pct"), color="black", linewidth=1.6,
                label="busy")
    for f, c in [("user", "tab:blue"), ("system", "tab:red"),
                 ("iowait", "tab:purple")]:
        k = f"cpu_{f}_pct"
        if has(k):
            ax.plot(xs, col(k), color=c, alpha=0.7, label=f)
    ax.set_ylabel("CPU %")
    ax.set_ylim(0, 100)
    ax.legend(loc="upper right", fontsize=8)
    ax.grid(alpha=0.3)
    if has("load_1m"):
        ax2 = ax.twinx()
        ax2.plot(xs, col("load_1m"), color="tab:green", linestyle=":",
                 alpha=0.8, label="load 1m")
        ax2.set_ylabel("load 1m")
        ax2.legend(loc="lower right", fontsize=7)

    # 2. GPU + EMC + temperature
    ax = axes[0][1]
    if has("gpu_pct"):
        ax.plot(xs, col("gpu_pct"), color="tab:green", label="GPU avg")
    if has("emc_pct"):
        ax.plot(xs, col("emc_pct"), color="tab:purple", linestyle="--",
                alpha=0.7, label="EMC")
    ax.set_ylabel("%")
    ax.set_ylim(0, 100)
    ax.legend(loc="upper right", fontsize=8)
    ax.grid(alpha=0.3)
    if has("tj_c"):
        ax2 = ax.twinx()
        ax2.plot(xs, col("tj_c"), color="tab:orange", linestyle=":",
                 alpha=0.8, label="Tj (°C)")
        ax2.set_ylabel("Tj (°C)")
        ax2.legend(loc="lower right", fontsize=7)

    # 3. Memory components (MB)
    ax = axes[1][0]
    if has("mem_total_kb"):
        total_mb = float(rows[0].get("mem_total_kb", 0)) / 1024.0
        for k, c, lbl in [
            ("mem_anon_kb", "tab:red", "anon"),
            ("mem_cached_kb", "tab:blue", "cached"),
            ("mem_buffers_kb", "tab:cyan", "buffers"),
            ("mem_slab_kb", "tab:olive", "slab"),
            ("mem_dirty_kb", "tab:pink", "dirty"),
        ]:
            if has(k):
                ax.plot(xs, [v / 1024.0 for v in col(k, 0)],
                        color=c, label=lbl, alpha=0.8)
        ax.axhline(total_mb, color="grey", linestyle=":", linewidth=0.6,
                   label=f"total {total_mb:.0f}MB")
    ax.set_ylabel("MB")
    ax.legend(loc="upper right", fontsize=8)
    ax.grid(alpha=0.3)

    # 4. Faults / context switches per second
    ax = axes[1][1]
    if has("pgfault_per_s"):
        ax.plot(xs, col("pgfault_per_s"), color="tab:blue", label="pgfault/s")
    if has("pgmajfault_per_s"):
        ax.plot(xs, col("pgmajfault_per_s"), color="tab:red",
                label="pgmajfault/s")
    if has("ctxt_per_s"):
        ax2 = ax.twinx()
        ax2.plot(xs, col("ctxt_per_s"), color="tab:green", linestyle="--",
                 alpha=0.6, label="ctxt sw/s")
        ax2.set_ylabel("ctxt/s")
        ax2.legend(loc="lower right", fontsize=7)
    ax.set_ylabel("faults/s")
    ax.legend(loc="upper right", fontsize=8)
    ax.grid(alpha=0.3)

    # 5. Disk I/O
    ax = axes[2][0]
    if has("disk_read_kb_per_s"):
        ax.plot(xs, [v / 1024.0 for v in col("disk_read_kb_per_s", 0)],
                color="tab:blue", label="read MB/s")
    if has("disk_write_kb_per_s"):
        ax.plot(xs, [v / 1024.0 for v in col("disk_write_kb_per_s", 0)],
                color="tab:red", label="write MB/s")
    ax.set_ylabel("MB/s")
    ax.set_xlabel("seconds")
    ax.legend(loc="upper right", fontsize=8)
    ax.grid(alpha=0.3)
    if has("disk_read_ios_per_s") or has("disk_write_ios_per_s"):
        ax2 = ax.twinx()
        if has("disk_read_ios_per_s"):
            ax2.plot(xs, col("disk_read_ios_per_s"), color="tab:cyan",
                     linestyle=":", alpha=0.6, label="read IOPS")
        if has("disk_write_ios_per_s"):
            ax2.plot(xs, col("disk_write_ios_per_s"), color="tab:pink",
                     linestyle=":", alpha=0.6, label="write IOPS")
        ax2.set_ylabel("IOPS")
        ax2.legend(loc="lower right", fontsize=7)

    # 6. Cache misses + IPC + power
    ax = axes[2][1]
    if has("perf_cache_misses") and has("perf_cache_references"):
        miss_rate = []
        for r in rows:
            try:
                m = float(r["perf_cache_misses"])
                ref = float(r["perf_cache_references"])
                miss_rate.append(100.0 * m / ref if ref > 0 else float("nan"))
            except (ValueError, TypeError, KeyError):
                miss_rate.append(float("nan"))
        ax.plot(xs, miss_rate, color="tab:red", label="cache miss %")
    if has("perf_branch_misses") and has("perf_branches"):
        bmiss = []
        for r in rows:
            try:
                m = float(r["perf_branch_misses"])
                br = float(r["perf_branches"])
                bmiss.append(100.0 * m / br if br > 0 else float("nan"))
            except (ValueError, TypeError, KeyError):
                bmiss.append(float("nan"))
        ax.plot(xs, bmiss, color="tab:purple", label="branch miss %")
    ax.set_ylabel("miss %")
    ax.set_xlabel("seconds")
    ax.legend(loc="upper left", fontsize=8)
    ax.grid(alpha=0.3)
    if has("vin_mw"):
        ax2 = ax.twinx()
        ax2.plot(xs, [v / 1000.0 for v in col("vin_mw", 0)],
                 color="tab:orange", linestyle=":", alpha=0.7,
                 label="VIN (W)")
        ax2.set_ylabel("Power (W)")
        ax2.legend(loc="upper right", fontsize=7)

    fig.tight_layout()
    fig.savefig(png_path, dpi=120)
    import matplotlib.pyplot as plt2
    plt2.close(fig)
    print(f"[perfmon] plot -> {png_path}")


# ---------------------------------------------------------------------
# CLI + main loop
# ---------------------------------------------------------------------

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--duration", type=float, default=300,
                   help="Duration in seconds. 0 = until interrupted. Default 300.")
    p.add_argument("--interval-ms", type=int, default=1000,
                   help="Sampling interval in ms. Default 1000.")
    p.add_argument("--pid", type=int, default=None,
                   help="Also capture per-pid metrics for this process.")
    p.add_argument("--out", default=None,
                   help="Output prefix (e.g. /tmp/run1). Default: ./perfmon_<host>_<ts>")
    p.add_argument("--no-plot", action="store_true",
                   help="Skip matplotlib plot at exit.")
    p.add_argument("--no-perf", action="store_true",
                   help="Skip perf stat (cache miss, branch, etc.) entirely.")
    p.add_argument("--quiet", action="store_true",
                   help="Suppress per-sample stdout summary.")
    return p.parse_args()


def default_prefix() -> str:
    host = os.uname().nodename
    ts = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    return f"perfmon_{host}_{ts}"


def main() -> int:
    args = parse_args()

    prefix = Path(args.out or default_prefix())
    prefix.parent.mkdir(parents=True, exist_ok=True)
    csv_path = prefix.with_suffix(".csv")
    png_path = prefix.with_suffix(".png")

    # Optional samplers. Both stay inert when their backing tool is
    # missing — main loop is sleep-paced, neither sampler gates capture.
    tg = TegraStats(args.interval_ms)
    if not tg.ok:
        print("[perfmon] tegrastats unavailable — GPU/EMC/temp/power columns "
              "will be absent (this is fine on non-Jetson hosts)",
              file=sys.stderr)
    perf = None
    if not args.no_perf:
        perf = PerfStat(args.interval_ms, args.pid)
        if not perf.ok:
            reason = perf.unavailable_reason or "unknown"
            print(f"[perfmon] perf disabled — {reason}", file=sys.stderr)
            if "paranoid" in reason.lower() or "permission" in reason.lower() \
                    or "access to performance" in reason.lower():
                print("[perfmon]   to enable system-wide events: "
                      "sudo sysctl kernel.perf_event_paranoid=1 (or =-1)",
                      file=sys.stderr)

    print(f"[perfmon] writing {csv_path}")
    print(f"[perfmon] interval={args.interval_ms}ms duration="
          f"{'∞' if args.duration <= 0 else f'{args.duration:.0f}s'}"
          f"  pid={args.pid or 'system-wide'}"
          f"  tegrastats={'on' if tg.ok else 'off'}"
          f"  perf={'on' if perf and perf.ok else 'off'}")

    extra_cols = perf.expected_columns() if perf and perf.ok else []
    writer = CsvWriter(csv_path, extra_columns=extra_cols)

    prev_stat = snap_proc_stat()
    prev_vm = snap_vmstat()
    prev_disk = snap_diskstats()
    prev_pid = snap_pid(args.pid) if args.pid else {}
    prev_t = time.monotonic()

    stop_at = (time.monotonic() + args.duration) if args.duration > 0 else None
    interval_s = args.interval_ms / 1000.0
    n = 0
    interrupted = False

    def stop(_sig, _frm):
        nonlocal interrupted
        interrupted = True
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)

    try:
        # Sleep-paced main loop. Each iteration: wait one interval, drain
        # any tegrastats / perf output that arrived during the sleep,
        # snapshot /proc, compute deltas, write a CSV row.
        while not interrupted:
            time.sleep(interval_s)
            if interrupted:
                break

            now = time.monotonic()
            dt_s = now - prev_t
            prev_t = now
            ts = dt.datetime.now().isoformat(timespec="milliseconds")

            tg.pump()
            if perf:
                perf.pump()

            cur_stat = snap_proc_stat()
            cur_mem = snap_meminfo()
            cur_vm = snap_vmstat()
            cur_disk = snap_diskstats()
            cur_load = snap_loadavg()
            cur_pid = snap_pid(args.pid) if args.pid else {}

            row: dict = {"ts": ts}
            row.update(cpu_pct_from_jif(prev_stat, cur_stat))
            row.update(diff_per_sec(prev_stat, cur_stat,
                                    ["ctxt", "intr", "forks"], dt_s))
            row["procs_running"] = cur_stat.get("procs_running", 0)
            row.update(cur_load)
            row.update(cur_mem)
            row["mem_used_kb"] = (cur_mem.get("mem_total_kb", 0)
                                  - cur_mem.get("mem_avail_kb", 0))
            row["swap_used_kb"] = (cur_mem.get("swap_total_kb", 0)
                                   - cur_mem.get("swap_free_kb", 0))
            row.update(diff_per_sec(prev_vm, cur_vm,
                                    ["pgfault", "pgmajfault", "pgpgin", "pgpgout",
                                     "pswpin", "pswpout"], dt_s))
            row.update(diff_per_sec(prev_disk, cur_disk,
                                    ["disk_read_ios", "disk_write_ios",
                                     "disk_read_kb", "disk_write_kb"], dt_s))
            row.update(tg.latest())
            if args.pid:
                row.update(cur_pid)
                row.update(diff_per_sec(prev_pid, cur_pid,
                                        ["pid_io_rchar", "pid_io_wchar",
                                         "pid_io_read_bytes", "pid_io_write_bytes",
                                         "pid_ctxsw_vol", "pid_ctxsw_invol"],
                                        dt_s))
            if perf:
                row.update(perf.latest())

            writer.write(row)
            n += 1
            if not args.quiet:
                cpu = row.get("cpu_busy_pct", 0)
                gpu = row.get("gpu_pct", "")
                ram_pct = (100.0 * row.get("mem_used_kb", 0)
                           / max(row.get("mem_total_kb", 1), 1))
                pgmaj = row.get("pgmajfault_per_s", 0)
                rd = row.get("disk_read_kb_per_s", 0) / 1024.0
                wr = row.get("disk_write_kb_per_s", 0) / 1024.0
                ctxt = row.get("ctxt_per_s", 0)
                tj = row.get("tj_c", "")
                vin = row.get("vin_mw", 0)
                # Format optional fields as "—" when absent.
                gpu_s = f"{gpu:4.1f}%" if isinstance(gpu, (int, float)) else "  --"
                tj_s = f"{tj:4.1f}C" if isinstance(tj, (int, float)) else " ---"
                vin_s = f"{vin/1000.0:5.2f}W" if isinstance(vin, (int, float)) and vin else "  ---"
                print(f"{ts}  cpu={cpu:5.1f}%  gpu={gpu_s}  ram={ram_pct:4.1f}%  "
                      f"pgmaj/s={pgmaj:5.1f}  rd={rd:5.1f}MB/s wr={wr:5.1f}MB/s  "
                      f"ctxt/s={ctxt:6.0f}  tj={tj_s}  vin={vin_s}")

            prev_stat = cur_stat
            prev_vm = cur_vm
            prev_disk = cur_disk
            prev_pid = cur_pid

            if stop_at is not None and time.monotonic() >= stop_at:
                break
    finally:
        tg.stop()
        if perf: perf.stop()
        writer.close()

    print(f"[perfmon] {n} samples written to {csv_path}"
          f"{' (interrupted)' if interrupted else ''}")
    if not args.no_plot and n > 0:
        render_plot(csv_path, png_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
