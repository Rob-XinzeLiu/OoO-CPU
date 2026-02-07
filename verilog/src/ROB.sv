`include "sys_defs.svh"
module ROB(
    input logic clock,
    input logic reset,
    input logic [1:0] dispatched_inst_cnt,//from dispatch
    input logic  mispredicted,
    input ROB_IDX mispredicted_index,
    input PRF_IDX t_from_freelist [`N-1:0],
    input PRF_IDX told_from_mt [`N-1:0],
    input X_C_PACKET cdb [`N-1:0],// add a cdb packet
    //input ADDR pc,
    //input logic [2:0] fu_type,//we can seperate it into logic   is_store; is_load; is_wfi
    input REG_IDX  dest_reg_in [`N-1:0],
    //input rob complete index
    //input rob recover index(the tail/rob index when the mispredicted branch was dispatched into ROB)
    //there should be a dispatch to issue packet, and this will at least be the input of rob and rs 
    //there should be a retire packet, this will be the output of rob
    //we should output head and tail pointers for debug purpose, also for branch revovery
    //output logic ready_dispatch,//replace with space avail
    output PRF_IDX told_to_freelist [`N-1:0],//retire
    output PRF_IDX t_to_amt [`N-1:0],//retire
    output REG_IDX  dest_reg_out [`N-1:0],//to AMT
    output ROB_CNT space_avail,//to dispatch
    output ROB_IDX rob_index [`N-1:0]
);

    typedef struct packed {
        ADDR    pc;
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
    ROB_IDX tail_ptr, next_tail_ptr;// let tail pointer point to next free slot
    ROB_CNT rob_count, next_rob_count;//how many entries used
    //retire
    logic retire_1, retire_2;
    assign retire_1 = (rob_array[head_ptr].ready_retire && !rob_array[head_ptr + 1 ].ready_retire);
    assign retire_2 = (rob_array[head_ptr].ready_retire && rob_array[head_ptr + 1 ].ready_retire );
    assign rob_index[0] = tail_ptr;
    assign rob_index[1] = tail_ptr + 1'b1;

    //function for branch recovery
    // function automatic logic is_younger(ROB_IDX current_idx, ROB_IDX head, ROB_IDX tail);
    //     if(head < tail) begin
    //         return current_idx < tail && current_idx >= head;
    //     end else begin
    //         return current_idx >= head || current_idx < tail;
    //     end
    // endfunction
///////////////////////////////////////////////////////////////////////
//////////////////////                         ////////////////////////
//////////////////////  Combinational Logic    ////////////////////////
//////////////////////                         ////////////////////////
///////////////////////////////////////////////////////////////////////
    always_comb begin
        //default
        next_head_ptr = head_ptr;
        next_tail_ptr = tail_ptr;
        next_rob_count = rob_count;
        next_rob_array = rob_array;
///////////////////////////////////////////////////////////////////////
//////////////////////                         ////////////////////////
//////////////////////      Commit(Retire)     ////////////////////////
//////////////////////                         ////////////////////////
///////////////////////////////////////////////////////////////////////

        if(retire_2)begin
            for(int i = 0; i < `N; ++i)begin
                told_to_freelist[i] = rob_array[head_ptr+i].told;
                t_to_amt[i] = rob_array[head_ptr+i].t;
                next_rob_array[head_ptr+i].ready_retire = 1'b0; 
                dest_reg_out[i] = rob_array[head_ptr+i].dest_reg_idx;
            end
            next_head_ptr = head_ptr + 2;
            next_rob_count = rob_count - 2;

        end else if(retire_1)begin
            told_to_freelist[0] = rob_array[head_ptr].told;
            t_to_amt[0] = rob_array[head_ptr].t;
            dest_reg_out[0] = rob_array[head_ptr].dest_reg_idx;
            next_head_ptr = head_ptr + 1;
            next_rob_count = rob_count - 1;
            next_rob_array[head_ptr].ready_retire = 1'b0;
        end else begin
            told_to_freelist    = '{default: '0};
            t_to_amt            = '{default: '0};
            dest_reg_out        = '{default: '0};
        end
       

///////////////////////////////////////////////////////////////////////
//////////////////////                          ///////////////////////
//////////////////////          Complete        ///////////////////////
//////////////////////                          ///////////////////////
///////////////////////////////////////////////////////////////////////

        for(int i = 0; i < `N; i++) begin
            if(cdb[i].valid) begin
                next_rob_array[cdb[i].complete_index].ready_retire = 1'b1;
            end
        end


///////////////////////////////////////////////////////////////////////
//////////////////////                         ////////////////////////
//////////////////////  Mispredict Recovery    ////////////////////////
//////////////////////                         ////////////////////////
///////////////////////////////////////////////////////////////////////
        if(mispredicted) begin
            // ROB_CNT flushed_count = 0;
            // for(int j =0; j < `ROB_SZ; j++) begin
            //     if(is_younger(j, mispred_idx, next_tail_ptr)) begin
            //         next_rob_array[j].valid = 1'b0;
            //         next_rob_array[j].ready_retire = 1'b0;
            //         flushed_count = flushed_count + 1;
            //     end
            // end
            next_tail_ptr = mispredicted_index + 1;
            next_rob_count = ROB_CNT'(ROB_IDX'(mispredicted_index - head_ptr) + 1'b1) ;
        end
///////////////////////////////////////////////////////////////////////
//////////////////////                         ////////////////////////
//////////////////////  space count            ////////////////////////
//////////////////////                         ////////////////////////
///////////////////////////////////////////////////////////////////////
        space_avail = `ROB_SZ - next_rob_count;
///////////////////////////////////////////////////////////////////////
//////////////////////                         ////////////////////////
//////////////////////  Enqueue(Dispatch)      ////////////////////////
//////////////////////                         ////////////////////////
///////////////////////////////////////////////////////////////////////
        if(dispatched_inst_cnt > 0 && !mispredicted) begin              // Just in case that we dispatch when it's mispredicted
            for(int k = 0; k < dispatched_inst_cnt; k++) begin
                // next_rob_array[tail_ptr + k].valid = 1'b1;
                next_rob_array[tail_ptr + k].t = t_from_freelist[k];
                next_rob_array[tail_ptr + k].told = told_from_mt[k];
                next_rob_array[tail_ptr + k].ready_retire = 1'b0;
                // next_rob_array[tail_ptr + k].is_load = (fu_type == 3'b001) ? 1'b1 : 1'b0;
                // next_rob_array[tail_ptr + k].is_store = (fu_type == 3'b010) ? 1'b1 : 1'b0;
                next_rob_array[tail_ptr + k].dest_reg_idx = dest_reg_in[k];
            end
            next_tail_ptr = tail_ptr + dispatched_inst_cnt;             // We need a logic to stop enqueing (maybe in dispatcher)
            next_rob_count = next_rob_count + dispatched_inst_cnt;
        end
    end

///////////////////////////////////////////////////////////////////////
//////////////////////                         ////////////////////////
//////////////////////  Sequential Logic       ////////////////////////
//////////////////////                         ////////////////////////
///////////////////////////////////////////////////////////////////////
    always_ff @(posedge clock) begin
        if (reset) begin
           head_ptr <= '0;
           tail_ptr <= '0;
           rob_count <= '0;
           rob_array <= '{default: '0};
        end
        else begin
           head_ptr <= next_head_ptr;
           tail_ptr <= next_tail_ptr;
           rob_count <= next_rob_count;
           rob_array <= next_rob_array;
        end
    end

    
endmodule 