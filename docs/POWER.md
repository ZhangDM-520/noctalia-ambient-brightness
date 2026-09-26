# als-brightness — power reference (P0–P4 study, 2026-09-26)

Measured on the reference machine (Ryzen AI 9 HX 370, OLED eDP-1) against the
post-refactor working tree (912 checks / 0 failures, uncommitted). Harness and
raw evidence live in `~/Workspace/als-power/` (not in this repo). Confidence
labels: **measured** = numbers below, **extrapolated** = reasoned from them,
**unknown** = not captured.

## 1. Meter verdicts (P0) — measured

| Meter | Verdict | Evidence |
|---|---|---|
| RAPL `intel-rapl:0/energy_uj` (root-only) | **promoted** | vs turbostat over identical spans: idle 3.95 vs 3.95 W (0.0 %), load 30.68 vs 30.67 W (+0.03 %) |
| `turbostat -q -S -d -i 1` interval mode | **promoted** (cross-check) | command mode emits one summary row only; `--dump` is gone |
| USB-C current meter | **dropped** | UCSI `current_now` = static PD contract (3 250 000 µA), zero movement across a 26 W load step |
| `perf power/energy-pkg/` | **dropped** | EINVAL unprivileged even after retry; root reads the same RAPL MSR |

Align every analysis window to turbostat spans: ±1 s loose edges produced +8.6 %
error against the exact-span 0.0 %.

## 2. Protocol — reproducible

`sampler.sh` (1 Hz RAPL + GPU W + backlight + dpms + battery + load + temp, drift-free
1 Hz deadlines, governor pinned `powersave` with EXIT/INT/TERM/HUP restore),
`event-meter.sh` (2 s RAPL integration around one command), `spark-trace.sh`
(20 Hz transient traces), `p1-gate.sh` (quiet-machine gate: no heavy process,
load1 < 2.5; real-pollution rejection via per-window turbostat Busy% > 15 rows).
A/A windows are verdict-graded (`ok`, `DRIFT_*`, `LOAD_POLLUTED`, `BUSY_POLLUTED`,
`TOO_SHORT`, `BAD_DPMS`, `BAD_BAT`) and rejected ones kept under `p1-rejected/`.

A/B uses **ABBA** (A = plugin enabled, B = disabled, 50 s blocks, 25 s washouts)
because the machine drifts thermally after boot — an A/A run minutes after boot
was rejected twice (DRIFT_TEMP +6 °C, DRIFT_W 10.5→12.0 W). ABBA cancels linear
drift; only the settled pair may be read.

## 3. Reference numbers (2026-09-26, display on, low backlight) — measured

| Quantity | Value | Source |
|---|---|---|
| Package power, settled (any plugin state) | **3.59–3.62 W** | B1/B2/A2 block means |
| 1 Hz sample sigma, settled rows | **≈ 0.22 W** | pooled settled-block rows |
| 2 s idle energy (integrator baseline) | **7.140 ± 0.053 J** (≈ 3.57 W) | 4× noop event windows |
| First-block GPU transient | up to +13.6 W GPU spike | A1 block (compositor/run-start work) |

Panel-blank (S2) sigma: **not captured** (protocol trimmed for OLED on-time;
the killed s2-w1 window is incomplete). Spark (blank/unblank transient) energy:
**not captured**.

## 4. Plugin cost

* **Steady state: below measurement resolution.** Settled ABBA pair 2:
  A2 − B2 = **−0.026 W** (block sigma 0.22 W). Pair 1 (+1.519 W) is contaminated
  by a GPU burst at run start (A1 GPU 4.0→13.6 W) and must not be read as plugin
  cost. The 1 Hz tick + stabilize + curve evaluation + guard chain is
  energetically invisible next to the platform floor.
* **Single-shot event costs** (2 s RAPL windows, 4 reps, minus noop baseline):

| Event | Cost (mean ± sd) | Above 3σ bar (0.158 J)? |
|---|---|---|
| `config-reload` (incl. colortemp splice, double-reload) | **+0.47 ± 0.44 J** | yes |
| plugin disable | **+0.63 ± 0.46 J** | yes |
| plugin enable (probe + curve build + write) | **+0.21 ± 0.17 J** | yes (marginal) |
| backlight write (`brightnessctl set`) | **−0.02 ± 0.06 J** | **no — invisible** |

## 5. 3-sigma scanner rule

* A 1 Hz sample deviating **> 0.66 W** (3 × 0.22 W) from the settled state mean
  marks a candidate event worth explaining.
* A 2 s integrated window deviating **> 0.16 J** (3 × 0.053 J) from the noop
  baseline marks a real event cost.
* **Optimization candidates must exceed these bars.** As of this study exactly
  two do:
  1. the `config-reload` path (the colortemp splice double-reload documented in
     DESIGN §6.1) — the only recurring event with a repeatable cost;
  2. plugin disable/enable churn — only relevant if updates/reloads become
     frequent.
  Explicitly **not** candidates: the tick loop, heartbeat logging, brightness
  writes (all below noise).

## 6. Deviations from the full protocol

Decided live (2026-09-26, user, OLED burn-in concern): S1 dedicated sigma
windows and the spark cycle were dropped; the A/A window attempts made before
that decision were honestly rejected by the drift verdicts (evidence kept).
Consequences: state sigmas come from settled ABBA rows and noop windows rather
than dedicated A/A windows; S2 sigma and spark energies remain unmeasured;
event table is n=4. A future full run should restore S2 windows + 3 spark
cycles overnight.
