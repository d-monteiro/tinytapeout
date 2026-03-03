# NeuroPulse v2 — Design Document (8 neurons, 1×1 tile)

## What changed vs v1

| | v1 | v2 |
|---|---|---|
| Neurons | 4 | **8** |
| vmem precision | 6-bit (0–63) | **8-bit (0–255)** |
| FSM states/neuron | 7 | **11** |
| Cycles/pass | 28 | **88** |
| state register | 3-bit | **4-bit** |
| neuron_idx | 2-bit | **3-bit** |
| syn_idx | 2-bit | **3-bit** |
| spikes output | uo_out[3:0] only | **uo_out[7:0] all 8** |
| Tile | 1×2 | **1×1** |
| ~Transistors | ~1840T (10% of 1×2) | **~3400T (37% of 1×1)** |
| Passes/second @50MHz | ~1.78M | **~568K** |

## Architecture

```
RP2040 (125 MHz)                    Chip (50 MHz)
─────────────────                   ──────────────────────
- Holds weights[8][8] (64 values)  - vmem[0..7]  (8-bit each)
- Streams weights via PIO           - trace[0..7] (3-bit each)
- Injects ext_spikes[7:0]          - spikes[7:0]
- Derives LTP from uo_out timing   - 11-state FSM × 8 neurons
```

## FSM (11 states × 8 neurons = 88 cycles/pass)

| State | Value | Action |
|-------|-------|--------|
| S_LATCH | 4'd0 | Capture ui_in[7:0] → ext_spikes (neuron 0 only) |
| S_TRACE | 4'd1 | Decay/reset trace for this neuron |
| S_ACCUM_0..7 | 4'd2..9 | Accumulate spike[i] × weight[N][i] |
| S_THRESH | 4'd10 | Apply threshold, emit spike, reset vmem |

## Key formulas

```verilog
// syn_idx: 3-bit subtraction wraps for states 8→syn6, 9→syn7
wire [2:0] syn_idx = state[2:0] - 3'd2;

// in_accum: states 2-9
wire in_accum = (state >= 4'd2) && (state <= 4'd9);

// 9-bit sum needed: max leak(192) + max accum(120) = 312
wire [8:0] vmem_sum = {1'b0, leak} + {1'b0, accum_in};
```

## Pin mapping

```
ui_in[3:0]  ← weight[N][syn] from RP2040 (during ACCUM states)
ui_in[7:0]  ← ext_spikes[7:0] (latched at S_LATCH when neuron_idx==0)

uo_out[7:0] → spikes[7:0]   — all 8 spike outputs

uio[0]      ← learn_ena     (INPUT)
uio_out[1]  → in_accum      (RP2040 weight-write gate)
uio_out[4:2]→ neuron_idx[2:0]
uio_out[7:5]→ syn_idx[2:0]  (valid when in_accum=1)

uio_oe = 8'b1111_1110
```

**ltp_pulse removed** — RP2040 samples uo_out[N] during the S_THRESH cycle for neuron N (deterministic timing).

## Transistor budget

```
vmem  8×8-bit  = 64 FFs = 1536T
trace 8×3-bit  = 24 FFs =  576T
spikes 8-bit   =  8 FFs =  192T
ext_spikes     =  8 FFs =  192T
accum          =  8 FFs =  192T
state (4-bit)  =  4 FFs =   96T
neuron_idx(3b) =  3 FFs =   72T
combinational              ~500T
─────────────────────────────────
TOTAL                   ~3,356T   (37% of 1×1 tile ~9000T)
```

## RP2040 interface changes

- Weight table: `uint8_t weights[8][8]` (was [4][4])
- in_accum signal: now on `uio_out[1]` (was `uo_out[6]`)
- neuron_idx: now on `uio_out[4:2]` 3-bit (was `uo_out[5:4]` 2-bit)
- syn_idx: now on `uio_out[7:5]` 3-bit (was `uio_out[6:5]` 2-bit)
- ltp_pulse: removed, derive from uo_out[N] at S_THRESH timing
- ext spikes: full `ui_in[7:0]` byte (was only `ui_in[7:4]`)
