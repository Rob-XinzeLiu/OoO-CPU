
`include "sys_defs.svh"

// This is a pipelined multiplier that multiplies two 64-bit integers and
// returns the low 64 bits of the result.
// This is not an ideal multiplier but is sufficient to allow a faster clock
// period than straight multiplication.

module mult (
    input logic clock, 
    input logic reset,
    input logic start,
    input DATA rs1, rs2,
    input MULT_FUNC func,
    input PRF_IDX  dest_tag_in,
    input ROB_IDX rob_idx_in,
    input B_MASK  bmask_in,

    input logic       mispredicted,
    input B_MASK      mispredicted_bmask_index,
    input logic       resolved,
    input B_MASK      resolved_bmask_index,

    output B_MASK      bmask_out, 
    output ROB_IDX    rob_idx_out,
    output PRF_IDX dest_tag_out,
    output logic cdb_req_mult,
    output DATA result,
    output logic done
);

    MULT_FUNC [`MULT_STAGES-2:0] internal_funcs;
    MULT_FUNC func_out;
    
    PRF_IDX [`MULT_STAGES-2:0] internal_tags;//wires
    ROB_IDX [`MULT_STAGES-2:0] internal_rob_indexes;//wires
    B_MASK [`MULT_STAGES-2:0] internal_bmasks; //wires

    logic [(64*(`MULT_STAGES-1))-1:0] internal_sums, internal_mcands, internal_mpliers;
    logic [`MULT_STAGES-2:0] internal_dones;

    logic [63:0] mcand, mplier, product;
    logic [63:0] mcand_out, mplier_out; // unused, just for wiring

    assign cdb_req_mult = internal_dones[`MULT_STAGES-2];

    // instantiate an array of mult_stage modules
    // this uses concatenation syntax for internal wiring, see lab 2 slides
    mult_stage mstage [`MULT_STAGES-1:0] (
        .clock                      (clock),
        .reset                      (reset),
        .func                       ({internal_funcs,   func}),
        .start                      ({internal_dones,   start}), // forward prev done as next start
        .prev_sum                   ({internal_sums,    64'h0}), // start the sum at 0
        .mplier                     ({internal_mpliers, mplier}),
        .mcand                      ({internal_mcands,  mcand}),
        .product_sum                ({product,    internal_sums}),
        .next_mplier                ({mplier_out, internal_mpliers}),
        .next_mcand                 ({mcand_out,  internal_mcands}),
        .next_func                  ({func_out,   internal_funcs}),
        .done                       ({done,       internal_dones}), // done when the final stage is done
        .tag_in                     ({internal_tags, dest_tag_in}),
        .tag_out                    ({dest_tag_out, internal_tags}),
        .rob_in                     ({internal_rob_indexes, rob_idx_in}),
        .rob_out                    ({rob_idx_out, internal_rob_indexes}),
        .bmask_in                   ({internal_bmasks, bmask_in}),
        .bmask_out                  ({bmask_out, internal_bmasks}),
        .mispredicted               (mispredicted),
        .mispredicted_bmask_index   (mispredicted_bmask_index),
        .resolved                   (resolved),
        .resolved_bmask_index       (resolved_bmask_index)
    );

    // Sign-extend the multiplier inputs based on the operation
    always_comb begin
        case (func)
            M_MUL, M_MULH, M_MULHSU: mcand = {{(32){rs1[31]}}, rs1};
            default:                 mcand = {32'b0, rs1};
        endcase
        case (func)
            M_MUL, M_MULH: mplier = {{(32){rs2[31]}}, rs2};
            default:       mplier = {32'b0, rs2};
        endcase
    end

    // Use the high or low bits of the product based on the output func
    assign result = (func_out == M_MUL) ? product[31:0] : product[63:32];

endmodule // mult


module mult_stage (
    input logic clock,
    input logic reset, 
    input logic start,
    input [63:0] prev_sum, mplier, mcand,
    input MULT_FUNC func,
    input PRF_IDX  tag_in,
    input ROB_IDX rob_in,
    input B_MASK  bmask_in,
    input logic       mispredicted,
    input B_MASK      mispredicted_bmask_index,
    input logic       resolved,
    input B_MASK      resolved_bmask_index,

    output B_MASK      bmask_out,
    output ROB_IDX    rob_out,
    output PRF_IDX     tag_out,
    output logic [63:0] product_sum, next_mplier, next_mcand,
    output MULT_FUNC next_func,
    output logic done
);

    parameter SHIFT = 64/`MULT_STAGES;

    logic [63:0] partial_product, shifted_mplier, shifted_mcand;

    assign partial_product = mplier[SHIFT-1:0] * mcand;

    assign shifted_mplier = {SHIFT'('b0), mplier[63:SHIFT]};
    assign shifted_mcand = {mcand[63-SHIFT:0], SHIFT'('b0)};
    
    always_ff @(posedge clock) begin
        product_sum <= prev_sum + partial_product;
        next_mplier <= shifted_mplier;
        next_mcand  <= shifted_mcand;
        next_func   <= func;
    end

    B_MASK next_bmask;
    logic next_done;

    always_comb begin
        // resolve first
        next_bmask = resolved ? (bmask_in & ~resolved_bmask_index) : bmask_in;
        // mispredict
        if (mispredicted && |(next_bmask & mispredicted_bmask_index)) begin
            next_bmask = '0;
            next_done  = '0;
        end else begin
            next_done  = start;
        end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            tag_out <= '0;          // on reset, clear tag
            rob_out <= '0;          // on reset, clear ROB index
            bmask_out <= '0;         // on reset, clear bmask
            done <= '0;             // on reset, not done
        end else begin
            tag_out <= tag_in;
            rob_out <= rob_in;
            bmask_out <= next_bmask;
            done      <= next_done;
        end
    end
  

endmodule // mult_stage
