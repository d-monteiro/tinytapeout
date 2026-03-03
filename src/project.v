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
    localparam THRESHOLD = 8'd40;   // fire when vmem >= 40

    // FSM states — 11 per neuron, 8 neurons = 88 cycles per pass
    localparam S_LATCH   = 4'd0;
    localparam S_TRACE   = 4'd1;
    localparam S_ACCUM_0 = 4'd2;
    localparam S_ACCUM_1 = 4'd3;
    localparam S_ACCUM_2 = 4'd4;
    localparam S_ACCUM_3 = 4'd5;
    localparam S_ACCUM_4 = 4'd6;
    localparam S_ACCUM_5 = 4'd7;
    localparam S_ACCUM_6 = 4'd8;
    localparam S_ACCUM_7 = 4'd9;
    localparam S_THRESH  = 4'd10;

    // =========================================================
    // State registers
    // =========================================================
    reg [7:0] vmem  [0:7];   // membrane potential, 8-bit (0-255)
    reg [2:0] trace [0:7];   // activity trace, 3-bit (0-7)
    reg [7:0] spikes;        // spike outputs, one per neuron
    reg [7:0] accum;         // weighted-sum accumulator
    reg [3:0] state;         // 4-bit FSM state
    reg [2:0] neuron_idx;    // 3-bit neuron index 0-7
    reg [7:0] ext_spikes;    // external spike injection, full byte from ui_in

    // =========================================================
    // Derived signals
    // =========================================================
    // in_accum: high during S_ACCUM_0..S_ACCUM_7 (states 2-9)
    wire in_accum = (state >= S_ACCUM_0) && (state <= S_ACCUM_7);

    // syn_idx: maps ACCUM states 2-9 → synapse indices 0-7
    // 3-bit subtraction wraps correctly for states 8 (→6) and 9 (→7)
    wire [2:0] syn_idx = state[2:0] - 3'd2;

    wire learn_ena = uio_in[0];
    wire _unused = &{uio_in[7:1], 1'b0};

    // =========================================================
    // Datapath instantiation
    // =========================================================
    wire [7:0] accum_out;
    wire       spike_out;
    wire [7:0] vmem_out;

    neuron_datapath datapath (
        .accum_in  (accum),
        .weight    (ui_in[3:0]),
        .pre_spike (spikes[syn_idx]),
        .accum_out (accum_out),
        .vmem_in   (vmem[neuron_idx]),
        .threshold (THRESHOLD),
        .spike_out (spike_out),
        .vmem_out  (vmem_out)
    );

    // =========================================================
    // Outputs
    // =========================================================
    assign uo_out[7:0] = spikes;        // all 8 spike outputs

    assign uio_out[0]   = 1'b0;         // uio[0] is input direction
    assign uio_out[1]   = in_accum;     // RP2040 weight-write gate
    assign uio_out[4:2] = neuron_idx;   // which neuron is active
    assign uio_out[7:5] = syn_idx;      // which synapse (valid when in_accum=1)

    assign uio_oe = 8'b1111_1110;       // uio[0] = learn_ena input, rest outputs

    // =========================================================
    // FSM
    // =========================================================
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_LATCH;
            neuron_idx <= 3'd0;
            accum      <= 8'd0;
            spikes     <= 8'd0;
            ext_spikes <= 8'd0;
            for (i = 0; i < 8; i = i + 1) begin
                vmem[i]  <= 8'd0;
                trace[i] <= 3'd0;
            end

        end else if (ena) begin
            case (state)

                S_LATCH: begin
                    // Latch all 8 external spikes from ui_in once per pass (neuron 0 only)
                    if (neuron_idx == 3'd0)
                        ext_spikes <= ui_in[7:0];
                    accum <= 8'd0;
                    state <= S_TRACE;
                end

                S_TRACE: begin
                    if (spikes[neuron_idx])
                        trace[neuron_idx] <= 3'd7;
                    else if (trace[neuron_idx] > 0)
                        trace[neuron_idx] <= trace[neuron_idx] - 3'd1;
                    state <= S_ACCUM_0;
                end

                S_ACCUM_0, S_ACCUM_1, S_ACCUM_2, S_ACCUM_3,
                S_ACCUM_4, S_ACCUM_5, S_ACCUM_6, S_ACCUM_7: begin
                    accum <= accum_out;
                    state <= state + 4'd1;
                end

                S_THRESH: begin
                    spikes[neuron_idx] <= spike_out | ext_spikes[neuron_idx];
                    vmem[neuron_idx]   <= vmem_out;
                    neuron_idx <= (neuron_idx == 3'd7) ? 3'd0 : neuron_idx + 3'd1;
                    state      <= S_LATCH;
                end

                default: state <= S_LATCH;

            endcase
        end
    end

endmodule
