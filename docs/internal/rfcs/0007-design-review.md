# RFC 0007 Adversarial Design Review — Synthesis

**Reviewer:** Principal engineer (synthesis of six verified lenses)
**Subject:** `docs/internal/rfcs/0007-fleet-ota-and-hierarchical-config.md`
**Companion read:** `docs/internal/rfcs/0006-local-git-as-argo-source.md`
**Verdict basis:** only `real-gap` and `partially-addressed` findings used as substance.

---

## 1. Executive summary

RFC 0007 is a **well-reasoned, internally coherent delivery design** with strong bones. It preserves RFC 0006's air-gap property (every cross-boundary arrow is robot-initiated), cleanly splits the network-facing puller from the privileged OS-writer so neither compromise alone is fatal, and correctly makes config↔image atomicity the load-bearing correctness property — enforced by the gated two-step. The authors are notably self-aware: §13 openly files the health-check question, and §3 flags host-config authz for security review. That honesty is the document's best feature and the right place to push.

The design is solid for **"does one config bundle land safely."** It is weak-to-absent on the three things that decide whether this is a *cutting-edge, safe humanoid-fleet product*:

1. **No behavioral safety gate.** The first time a new locomotion policy or state-estimator meets physics is on a real, possibly weight-bearing humanoid. There is no sim gate before the fleet, and §13's proposed post-apply floor is liveness-level — which, by the RFC's own example, does not catch a state-estimator publishing NaNs or a policy outputting garbage.
2. **Auto-rollback is not actually transactional.** The "uses only local state" promise is hollow: the N-1 rollback target's container images can be GC'd (offline `ImagePullBackOff`), the revert restarts RT/locomotion/SE pods with no safe-state gate (can topple a robot the bad apply destabilized), and a power-loss mid-apply leaves the unproven version live with no intent journal or watchdog.
3. **The riskiest substrate is uncovered.** Kernel / k0s / containerd / the baked cosign key are entirely outside the OTA and rollback story — the exact layer that crash-looped robots in this fleet's own history (unpinned `get.k0s.sh` → k0s 1.36/containerd 2.x).

On security, cosign authenticity is real, but the trust model sits **one tier below the automotive/Uptane bar** the product should target: it collapses Uptane's two decisions (authentic vs. which-version-for-me), leaves the Desired-State API a fully-trusted online Director, has no anti-rollback floor, no freshness anchor, no key rotation/revocation without a reflash, no SLSA provenance, and no secret-management story. None defeat cosign; together a single online-service or CI-credential compromise can stall the fleet, pin every robot to a stale-but-signed vulnerable version, or cross-pin one customer's config onto another's robots.

Fleet orchestration (canary/bake/halt semantics, metric-driven delivery, telemetry substrate, fleet query/drift, recall) is **asserted but unspecified**. Some legitimately lives in named sibling workstreams, but the RFC must own the semantics and trigger hooks for properties it itself relies on as safety guarantees.

**Net:** a strong delivery channel, an incomplete safety system, and a security model below the bar a humanoid fleet should meet.

### What is already strong (keep)
- **Air-gap preservation** — robot-initiated poll/pull/report; no inbound surface (R1, §12).
- **Privilege split** — network pod can't write `/opt`; OS-writer has no inbound net; compromise of one ≠ robot.
- **Config↔image atomicity** via the gated two-step (§11) — the right correctness anchor.
- **Single privileged applier** for both OTA and host-config (§3) — one gate, one audit log; the right shape (it just needs to be made explicitly single-flight and crash-safe).
- **Self-awareness** — §13 and §3 flag the two hardest problems instead of papering over them.

---

## 2. Top must-fix critical gaps (most important first)

