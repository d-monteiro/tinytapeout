`default_nettype none

// Pure combinational datapath — no state, no clock.
module neuron_datapath (
    input  wire [7:0] accum_in,
    input  wire [3:0] weight,
    input  wire       pre_spike,
    output wire [7:0] accum_out,

    input  wire [7:0] vmem_in,    // 8-bit
    input  wire [7:0] threshold,  // 8-bit
    output wire       spike_out,
    output wire [7:0] vmem_out    // 8-bit
);

    assign accum_out = accum_in + (pre_spike ? {4'b0, weight} : 8'b0);

    wire [7:0] leak     = vmem_in - (vmem_in >> 2);        // V * 0.75
    wire [8:0] vmem_sum = {1'b0, leak} + {1'b0, accum_in}; // 9-bit, max 312

    assign spike_out = (vmem_sum >= {1'b0, threshold});
    assign vmem_out  = spike_out   ? 8'd0              // reset on spike
                     : vmem_sum[8] ? 8'hFF             // saturate at 255
                     :               vmem_sum[7:0];    // normal update

endmodule
