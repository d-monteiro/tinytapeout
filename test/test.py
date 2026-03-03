# SPDX-FileCopyrightText: © 2026 Duarte Monteiro
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles

# Weight table: WEIGHTS[post][pre] — 8×8, RP2040 streams these
WEIGHTS = [
    [ 0,  0,  0,  0,  0,  0,  0,  0],   # into neuron 0
    [10,  0,  0,  0,  0,  0,  0,  0],   # into neuron 1: weight 10 from neuron 0
    [ 0,  0,  0,  0,  0,  0,  0,  0],   # into neuron 2
    [ 0,  0,  0,  0,  0,  0,  0,  0],   # into neuron 3
    [ 0,  0,  0,  0,  0,  0,  0,  0],   # into neuron 4
    [ 0,  0,  0,  0,  0,  0,  0,  0],   # into neuron 5
    [ 0,  0,  0,  0,  0,  0,  0,  0],   # into neuron 6
    [ 0,  0,  0,  0,  0,  0,  0,  0],   # into neuron 7
]

FSM_PERIOD = 88  # 11 states × 8 neurons


async def do_reset(dut):
    dut.rst_n.value  = 0
    dut.ena.value    = 1
    dut.ui_in.value  = 0
    dut.uio_in.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)


async def weight_driver(dut, weight_table, ext_spike_mask=0):
    """
    Mimics the RP2040 PIO weight streaming.

    Samples uio_out on the falling edge (after all NBA settle) to read
    in_accum, neuron_idx, and syn_idx, then drives ui_in accordingly.

    During ACCUM:     ui_in[3:0] = weight[neuron][syn], ui_in[7:4] = 0
    Outside ACCUM:    ui_in[7:0] = ext_spike_mask (latched at S_LATCH/neuron0)
    """
    while True:
        await FallingEdge(dut.clk)

        uio_val  = int(dut.uio_out.value)
        in_accum = (uio_val >> 1) & 0x1   # uio_out[1]
        neuron_n = (uio_val >> 2) & 0x7   # uio_out[4:2]
        syn_s    = (uio_val >> 5) & 0x7   # uio_out[7:5]

        if in_accum:
            dut.ui_in.value = weight_table[neuron_n][syn_s] & 0xF
        else:
            dut.ui_in.value = ext_spike_mask & 0xFF


# =========================================================
# Test 1: FSM neuron sequencing
# =========================================================

@cocotb.test()
async def test_neuron_sel_cycles(dut):
    """All 8 neurons must appear on neuron_sel within one FSM period."""
    clock = Clock(dut.clk, 20, units="ns")
    cocotb.start_soon(clock.start())
    await do_reset(dut)

    seen = set()
    for _ in range(FSM_PERIOD + 12):
        await RisingEdge(dut.clk)
        n = (int(dut.uio_out.value) >> 2) & 0x7   # uio_out[4:2]
        seen.add(n)

    assert seen == {0, 1, 2, 3, 4, 5, 6, 7}, \
        f"Not all neurons seen in neuron_sel: {seen}"
    dut._log.info("neuron_sel cycles through all 8 neurons OK")


# =========================================================
# Test 2: External spike injection
# =========================================================

@cocotb.test()
async def test_ext_spike_injection(dut):
    """External spike on neuron 0 must appear on spikes[0] output."""
    clock = Clock(dut.clk, 20, units="ns")
    cocotb.start_soon(clock.start())
    await do_reset(dut)

    zero_weights = [[0] * 8 for _ in range(8)]
    cocotb.start_soon(weight_driver(dut, zero_weights, ext_spike_mask=0b00000001))

    spike_seen = False
    for _ in range(FSM_PERIOD * 3):
        await RisingEdge(dut.clk)
        if int(dut.uo_out.value) & 0x1:
            spike_seen = True
            break

    assert spike_seen, "Neuron 0 spike never appeared — ext injection broken"
    dut._log.info("External spike injection on neuron 0 OK")


# =========================================================
# Test 3: Weight-driven spike propagation
# =========================================================

@cocotb.test()
async def test_weight_propagation(dut):
    """
    Repeated ext spike on neuron 0 must cause neuron 1 to spike via weight.
    WEIGHTS[1][0] = 10, THRESHOLD = 40 → neuron 1 needs ~11 passes to spike.
    """
    clock = Clock(dut.clk, 20, units="ns")
    cocotb.start_soon(clock.start())
    await do_reset(dut)

    cocotb.start_soon(weight_driver(dut, WEIGHTS, ext_spike_mask=0b00000001))

    n1_spikes = 0
    for _ in range(FSM_PERIOD * 50):
        await RisingEdge(dut.clk)
        if int(dut.uo_out.value) & 0x2:   # spikes[1]
            n1_spikes += 1

    dut._log.info(f"Neuron 1 spike count over 50 passes: {n1_spikes}")
    assert n1_spikes > 0, "Weight propagation failed — neuron 1 never spiked"
