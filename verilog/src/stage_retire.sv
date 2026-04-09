`include "sys_defs.svh"

module stage_retire(
    input logic clock,
    input logic reset,
    //from rob
    input  RETIRE_PACKET    [`N-1:0]            rob_commit_pack,  
    input logic                                 dcache_filling,
    input logic                                 mshr_currently_waiting,

    output FL_RETIRE_PACKET [`N-1:0]            freelist_pack  ,//to freelist
    output SQ_PACKET                            store_retire_pack       [`N-1:0],//to store queue
    output RETIRE_PACKET    [`N-1:0]            commit_pack,//to tb
    output logic                                stall_fetch  //to fetch stage 
);

    logic retiring_halt;
    logic halt_safe;
    logic halt_waiting;
    logic halt_retired_reg;

    assign halt_safe    = !dcache_filling && !mshr_currently_waiting;

    
    assign halt_waiting =(rob_commit_pack[0].valid && rob_commit_pack[0].halt && !halt_safe) ||
    (rob_commit_pack[1].valid && rob_commit_pack[1].halt && !halt_safe);

    always_comb begin
        commit_pack    = '0;
        retiring_halt  = 1'b0;
        freelist_pack = '0;
        store_retire_pack = '{default:'0};

        if(rob_commit_pack[0].valid) begin
            if(rob_commit_pack[0].halt) begin
                // if pack[0] is halt, only retire pack[0]
                if(halt_safe)begin
                    commit_pack[0] = rob_commit_pack[0];
                    retiring_halt  = 1'b1;

                end
                

            end else if(rob_commit_pack[1].valid) begin
                // pack[0] is not halt，pack[1] is valid
                commit_pack[0] = rob_commit_pack[0];
                //commit_pack[1] = rob_commit_pack[1];
                freelist_pack[0].valid = rob_commit_pack[0].has_dest;
                freelist_pack[0].t_old = rob_commit_pack[0].t_old;
                store_retire_pack[0].valid = rob_commit_pack[0].is_store;
                store_retire_pack[0].sq_index = rob_commit_pack[0].sq_index;
                
                if(rob_commit_pack[1].halt) begin
                    if(halt_safe) begin
                        retiring_halt = 1'b1;
                        commit_pack[1] = rob_commit_pack[1];
                    end
                end else begin
                    commit_pack[1] = rob_commit_pack[1];
                    freelist_pack[1].valid = rob_commit_pack[1].has_dest;
                    freelist_pack[1].t_old = rob_commit_pack[1].t_old;
                    store_retire_pack[1].valid = rob_commit_pack[1].is_store;
                    store_retire_pack[1].sq_index = rob_commit_pack[1].sq_index;
                end

            end else begin
                // pack[0] is not halt，pack[1] is not valid， only retire pack[0]
                commit_pack[0] = rob_commit_pack[0];
                freelist_pack[0].valid = rob_commit_pack[0].has_dest;
                freelist_pack[0].t_old = rob_commit_pack[0].t_old;
                store_retire_pack[0].valid = rob_commit_pack[0].is_store;
                store_retire_pack[0].sq_index = rob_commit_pack[0].sq_index;

            end
        end
    end
    

    always_ff @(posedge clock) begin
        if(reset) begin
            halt_retired_reg <= 1'b0;
        end else if (retiring_halt) begin//latch halt signal until reset
            halt_retired_reg <= 1'b1;
        end
    end

//assign stall_fetch = halt_retired_reg;
assign stall_fetch = halt_retired_reg || halt_waiting;


endmodule