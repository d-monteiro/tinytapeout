/*
 * Copyright (c) 2026 Duarte Monteiro
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_d_monteiro (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    // =========================================================
    // Parameters
    // =========================================================
    localparam THRESHOLD = 6'd40;   // fire when vmem >= 40
    localparam TRACE_MAX = 3'd7;    // trace saturates at 7

    // FSM states — 7 per neuron, 4 neurons = 28 cycles per pass
    localparam S_LATCH   = 3'd0;    // latch ext_spikes from RP2040
    localparam S_TRACE   = 3'd1;    // decay / reset trace for this neuron
    localparam S_ACCUM_0 = 3'd2;    // accumulate spike[0] * weight[n][0]
    localparam S_ACCUM_1 = 3'd3;    // accumulate spike[1] * weight[n][1]
    localparam S_ACCUM_2 = 3'd4;    // accumulate spike[2] * weight[n][2]
    localparam S_ACCUM_3 = 3'd5;    // accumulate spike[3] * weight[n][3]
    localparam S_THRESH  = 3'd6;    // apply threshold, emit spike

    // =========================================================
    // State registers
    // =========================================================
    reg [5:0] vmem  [0:3];   // membrane potential, 6-bit (0-63)
    reg [2:0] trace [0:3];   // activity trace, 3-bit (0-7)
    reg [3:0] spikes;        // spike outputs, one per neuron
    reg [7:0] accum;         // weighted-sum accumulator for current neuron
    reg [2:0] state;
    reg [1:0] neuron_idx;
    reg [3:0] ext_spikes;    // external spike injection, latched from ui_in[7:4]

    // =========================================================
    // Derived signals
    // =========================================================
    // in_accum: high during S_ACCUM_0..3 — tells RP2040 to present weight
    wire in_accum = (state >= S_ACCUM_0) && (state <= S_ACCUM_3);

    // syn_idx: which pre-synaptic input we are accumulating (0-3)
    // Maps S_ACCUM_0..3 (states 2-5) → syn_idx 0-3 via XOR
    wire [1:0] syn_idx = state[1:0] ^ 2'b10;

    wire learn_ena = uio_in[0];
    wire _unused = &{uio_in[7:1], 1'b0};

    // =========================================================
    // Datapath instantiation
    // =========================================================
    wire [7:0] accum_out;
    wire       spike_out;
    wire [5:0] vmem_out;

    neuron_datapath datapath (
        .accum_in  (accum),
        .weight    (ui_in[3:0]),        // RP2040 presents weight here during ACCUM
        .pre_spike (spikes[syn_idx]),   // spike from pre-synaptic neuron
        .accum_out (accum_out),
        .vmem_in   (vmem[neuron_idx]),
        .threshold (THRESHOLD),
        .spike_out (spike_out),
        .vmem_out  (vmem_out)
    );

    // =========================================================
    // Outputs
    // =========================================================
    // ltp_pulse: fires when neuron spikes with learning enabled
    // RP2040 watches this and increments weights where trace[i] > 0
    wire ltp_pulse = learn_ena && spike_out && (state == S_THRESH);

    assign uo_out[3:0] = spikes;       // spike outputs for all 4 neurons
    assign uo_out[5:4] = neuron_idx;   // which neuron is active (for RP2040 sync)
    assign uo_out[6]   = in_accum;     // high during ACCUM — RP2040 must present weight
    assign uo_out[7]   = ltp_pulse;    // Hebbian learning trigger

    assign uio_out[3:0] = vmem[neuron_idx][5:2];  // top 4 bits of current vmem (debug)
    assign uio_out[4]   = 1'b0;
    assign uio_out[6:5] = syn_idx;     // which synapse (valid when in_accum=1)
    assign uio_out[7]   = 1'b0;

    assign uio_oe = 8'b1111_1110;      // uio[0] is input (learn_ena), rest outputs

    // =========================================================
    // FSM
    // =========================================================
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_LATCH;
            neuron_idx <= 2'd0;
            accum      <= 8'd0;
            spikes     <= 4'd0;
            ext_spikes <= 4'd0;
            for (i = 0; i < 4; i = i + 1) begin
                vmem[i]  <= 6'd0;
                trace[i] <= 3'd0;
            end

        end else if (ena) begin
            case (state)

                S_LATCH: begin
                    // Latch external spikes once per full pass (at neuron 0)
                    if (neuron_idx == 2'd0)
                        ext_spikes <= ui_in[7:4];
                    accum <= 8'd0;
                    state <= S_TRACE;
                end

                S_TRACE: begin
                    // Update trace for this neuron only
                    if (spikes[neuron_idx])
                        trace[neuron_idx] <= TRACE_MAX;
                    else if (trace[neuron_idx] > 0)
                        trace[neuron_idx] <= trace[neuron_idx] - 3'd1;
                    state <= S_ACCUM_0;
                end

                S_ACCUM_0, S_ACCUM_1, S_ACCUM_2, S_ACCUM_3: begin
                    // RP2040 must have weight[neuron_idx][syn_idx] on ui_in[3:0]
                    accum <= accum_out;
                    state <= state + 3'd1;
                end

                S_THRESH: begin
                    // OR in external spike injection alongside computed spike
                    spikes[neuron_idx] <= spike_out | ext_spikes[neuron_idx];
                    vmem[neuron_idx]   <= vmem_out;
                    // Advance to next neuron
                    neuron_idx <= (neuron_idx == 2'd3) ? 2'd0 : neuron_idx + 2'd1;
                    state      <= S_LATCH;
                end

                default: state <= S_LATCH;

            endcase
        end
    end

endmodule
