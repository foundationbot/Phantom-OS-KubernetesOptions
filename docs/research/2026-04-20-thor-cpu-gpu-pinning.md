# CPU & GPU Pinning on Jetson Thor in k0s — Research Doc

**Author:** Gaurav
**Date:** 2026-04-20
**Status:** Draft — awaiting validation
**Scope:** Single Thor device, single iGPU, multi-tier robotics workload running under k0s.

---

## 1. Problem statement

We need to co-schedule three workload tiers on a single Jetson Thor module running k0s, each with different latency and compute requirements, and guarantee that the real-time tier is not starved by the other two.

Workload tiers (from whiteboard):

| Tier | Frequency | Workloads | Target resources (from whiteboard) |
|------|-----------|-----------|------------------------------------|
| A — On-demand | bursty / low rate | Qwen (LLM), V-JEPA, world models (~2–3 B params) | CPU + large SM share + VRAM burst |
| B — Perception | ~10 Hz | DinoVL, action solver, NAV/SLAM, PremAke | CPU + mid SM share |
| C — Real-time control | 50–500 Hz, WBC target ~1 kHz | WBC (whole-body controller), GhPPO | CPU + guaranteed SM reservation, hard latency |

Hard constraints:
- Single physical GPU — "GPU 0/1/2" on the whiteboard refers to *logical SM partitions*, not discrete GPUs.
- Thor iGPU shares system memory with CPU (unified memory) — VRAM partitioning is also RAM partitioning.
- Tier C must meet its deadline under worst-case contention from A and B.
- Deployment is k0s-managed; config should live in GitOps alongside the rest of the platform.

Non-goals for this doc:
- Choosing the LLM/perception model binaries.
- Cluster-wide multi-node scheduling (single-node problem for now).
- PREEMPT_RT kernel selection (tracked separately; assumed available).

---

## 2. Background facts (verified vs. assumed)

| # | Fact | Status | Source / needs verification |
|---|------|--------|-----------------------------|
| F1 | MIG is **not** available on Jetson Thor (datacenter-only: A100/H100/B200) | Assumed — matches public NVIDIA docs to date | **AI-1:** Confirm against current JetPack / Thor datasheet. |
| F2 | Thor iGPU supports CUDA MPS | Assumed | **AI-2:** Confirm MPS daemon runs on JetPack for Thor. |
| F3 | Thor iGPU supports CUDA Green Contexts (CUDA 12.4+) | Assumed — depends on shipped CUDA version | **AI-3:** Check `nvcc --version` on Thor dev kit; verify `cuDevSmResourceSplitByCount` symbol exists. |
| F4 | NVIDIA k8s device plugin has a Jetson-compatible build with MPS mode | Assumed — GPU Operator added Jetson profile in 2024 | **AI-4:** Verify device-plugin image tag that works on arm64 JetPack. |
| F5 | k0s exposes kubelet CPU Manager / Topology Manager via `workerProfiles` | Verified — documented k0s feature | k0s docs: worker profiles |
| F6 | Guaranteed QoS pods (integer CPU, requests==limits) are required for static CPU pinning | Verified — upstream k8s behavior | k8s docs: CPU Manager |
| F7 | Unified memory on Thor means GPU "VRAM" requests consume host RAM | Verified — Jetson architecture | JetPack docs |
| F8 | MPS caps via `CUDA_MPS_ACTIVE_THREAD_PERCENTAGE` are soft (best-effort, not reservations) | Verified — NVIDIA MPS docs | NVIDIA MPS manual |
| F9 | Green Contexts provide hard SM partitioning at driver level | Verified — CUDA 12.4 release notes | CUDA 12.4 changelog |

Any "Assumed" item must be validated before we commit to architecture (see §7 action items).

---

## 3. Candidate approaches

### Approach 1 — All-MPS via device plugin

Split the single GPU into N equal MPS slices (e.g. N = 10 → 10 % SM each) and let each pod request an integer number of slices.

**Wiring:**
- NVIDIA device plugin DaemonSet with `sharing.mps.replicas = 10`
- MPS control daemon runs on the node
- Pods request `nvidia.com/gpu: K` (K slices)

**Pros:**
- Fully Kubernetes-native; scheduler knows about the resource.
- No application code changes.
- Works with existing GPU Operator tooling.
- Memory partitioning comes "for free" — each slice gets 1/N of the memory quota.
- Configurable via GitOps (Helm values on the device plugin).