### G1 — Behavioral safety gate is missing; the functional health gate is open at the wrong altitude
Integrity gates (cosign, image-pairing) prove *the bytes are present*, not *the robot behaves*. There is no sim/digital-twin validation between render and a physical robot, and §13's proposed fixed floor (`RT/EtherCAT liveness, API-server reachable`) does not cover the NaN/garbage cases the RFC itself names.
- **Add a CI sim gate**: run the bundle's exact image digests in the existing ABI-locked containerized sim; replay standing/locomotion/disturbance scenarios; emit a **signed sim-evidence attestation** in `meta.json`; `fleetctl promote` refuses safety-critical bundles lacking it. Frame as **necessary, not sufficient** (this fleet's noise-free sim cannot reproduce the raw-vs-filtered-gyro OOD class).
- **Reframe the immutable floor as numeric bounded-correctness**: SE finite/within physical bounds (covers the RFC's own NaN example, which "liveness" does not), control torque within saturation, RT deadline met **with margin**, EtherCAT all-OP, IMU variance in-band. Bundles may ADD checks, never lower the floor.
- **Mandate a safe-posture watch window**: limp/sit/damped-stand with small **NON-ZERO** gains (FIR-460 limp; Novanta CSP drives ignore zero gains), then graduate to weight-bearing only after the floor passes.

### G2 — Auto-rollback is not transactional and can itself drop the humanoid
R6's "never strand the robot" promise fails in four concrete, compounding ways:
- **GC'd rollback images** — §11 pins only the *forward* digests; nothing pins N-1, so containerd/kubelet GC evicts exactly the layers a revert needs, on the explicitly-targeted tiny-disk robots → offline `ImagePullBackOff`.
- **Unsafe revert** — the revert re-reconciles and **restarts EtherCAT/locomotion/SE pods**; §13's safe-state gate is forward-only, so a revert can topple a robot the bad apply already destabilized.
- **Crash mid-apply** — a power loss between `commit HEAD` and the health verdict reboots into the unproven vN with no watcher and no intent journal.
- **Torn git commit** — no fsync/fsck/atomic-rename; a torn `.git` defeats the revert path (same object store).

**Fix:** pin current+N-1(+N-2) digests (containerd lease / kubelet pinned-images); make "rollback images present" a **precondition of revert** (else SAFE-PARK + page); apply the **same safe-state gate** to the revert path; add a durable **apply-intent journal** replayed on every boot (fold in boot-time `git fsck`); run the System Service under `systemd Restart=always + WatchdogSec`; make the rollback target **last-known-GOOD**, not merely `HEAD~1`; add a **free-space precondition** to the apply gate.

### G3 — No OS/kernel/k0s/containerd update or rollback path
The §7 "A/B" is git-HEAD over manifests and cannot recover a broken kernel/k0s/containerd (it presupposes a healthy node + cluster). `minOSVersion` in `meta.json` is decorative — nothing advances the OS. This is the fleet's own historical crash-loop class.
- **Cheap, must-have for this RFC:** a "substrate coverage" subsection naming what OTA does NOT cover (kernel, RT patch, k0s, containerd, baked cosign key, the two OTA binaries) and the honest current recovery story (root SSH + reflash, not fleet-scalable).
- **Program-level (sibling RFC):** dual-partition image-based OS updates (flash inactive slot, set next-boot, boot-success gate, bootloader auto-fallback) — the only rollback that survives a broken kernel — with `minOSVersion` gating/triggering the OS tier first. Prior art: ChromeOS update_engine, Android A/B, Mender/RAUC, balenaOS HUP.

### G4 — Supply-chain trust collapses Uptane's two decisions into one online authority
The Desired-State API answers "which version for this robot?" with no signature over the targeting decision; there is no anti-rollback floor, no freshness anchor, no key rotation/revocation without a reflash, and no provenance. Realistic blast radius (cosign still blocks *unsigned* code): redirect-to-any-validly-signed-bundle, downgrade-to-known-bad, freeze, cross-tenant pin, fleet stall.
**Fix as one hardening package, built on one metadata root:**
- Sign the **targeting assertion** with an **offline Director-role key** distinct from the CI/Targets key, bound to the robot's locked identity (ideally SPIFFE/x509 SVID).
- Persist a **monotonic anti-rollback version floor** in the A/B state; downgrade becomes an explicitly-authorized operation (root SSH + bootstrap tier), never silent.
- Add **signed `notBefore`/`notAfter`** freshness to `meta.json`.
- Add a minimal **TUF-style root** that rotates the signing key over the OTA channel (no reflash) + a **revocation list**; record signatures in **Rekor** (or adopt keyless).
- Emit and verify **SLSA L3** build provenance (source repo + `meta.json` source SHA + builder identity) as in-toto; make §2 step-3 **promotion a separate signed approval** distinct from the CI key.

### G5 — Fleet rollout orchestration and its telemetry substrate are asserted, not specified
The RFC promises canary tiers and "auto-roll-back and halt the rollout" but never defines **halt** for a pull fleet, has no bake-time/failure-rate threshold (Model 2's "24h" is prose), no metric-driven progressive delivery, no cross-robot version-skew bound, and no **fleet recall** for a functionally-bad bundle that passes every local gate. The telemetry these depend on is a dotted arrow with no TSDB/OTLP/SLI substrate; there is no fleet-query/drift primitive.
**Own the semantics in this RFC** (precise "halt", canary-promotion signal contract, per-wave failure-rate budget, inter-stack compatibility ranges, a "mark vN bad" recall robots honor on next poll even after committing); **define the OTLP-over-store-and-forward telemetry substrate** (reuse §8's bounded-queue/idempotency, no inbound dependency); **defer only controller internals** to the named sibling RFC.

---

## 3. Cross-cutting themes

| Theme | Why it matters | Representative findings |
|---|---|---|
| Behavioral safety unproven before/during contact | Integrity ≠ behavior; first physics encounter is on real hardware; the post-apply probe is open and liveness-level; matches this fleet's SE/gyro fall history | `sim-gate-before-fleet`, `functional-rt-health-gate`, `health-check-floor-rt-coupling`, `ml-policy-first-class-artifact` |
| "Auto-rollback uses only local state" is not transactional | The failure handler is less robust than the failure it handles; offline-unrecoverable on air-gapped robots | `rollback-image-gc`, `rollback-not-actually-transactional`, `system-service-self-watchdog`, `torn-git-commit`, `disk-full-staging-apply` |
| Supply chain one tier below the Uptane/SLSA bar | A single online/CI compromise → fleet-wide stall, downgrade, cross-tenant pin — without defeating cosign | `directory-image-split-collapsed`, `no-anti-rollback-uptane`, `key-lifecycle-rotation-revocation`, `no-provenance-attestation-slsa`, `offline-cosign-tuf-expiry` |
| OTA channel exists; fleet-ops brain does not | A modern fleet is judged on safely moving thousands of robots; semantics + telemetry the RFC leans on are undefined | `fleet-rollout-orchestration-semantics`, `no-automated-canary-analysis`, `telemetry-pipeline-undefined`, `stuck-rollout-and-fleet-recall` |
| Concurrency / consistency / GitOps substrate under-specified | Two writers race the same HEAD; doc contradicts itself (robot vs robot+stack); no render-validation or reproducibility; inherited 0006 hazards unre-examined | `two-writers-opt-etc`, `selfheal-vs-apply-race`, `kustomize-component-cascade-pitfalls`, `desired-state-data-model-missing`, `file-hostpath-argocd-upgrade-coupling` |
| Multi-tenancy & data flywheel left on the table | Multi-customer product with asserted-not-designed isolation; "push" half shipped without the "learn" half | `multi-tenancy-underspecified`, `per-robot-leaf-build-explosion`, `data-flywheel`, `cloud-plane-gitops-and-dx` |

---

## 4. Phased roadmap (Now / Next / Later)

### Now — close physical-safety holes and the false-transactional rollback (blocks weight-bearing fleet OTA)
- Numeric bounded-correctness floor (§13) — SE finiteness/bounds, torque saturation, RT deadline margin, EtherCAT OP, IMU variance.
- Mandatory safe-posture watch window (limp/sit, small non-zero gains) before load.
- Same safe-state gate on the **revert** path (HOLD + page if unsafe).
- Pin current+N-1 images; "rollback images present" precondition of revert; rollback target = last-known-GOOD.
- Durable apply-intent journal + boot-time replay + `git fsck`; System Service under `Restart`+`WatchdogSec`.
- Free-space precondition on the apply gate.
- Explicit single-flight applier (flock) across OTA apply / revert / host-config; `refs/phantomos/last-good`.
- "Substrate coverage" subsection naming the uncovered OS/k0s/containerd/key layers + honest recovery story.

### Next — raise the supply chain to the Uptane/SLSA bar; own rollout semantics
- CI sim-gate + signed sim-evidence attestation (necessary-not-sufficient, paired with on-robot floor).
- Offline Director key on the targeting assertion (bound to locked identity); monotonic anti-rollback floor; signed freshness.
- One TUF-style root: reflash-free key rotation + revocation list + Rekor; SLSA L3 provenance verified at apply; separate signed promotion.
- CI render-validation gate; pinned kustomize/kubectl recorded in `meta.json`; no-plaintext-secrets path (SOPS/External Secrets) bound to per-node identity.
- Rollout semantics in-RFC (halt definition, canary signal contract, per-wave failure budget, inter-stack compatibility ranges, fleet recall).
- OTLP telemetry substrate over store-and-forward; canonical SLI list; cloud TSDB — no inbound dependency.
- Resolve robot-vs-(robot,stack) contradiction; declarative server-side Rollout resource + optimistic concurrency; periodic on-robot re-attestation; validate file:// `refresh:hard` cache-bust + hostPath survival across Argo upgrades; short threat-model + blast-radius table.

### Later — differentiate as a cutting-edge embodied-AI fleet platform
- First-class ML policy artifact + obs/action-space compatibility gate (blocks the documented gyro OOD fall class) + shadow-mode + matched-robot A/B.
- Metric-driven progressive delivery (rings + canary-vs-baseline auto-analysis) + named deploy SLOs + error-budget promotion freeze.
- Per-(robot,stack) versioning so the high-churn policy canaries independently of the RT plane.
- Data flywheel: episode-capture hooks on rollback/SE-breach/fall → outbound → sibling retraining → back through render→sim-gate→sign→OTA.
- Multi-tenancy hardening (per-customer registry namespaces, CODEOWNERS on `layers/global`, API-layer tenant RBAC, partitioned telemetry/audit).
- Declarative git-backed cloud fleet-intent + pre-approval preview (diff + image delta + sim attestation) + OPA promotion guardrails + per-robot timeline with one-click revert.
- Optional site-local pull-through mirror (untrusted, cosign-verified per robot); thin ML-weight OCI layers; tamper-evident end-to-end audit store for per-tenant compliance.

---

## 5. Highest-leverage cutting-edge bets

1. **Behavioral safety gate as the signature feature** — CI sim-gate with a *signed* attestation + an on-robot bounded-correctness floor evaluated in a damped/limp posture. "We proved it walks in sim and proved it doesn't NaN on-robot before it bore weight" vs. "we signed it and pods went Ready." Sim is necessary-not-sufficient; the on-robot floor is the backstop.
2. **Policies as first-class ML artifacts with an obs-space compatibility gate** — cheaply and directly blocks the documented walking-forward-fall OOD failure (raw gyro into a filtered-gyro-trained policy produced a "Healthy" pod that toppled) that no signature can see.
3. **Uptane-in-miniature + SLSA L3 as one package** — offline Director key, monotonic anti-rollback floor, signed freshness, reflash-free TUF root, verified provenance. Moves from "authentic content" to "authentic, fresh, monotonic, attested, aimed-at-me," keeping cosign as the floor.
4. **Data flywheel built into the deploy channel** — reserve edge episode-capture hooks on the events the design already emits (rollback, SE-breach, fall) → outbound store-and-forward → sibling retraining → back through the same pipeline. Turns a config pusher into a closed-loop embodied-AI improvement engine.
5. **Metric-driven progressive delivery + fleet-recall kill-switch** — expanding rings, automated canary-vs-baseline analysis on real SLIs, auto-pause on statistically significant regression, and a fleet-wide "mark vN bad" robots honor even after committing. The defining capability of a state-of-the-art fleet platform.

---

## 6. Notes on scope and double-counting

- Several findings legitimately straddle the RFC's stated scope boundary (Area 4 portals, factory flows, OS `.deb` distribution). The consistent ask is **own the semantics/contract here, defer only the internals** — and *name* the boundary so an uncovered layer is intentional, not silent (the `substrate-coverage`, `fleet-query/drift`, and `desired-state-data-model` findings all turn on this).
- `no-deploy-slos-error-budget` and `fleet-health-scoring-anomaly` substantially overlap the canary + telemetry findings and should be implemented as the **governance/analysis layer on top**, not tracked as independent gaps.
- `no-threat-model` is a meta-finding: its standalone value is the **blast-radius table** that would have surfaced the Director / CI-key / OS-baked-key single points of failure in the body of the RFC.
