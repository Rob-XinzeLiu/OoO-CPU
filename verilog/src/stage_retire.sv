`include "sys_defs.svh"
module stage_retire(
    input logic clock,
    input logic reset,
    //from rob
    input  RETIRE_PACKET    [`N-1:0]            rob_commit_pack,  
    output FL_RETIRE_PACKET [`N-1:0]            freelist_pack  ,
    output SQ_PACKET                            store_retire_pack [`N-1:0],
    output logic                                load_retire_valid,
    output logic [1:0]                          load_retire_num,
    output RETIRE_PACKET    [`N-1:0]            commit_pack,
    output logic                                stall_fetch
);
    logic retiring_halt;
    always_comb begin
        commit_pack       = '0;
        retiring_halt     = 1'b0;
        freelist_pack     = '0;
        store_retire_pack = '{default:'0};
        load_retire_num   = '0;
        load_retire_valid = '0;

        if(rob_commit_pack[0].valid) begin
            if(rob_commit_pack[0].halt) begin
                commit_pack[0] = rob_commit_pack[0];
                retiring_halt  = 1'b1;
            end else if(rob_commit_pack[1].valid) begin
                commit_pack[0] = rob_commit_pack[0];
                commit_pack[1] = rob_commit_pack[1];

                freelist_pack[0].valid     = rob_commit_pack[0].has_dest;
                freelist_pack[0].t_old     = rob_commit_pack[0].t_old;
                store_retire_pack[0].valid    = rob_commit_pack[0].is_store;
                store_retire_pack[0].sq_index = rob_commit_pack[0].sq_index;
                if (rob_commit_pack[0].is_load) load_retire_num += 2'd1;

                if(rob_commit_pack[1].halt) begin
                    retiring_halt = 1'b1;
                end else begin
                    freelist_pack[1].valid     = rob_commit_pack[1].has_dest;
                    freelist_pack[1].t_old     = rob_commit_pack[1].t_old;
                    store_retire_pack[1].valid    = rob_commit_pack[1].is_store;
                    store_retire_pack[1].sq_index = rob_commit_pack[1].sq_index;
                    if (rob_commit_pack[1].is_load) load_retire_num += 2'd1;
                end
            end else begin
                commit_pack[0] = rob_commit_pack[0];
                freelist_pack[0].valid     = rob_commit_pack[0].has_dest;
                freelist_pack[0].t_old     = rob_commit_pack[0].t_old;
                store_retire_pack[0].valid    = rob_commit_pack[0].is_store;
                store_retire_pack[0].sq_index = rob_commit_pack[0].sq_index;
                if (rob_commit_pack[0].is_load) load_retire_num += 2'd1;
            end
        end

        load_retire_valid = (load_retire_num != '0);
    end
    
    logic halt_retired_reg;
    always_ff @(posedge clock) begin
        if(reset) begin
            halt_retired_reg <= 1'b0;
        end else if (retiring_halt) begin
            halt_retired_reg <= 1'b1;
        end
    end

    assign stall_fetch = halt_retired_reg;
endmodule