**Cons:**
- **Soft caps only** — under contention Tier C can still see jitter.
- Fixed equal-sized slices limit flexibility; unequal tiers waste slices or fragment allocation.
- MPS itself adds ~small but nonzero scheduling overhead.
- A single misbehaving Tier A kernel can still occupy SMs and delay Tier C dispatch.
- MPS has historically had stability quirks on iGPU; needs confirmation on Thor.

**Fit for whiteboard tiers:**
- Tier A: good.
- Tier B: good.
- Tier C: **risky** at 500 Hz, likely unacceptable at 1 kHz.

---

### Approach 2 — Hybrid: MPS for A/B, Green Contexts for C

Device-plugin MPS covers the flexible, non-RT tiers. The Tier C container owns a dedicated MPS slice large enough to host its Green Context, and internally carves out a hard SM partition via the CUDA driver API.

**Wiring:**
- Same device-plugin config as Approach 1.
- WBC container code adds Green Context init: reserve e.g. 30 % of SMs hard, run WBC kernels on that context.
- WBC pod gets Guaranteed QoS + pinned CPUs + `topology-manager-policy: single-numa-node`.

**Pros:**
- Tier C gets **hard** SM reservation — no jitter from A/B GPU workloads.
- Tier A/B keep the ergonomics of Approach 1.
- No extra infrastructure components beyond device plugin + MPS.
- Green Contexts are the vendor-recommended path for partitioning on non-MIG GPUs going forward.

**Cons:**
- Requires WBC application code change (Green Context setup in startup path).
- Green Contexts are newer (CUDA 12.4+) — smaller body of operational experience, especially on Jetson.
- Failure modes of Green Context + MPS combined are not well-documented; could surface only under real contention.
- SM count on Thor (exact value) determines feasible partition granularity — need the number.

**Fit:**
- Tier A: good.
- Tier B: good.
- Tier C: **good if Green Contexts work on Thor iGPU** — this is the key unknown.

---

### Approach 3 — CUDA stream priorities + process priority, no partitioning

Skip SM partitioning entirely. All workloads share the GPU via the default context; Tier C uses high-priority CUDA streams and CPU-side `SCHED_FIFO` to win every dispatch race. CPU pinning still applies.

**Wiring:**
- No device plugin sharing config; each pod just sees `nvidia.com/gpu: 1`.
- Application code uses `cudaStreamCreateWithPriority` with high priority for WBC.
- WBC process runs with `SCHED_FIFO` and pinned cores.

**Pros:**
- Simplest — no MPS, no Green Contexts, no device-plugin tuning.
- Matches how most working robotics stacks (Isaac ROS, ros2_control GPU components) actually ship today.
- Lowest per-kernel overhead.

**Cons:**
- Only two priority levels on most CUDA drivers — limited expressiveness.
- **No memory isolation** — a Tier A workload can OOM the shared unified-memory pool and kill WBC.
- No SM reservation at all; under sustained Tier A load WBC kernels still queue.
- Kubernetes scheduler has no insight into partitioning; can't represent "WBC needs X% SM" as a resource request.
- Harder to enforce in multi-tenant / GitOps-driven config — it's an application convention, not a platform guarantee.

**Fit:**
- Tier A: good.
- Tier B: good.
- Tier C: acceptable only if Tier A is strictly off during RT operation (mode-switched).

---

### Approach 4 — Time-slicing via device plugin (not recommended, included for completeness)

NVIDIA device plugin's `sharing.timeSlicing.replicas` advertises multiple logical GPUs that are actually time-shared at the driver level.

**Pros:** simplest config change.
**Cons:** time-slicing means Tier C can be suspended for Tier A's kernel execution — directly incompatible with 500 Hz RT. Reject.

---

## 4. Comparison matrix

| Dimension | Approach 1 (MPS) | Approach 2 (Hybrid) | Approach 3 (Priorities) | Approach 4 (Time-slicing) |
|-----------|------------------|---------------------|-------------------------|---------------------------|
| Tier C jitter control | Soft | **Hard** | Soft (priority only) | **Worst** |
| Memory isolation | Yes (partitioned) | Yes (partitioned) | None | Partial |
| k8s-native scheduling | Yes | Yes | No | Yes |
| App code changes | None | WBC only | All GPU apps | None |
| Operational maturity | High | Low–medium | High | High |
| Fits GitOps config model | Yes | Yes | Weak | Yes |
| Risk if assumption fails | Tier C misses deadline | WBC falls back to Approach 1 | Tier C starved under load | Obvious failure |
| Recommended? | As interim | **Target** | Fallback | No |

