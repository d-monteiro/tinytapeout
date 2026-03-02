# NeuroPulse — Design Document

## System Overview

Two chips on the same PCB:

```
RP2040 (125 MHz)                    Chip / Tapeout (50 MHz)
─────────────────                   ───────────────────────
- Holds ALL weights                 - Holds V_mem[0..3]
- Streams weights in sync           - Holds pre_trace[0..3]
- Injects external spikes           - Holds post_trace[0..3]
- Reads spike outputs               - Runs FSM
- Manages larger virtual nets       - Computes LIF + Hebbian
```

The chip is a **4-neuron neural compute engine**.
Weights are NOT stored on chip — the RP2040 owns them.
The chip is stateful only about membrane potential and traces.

---

## Why weights off-chip?

Transistor budget: **2000T hard limit**

| Component            | Bits | ~Transistors |
|----------------------|------|-------------|
| V_mem  (6b × 4)      |  24  |     576     |
| trace (3b × 4)       |  12  |     288     |
| Accumulator (8b)     |   8  |     192     |
| FSM + counters       |  ~8  |     192     |
| Spike regs (4b)      |   4  |      96     |
| ext_spikes (4b)      |   4  |      96     |
| Combinational logic  |  —   |    ~400     |
| **TOTAL**            |      |  **~1840**  |

> One trace per neuron (not separate pre/post). Saves 12 FFs = ~288T.

Weights on-chip (4b × 16 synapses = 64 FFs) would add **1,536T** — blowing the budget.

> Bit widths are a starting point. They will be tuned iteratively.

---

## Neuron Model (LIF)

```
Every update cycle, for neuron N:
  leak     = vmem[N] - (vmem[N] >> 2)        // V * 0.75, shift-only
  vmem[N]  = leak + weighted_input
  if vmem[N] >= THRESHOLD:
      spike[N] = 1
      vmem[N]  = 0
  else:
      spike[N] = 0
```

Weighted input = Σ( weight[N][i] × spike[i] ) for i = 0..3
Weights come from RP2040 on input pins, one per cycle during ACCUM phase.

---

## Hebbian Learning (LTP only)

```
On each neuron update:
  if spike[N]:
      post_trace[N] = POST_TRACE_MAX   // reset to full
  else:
      post_trace[N] = post_trace[N] - 1  (if > 0)   // decay

  if spike[i]:  (for each pre-synaptic neuron i)
      pre_trace[i] = PRE_TRACE_MAX
  else:
      pre_trace[i] = pre_trace[i] - 1   (if > 0)

  if pre_trace[i] > 0 AND post_trace[N] > 0:
      weight[N][i] += 1  (saturating)    // LTP, RP2040 applies this
```

The chip signals when LTP should occur (outputs `ltp_pulse` + which synapse).
The RP2040 increments the weight in its own memory.

---

## FSM — Per-neuron sequence

The FSM processes neurons **one at a time**, 7 cycles each:

```
State       Cycles   Action
─────────────────────────────────────────────────────────
LATCH         1      Capture ui_in[7:4] as ext_spike[3:0]
TRACE         1      Update pre/post traces for neuron N
ACCUM_0       1      Read weight[N][0] from pins, accumulate spike[0]*w
ACCUM_1       1      Read weight[N][1], accumulate spike[1]*w
ACCUM_2       1      Read weight[N][2], accumulate spike[2]*w
ACCUM_3       1      Read weight[N][3], accumulate spike[3]*w
THRESHOLD     1      Apply threshold, generate spike, reset vmem if fired
─────────────────────────────────────────────────────────
Total: 7 cycles × 4 neurons = 28 cycles per full network pass
```

At 50 MHz and 100 Hz biological refresh:
- Need: 28 cycles × 100 passes = 2,800 cycles/second
- Available: 50,000,000 cycles/second
- **Utilization: 0.006% — massive headroom**

---

## Pin Mapping

```
ui_in[3:0]   ← weight data from RP2040 (valid during ACCUM states)
ui_in[7:4]   ← external spike injection (latched during LATCH state)

uo_out[3:0]  → spike outputs (one per neuron, registered)
uo_out[5:4]  → neuron_sel[1:0] (which neuron is active — for RP2040 sync)
uo_out[7:6]  → syn_sel[1:0] (which synapse is being accumulated)

uio_in[0]    ← learn_ena (Hebbian on/off)
uio_in[1]    ← (reserved)
uio_in[7:2]  ← (reserved)

uio_out[3:0] → vmem[5:2] of current neuron (top 4 bits, debug)
uio_out[4]   → ltp_pulse (1 when LTP should fire, RP2040 increments weight)
uio_out[6:5] → ltp_neuron[1:0] (which post-synaptic neuron)
uio_out[7]   → (reserved)

uio_oe = 8'b1111_1110  // uio_in[0] is input, rest output
```

---

## RP2040 Interface Protocol

The FSM is **deterministic** — the RP2040 knows exactly which weight is needed at each chip cycle:

```
Chip cycle:   ... LATCH | TRACE | ACCUM_0 | ACCUM_1 | ACCUM_2 | ACCUM_3 | THRESH ...
RP2040 drives:          |       | w[N][0] | w[N][1] | w[N][2] | w[N][3] |
```

RP2040 uses **PIO** to stream weights in order — no GPIO reaction time needed.
It pre-loads the 16 weights for the upcoming pass into a PIO TX FIFO.

On `ltp_pulse`: RP2040 increments `weight[ltp_neuron][ltp_synapse]` in its table,
then re-loads the PIO FIFO for the next pass.

---

## Source Files

| File              | Role                                      |
|-------------------|-------------------------------------------|
| `src/project.v`   | Top-level, pin mapping, instantiates FSM  |
| `src/neuron.v`    | Datapath: leak, accumulate, threshold     |
| `test/test.py`    | cocotb testbench                          |
| `test/Makefile`   | Simulation config                         |
| `src/DESIGN.md`   | This file                                 |

---

## Implementation Order

1. [ ] Rewrite `neuron.v` — pure datapath, no internal state, inputs driven by FSM
2. [ ] Rewrite `project.v` — FSM controller + register file (vmem, traces)
3. [ ] Update `test/test.py` — test FSM sequence + spike propagation
4. [ ] Verify transistor count after synthesis
5. [ ] Tune bit widths if over budget
6. [ ] Document RP2040 firmware interface (separate doc)
