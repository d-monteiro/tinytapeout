`default_nettype none

// Pure combinational datapath — no state, no clock.
// The FSM in project.v owns all registers and drives these ports.
module neuron_datapath (
    // Accumulation path (used during S_ACCUM_0..3)
    input  wire [7:0] accum_in,
    input  wire [3:0] weight,     // from RP2040 via ui_in[3:0]
    input  wire       pre_spike,  // spike[syn_idx] from previous pass
    output wire [7:0] accum_out,

    // Threshold path (used during S_THRESH)
    // accum_in is reused here — holds full weighted sum at thresh time
    input  wire [5:0] vmem_in,
    input  wire [5:0] threshold,
    output wire       spike_out,
    output wire [5:0] vmem_out
);

    // Accumulate: add weighted pre-synaptic spike to running sum
    assign accum_out = accum_in + (pre_spike ? {4'b0, weight} : 8'b0);

    // Threshold: leak membrane, fold in accumulated input, compare
    wire [5:0] leak     = vmem_in - (vmem_in >> 2);   // V * 0.75 (shift-only)
    wire [7:0] vmem_sum = {2'b0, leak} + accum_in;    // may exceed 6 bits

    assign spike_out = (vmem_sum >= {2'b0, threshold});
    assign vmem_out  = spike_out      ? 6'd0              // reset on spike
                     : |vmem_sum[7:6] ? 6'h3F             // saturate at 63
                     :                  vmem_sum[5:0];    // normal update

endmodule