---

## 5. Proposed architecture

Two-phase plan:

**Phase 1 — Approach 1 (all-MPS) as validation scaffolding.**
Stand up device plugin with MPS, confirm three pods at different SM caps can run concurrently, benchmark Tier C jitter under Tier A/B load. This tells us whether MPS-soft-caps are already sufficient (they might be, at 500 Hz). Cheap to reverse.

**Phase 2 — Approach 2 (hybrid) if Phase 1 doesn't hit WBC deadlines.**
Add Green Context partitioning inside the WBC container, keep the rest on MPS.

CPU-side configuration is the same for both phases:

```yaml
# excerpt: k0s worker profile for Thor
spec:
  workerProfiles:
    - name: thor-rt
      values:
        cpuManagerPolicy: static
        topologyManagerPolicy: single-numa-node
        memoryManagerPolicy: Static
        reservedSystemCPUs: "0,1"       # system + DaemonSets
        kubeReserved:
          cpu: "500m"
          memory: "1Gi"
        systemReserved:
          cpu: "500m"
          memory: "1Gi"
```

Kernel-side (outside k0s, tracked separately):
- `isolcpus=<WBC cores>`, `nohz_full=<same>`, `rcu_nocbs=<same>` in boot cmdline.
- PREEMPT_RT kernel.
- IRQ affinity pinned off WBC cores.

Pod shape for WBC (Phase 2):

```yaml
spec:
  priorityClassName: rt-critical
  containers:
    - name: wbc
      resources:
        requests:
          cpu: "4"
          memory: "4Gi"
          nvidia.com/gpu: 4     # 4 MPS slices = 40% SM (soft floor)
        limits:
          cpu: "4"
          memory: "4Gi"
          nvidia.com/gpu: 4
      env:
        - name: WBC_GREEN_CTX_SM_COUNT
          value: "<computed from Thor SM count>"
```

---

## 6. Risks & open questions

| # | Risk | Impact | Mitigation |
|---|------|--------|------------|
| R1 | MPS not stable on Thor iGPU | Phase 1 blocked | Validate on dev kit before committing; fallback = Approach 3 temporarily. |
| R2 | Green Contexts unavailable / buggy on Thor | Phase 2 blocked | Keep Approach 1 as long-term if MPS meets jitter budget; alternative = move WBC off GPU where possible. |
| R3 | Unified memory pressure from Tier A evicts/thrashes Tier C working set | WBC latency spikes | Hard memory limits on Tier A pods; consider `mlock` for WBC buffers. |
| R4 | `isolcpus` cores not honored by kubelet static policy | CPU pinning ineffective | Verify via `/sys/fs/cgroup/.../cpuset.cpus.effective` on a running WBC pod; adjust `reservedSystemCPUs` to exclude iso cores. |
| R5 | MPS daemon failure takes down all GPU pods on node | Whole-robot outage | Health check + auto-restart DaemonSet; treat MPS daemon as tier-0 infra. |
| R6 | NVIDIA device plugin arm64 Jetson image lags upstream | Missing features / bugs | Pin known-good tag; subscribe to NVIDIA Jetson channel. |
| R7 | Green Context + MPS interaction under-documented | Unknown failure modes | Reproduce in isolation before integrating; capture CUDA trace. |
| R8 | Thor SM count assumed but not confirmed | Partition math wrong | Read from `nvidia-smi` / `deviceQuery` on first boot (see AI-6). |

---

## 7. Action items — assumption validation

Ordered by dependency. Each item is small (≤ 1 day) and has a clear pass/fail.

### Pre-work (information gathering)

