`include "sys_defs.svh"
`include "ROB.svh"
module ROB(
    input logic clock,
    input logic reset,
    input logic [1:0] dispatched_inst_cnt,//from dispatch
    input logic  mispredicted,//from ex stage
    input PRF_IDX mispredicted_tag,
    input PRF_IDX t_from_freelist [`N-1:0],
    input PRF_IDX told_from_mt [`N-1:0],
    input PRF_IDX ready_retire_tag [`N-1:0],
    //input ADDR pc,
    input logic [2:0] fu_type,//we can seperate it into logic   is_store; is_load; is_wfi
    input REG_IDX  dest_reg_idx [`N-1:0],
    input 
    //input rob complete index
    //input rob recover index(the tail/rob index when the mispredicted branch was dispatched into ROB)
    //output space available
    //output dest reg idx to amt
    //there should be a dispatch to issue packet, and this will at least be the input of rob and rs 
    //there should be a retire packet, this will be the output of rob
    //we should output head and tail pointers for debug purpose, also for branch revovery
    output logic ready_dispatch,//replace with space avail
    output logic [`TAG_CNT-1:0] told_to_freelist,//retire
    output logic [`TAG_CNT-1:0] t_to_amt,//retire
    output ROB_CNT space_avail
);

    typedef struct packed {
        ADDR    pc;
        logic   valid;
        PRF_IDX t;
        PRF_IDX told;
        logic ready_retire;//how many inst can we retire per cycle?
        ROB_IDX index;
        logic is_load;
        logic is_store;
        REG_IDX  dest_reg_idx; 
    } ROB_ENTRY;

    ROB_ENTRY rob_array [`ROB_SZ-1:0];
    ROB_ENTRY next_rob_array [`ROB_SZ-1:0];
    ROB_IDX head_ptr, next_head_ptr;
    ROB_IDX tail_ptr, next_tail_ptr;
    ROB_CNT rob_count, next_rob_count;
    ROB_CNT space_avail;

    function automatic logic is_younger(ROB_IDX current_idx, ROB_IDX mispredicted_idx, ROB_IDX tail_ptr);
        if(mispredicted_idx < tail_ptr) begin
            return current_idx < tail_ptr && current_idx > mispredicted_idx;
        end else begin
            return current_idx > mispredicted_idx || current_idx < tail_ptr;
        end
    endfunction

    always_comb begin
        //default
        next_head_ptr = head_ptr;
        next_tail_ptr = tail_ptr;
        next_rob_count = rob_count;
        next_rob_array = rob_array;
        //--------------retire---------
        if(rob_array[head_ptr].valid && rob_array[head_ptr].ready_retire) begin
            told_to_freelist = rob_array[head_ptr].told;
            t_to_amt = rob_array[head_ptr].t;
            next_head_ptr = head_ptr + 1;
            next_rob_count = rob_count - 1;
            next_rob_array[head_ptr].valid = 1'b0; 
            next_rob_array[head_ptr].ready_retire = 1'b0; 
        end
        // else begin
        //     told_to_freelist = '0;
        //     t_to_amt = '0;
        //     next_head_ptr = head_ptr;
        //     next_rob_count = rob_count;  
        // end
        //----------complete
        if(rob_array[head_ptr].t == ready_retire_tag) begin
            next_rob_array[head_ptr].ready_retire = 1'b1;
        end

      

        //mispredict recovery
        if(mispredicted) begin
            ROB_IDX mispred_idx;
            ROB_CNT flushed_count = 0;
            for(int i = 0; i < `ROB_SZ; i++) begin
                if(rob_array[i].t == mispredicted_tag) begin
                    mispred_idx = i;
                end
            end  
            for(int j =0; j < `ROB_SZ; j++) begin
                if(is_younger(j, mispred_idx, next_tail_ptr)) begin
                    next_rob_array[j].valid = 1'b0;
                    next_rob_array[j].ready_retire = 1'b0;
                    flushed_count = flushed_count + 1;
                end
            end
            next_tail_ptr = mispred_idx;
            next_rob_count = next_rob_count - flushed_count;
        end
    //-------------space_count--------------
        space_avail = `ROB_SZ - next_rob_count;
    //-----------------enqueue-----------------
        if(dispatched_inst_cnt > 0) begin
            for(int k = 0; k < dispatched_inst_cnt; k++) begin
                next_rob_array[tail_ptr + k].valid = 1'b1;
                next_rob_array[tail_ptr + k].t = t_from_freelist[k];
                next_rob_array[tail_ptr + k].told = told_from_mt[k];
                next_rob_array[tail_ptr + k].ready_retire = 1'b0;
                // next_rob_array[tail_ptr + k].is_load = (fu_type == 3'b001) ? 1'b1 : 1'b0;
                // next_rob_array[tail_ptr + k].is_store = (fu_type == 3'b010) ? 1'b1 : 1'b0;
                next_rob_array[tail_ptr + k].dest_reg_idx = dest_reg_idx[k];
            end
            next_tail_ptr = tail_ptr + dispatched_inst_cnt;
            next_rob_count = next_rob_count + dispatched_inst_cnt;
        end
   
    end


    always_ff @(posedge clock) begin
        if (reset) begin
           
        end
        else begin
           
        end
    end

    
endmodule 