# SPDX-FileCopyrightText: © 2026 Duarte Monteiro
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, Timer

# =========================================================
# Weight table: WEIGHTS[post_neuron][pre_neuron]
# WEIGHTS[n][i] = synaptic strength from neuron i → neuron n
# Weights are held by RP2040; presented on ui_in[3:0] during ACCUM states
# =========================================================
WEIGHTS = [
    [ 0,  0,  0,  0],   # into neuron 0
    [10,  0,  0,  0],   # into neuron 1: weight 10 from neuron 0
    [ 0,  0,  0,  0],   # into neuron 2
    [ 0,  0,  0,  0],   # into neuron 3
]

FSM_PERIOD = 28  # 7 states × 4 neurons


# =========================================================
# Helpers
# =========================================================

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
    Background task that mimics the RP2040 PIO weight streaming.

    Reads neuron_sel and syn_sel from chip outputs after each clock edge,
    then immediately drives the correct weight on ui_in[3:0] so it is
    stable before the next rising edge.

    ui_in[7:4] = ext_spike_mask  (held constant throughout)
    ui_in[3:0] = weight[neuron][syn] when in_accum=1, else 0
    """
    while True:
        await RisingEdge(dut.clk)
        await Timer(1, units="ns")   # let combinatorial outputs settle

        in_accum = (int(dut.uo_out.value) >> 6) & 0x1
        neuron_n = (int(dut.uo_out.value) >> 4) & 0x3
        syn_s    = (int(dut.uio_out.value) >> 5) & 0x3

        w = weight_table[neuron_n][syn_s] if in_accum else 0
        dut.ui_in.value = ((ext_spike_mask & 0xF) << 4) | (w & 0xF)


# =========================================================
# Test 1: FSM neuron sequencing
# =========================================================

@cocotb.test()
async def test_neuron_sel_cycles(dut):
    """All 4 neurons must appear on neuron_sel within one FSM period."""
    clock = Clock(dut.clk, 20, units="ns")  # 50 MHz
    cocotb.start_soon(clock.start())
    await do_reset(dut)

    seen = set()
    for _ in range(FSM_PERIOD + 4):
        await RisingEdge(dut.clk)
        n = (int(dut.uo_out.value) >> 4) & 0x3
        seen.add(n)

    assert seen == {0, 1, 2, 3}, f"Not all neurons seen in neuron_sel: {seen}"
    dut._log.info("neuron_sel cycles through all 4 neurons OK")


# =========================================================
# Test 2: External spike injection
# =========================================================

@cocotb.test()
async def test_ext_spike_injection(dut):
    """External spike on neuron 0 must appear on spikes[0] output."""
    clock = Clock(dut.clk, 20, units="ns")
    cocotb.start_soon(clock.start())
    await do_reset(dut)

    zero_weights = [[0] * 4 for _ in range(4)]
    cocotb.start_soon(weight_driver(dut, zero_weights, ext_spike_mask=0b0001))

    spike_seen = False
    for _ in range(FSM_PERIOD * 3):
        await RisingEdge(dut.clk)
        if int(dut.uo_out.value) & 0x1:   # spikes[0]
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
    WEIGHTS[1][0] = 10, THRESHOLD = 40 → neuron 1 needs ~4 passes to spike.
    """
    clock = Clock(dut.clk, 20, units="ns")
    cocotb.start_soon(clock.start())
    await do_reset(dut)

    cocotb.start_soon(weight_driver(dut, WEIGHTS, ext_spike_mask=0b0001))

    n1_spikes = 0
    for _ in range(FSM_PERIOD * 50):
        await RisingEdge(dut.clk)
        if int(dut.uo_out.value) & 0x2:   # spikes[1]
            n1_spikes += 1

    dut._log.info(f"Neuron 1 spike count over 50 passes: {n1_spikes}")
    assert n1_spikes > 0, "Weight propagation failed — neuron 1 never spiked"