- [ ] **AI-1** — Confirm Thor does not support MIG. Check NVIDIA Thor datasheet + JetPack release notes. *Owner: TBD. Pass: documented statement either way.*
- [ ] **AI-2** — Confirm MPS is supported on Thor's JetPack build. `nvidia-cuda-mps-control -d` on dev kit; verify no errors, verify client process can attach. *Pass: two dummy CUDA processes run concurrently with distinct `CUDA_MPS_ACTIVE_THREAD_PERCENTAGE` values.*
- [ ] **AI-3** — Confirm CUDA ≥ 12.4 on JetPack for Thor; verify Green Context API. Small C++ program calling `cuDevSmResourceSplitByCount` on device 0. *Pass: split succeeds, both resources report expected SM counts.*
- [ ] **AI-4** — Identify the device-plugin image tag that supports MPS on arm64 Jetson. Check NVIDIA GPU Operator Jetson profile release notes. *Pass: tag + Helm values documented in this repo.*
- [ ] **AI-5** — Confirm k0s worker profile accepts `memoryManagerPolicy: Static` (not all k8s distros wire this). *Pass: kubelet logs show memory manager active.*
- [ ] **AI-6** — Record Thor actual SM count, VRAM/unified memory capacity, CUDA version, driver version. *Pass: values committed to `docs/research/thor-hardware-facts.md`.*

### Phase 1 validation (Approach 1 — MPS)

- [ ] **AI-7** — Deploy NVIDIA device plugin on a Thor dev kit with `sharing.mps.replicas = 10`. *Pass: `nvidia.com/gpu: 10` advertised on the node.*
- [ ] **AI-8** — Run three stress pods (A: sustained LLM inference; B: 10 Hz DinoVL-like load; C: 500 Hz GPU kernel loop). Measure Tier C kernel-launch-to-completion latency p50/p99/p99.9 under (i) idle, (ii) B-only load, (iii) A+B load. *Pass: collect numbers; no verdict yet.*
- [ ] **AI-9** — Compare Tier C latency budget (TBD — needs WBC timing budget from control team) against measurements in AI-8. *Pass: decision to continue with Approach 1 or escalate to Approach 2.*
- [ ] **AI-10** — Verify CPU pinning end-to-end: inspect `cpuset.cpus.effective` for Guaranteed pod; run cyclictest (or equivalent) inside the WBC container. *Pass: no cross-core scheduling observed; cyclictest p99 < budget.*

### Phase 2 validation (Approach 2 — Hybrid)

- [ ] **AI-11** — Build a minimal WBC-shaped container that initialises a Green Context at startup. *Pass: container starts, Green Context reports correct SM count, kernels execute on it.*
- [ ] **AI-12** — Run the Phase 1 contention test (AI-8) again with WBC using Green Context inside an MPS slice. *Pass: Tier C p99.9 meets budget under A+B load.*
- [ ] **AI-13** — Chaos test: kill MPS daemon mid-run, force Tier A OOM, saturate PCIe/memory bus. Document recovery behavior. *Pass: documented failure modes + recovery times.*

### Deployment wiring

- [ ] **AI-14** — Commit k0s worker profile + device-plugin Helm values + sample pod manifests to this repo under `manifests/base/thor-rt/`. *Pass: `kubectl apply` + `k0sctl apply` produces the intended runtime state on a clean Thor.*
- [ ] **AI-15** — Document the GitOps path: which ArgoCD Application owns this, rollback procedure. *Pass: runbook page.*
- [ ] **AI-16** — Pre-flight check script: verifies MPS daemon running, isolcpus honored, CUDA version, device plugin resources advertised. Run as a k0s worker startup gate. *Pass: script committed + wired to systemd unit.*

### Decision gates

- **Gate 1** (after AI-1 … AI-6): Do hardware facts support the hybrid plan? If MPS or Green Contexts are unavailable on Thor, re-plan before Phase 1.
- **Gate 2** (after AI-9): Does Approach 1 meet WBC deadlines? If yes, skip Phase 2.
- **Gate 3** (after AI-13): Is Approach 2's chaos behavior acceptable? If no, pursue WBC-on-CPU fallback.

---

## 8. Out-of-scope follow-ups

- PREEMPT_RT kernel packaging for Thor (separate track — owner: OS team).
- Multi-Thor / multi-robot orchestration (cluster-level, not covered here).
- Observability: per-SM utilisation metrics, MPS client metrics — needs a separate design doc.
- GPU-direct IO for sensors feeding Tier C — likely material for a companion doc.

---

## 9. References

- NVIDIA CUDA MPS documentation
- CUDA 12.4 release notes — Green Contexts
- k0s documentation — worker profiles, kubelet config
- NVIDIA GPU Operator — Jetson profile
- Kubernetes docs — CPU Manager (static policy), Topology Manager, Memory Manager
- (links to be added once AI-1…AI-4 produce authoritative URLs)
