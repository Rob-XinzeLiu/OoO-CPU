`include "sys_defs.svh"

module stage_retire(
    input logic clock,
    input logic reset,
    //from rob
    input  RETIRE_PACKET   [`N-1:0]     rob_commit_pack,  

    output FL_RETIRE_PACKET [`N-1:0] freelist_pack  ,//to freelist
    output RETIRE_PACKET  [`N-1:0] commit_pack,//to tb
    output logic           stall_fetch  //to fetch stage 
);

    logic retiring_halt;

    always_comb begin
        commit_pack    = '0;
        retiring_halt  = 1'b0;
        freelist_pack = '0;

        if(rob_commit_pack[0].valid) begin
            if(rob_commit_pack[0].halt) begin
                // if pack[0] is halt, only retire pack[0]
                commit_pack[0] = rob_commit_pack[0];
                retiring_halt  = 1'b1;

            end else if(rob_commit_pack[1].valid) begin
                // pack[0] is not halt，pack[1] is valid
                commit_pack[0] = rob_commit_pack[0];
                commit_pack[1] = rob_commit_pack[1];
                freelist_pack[0].valid = rob_commit_pack[0].has_dest;
                freelist_pack[0].t_old = rob_commit_pack[0].t_old;
                
                if(rob_commit_pack[1].halt) begin
                    retiring_halt = 1'b1;
                end else begin
                    freelist_pack[1].valid = rob_commit_pack[1].has_dest;
                    freelist_pack[1].t_old = rob_commit_pack[1].t_old;
                end

            end else begin
                // pack[0] is not halt，pack[1] is not valid， only retire pack[0]
                commit_pack[0] = rob_commit_pack[0];
                freelist_pack[0].valid = rob_commit_pack[0].has_dest;
                freelist_pack[0].t_old = rob_commit_pack[0].t_old;

            end
        end
    end
    
    logic halt_retired_reg;

    always_ff @(posedge clock) begin
        if(reset) begin
            halt_retired_reg <= 1'b0;
        end else if (retiring_halt) begin//latch halt signal until reset
            halt_retired_reg <= 1'b1;
        end
    end

assign stall_fetch = halt_retired_reg;


endmodule