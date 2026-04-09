`include "sys_defs.svh"
module rob(
    input logic                 clock                           ,
    input logic                 reset                           ,
    input D_S_PACKET            dispatch_pack           [`N-1:0],
    input logic [`N-1:0]        is_branch                       ,//from dispatch
    input logic                 mispredicted                    ,//from execute
    input ROB_IDX               rob_tail_in                     ,//from branch stack
    input X_C_PACKET            [`N-1:0]   cdb                  ,//set complete bit
    input COND_BRANCH_PACKET    cond_branch_in                  ,//from execute  
    input SQ_PACKET             sq_in                           ,//from execute   
    input logic                 halt_safe                       ,   

    output RETIRE_PACKET        [`N-1:0] rob_commit             ,//to retire stage
    output logic [1:0]          rob_space_avail                 ,//to dispatch stage
    output ROB_IDX              rob_index               [`N-1:0],//to rs 
    output ROB_IDX              rob_tail_out            [`N-1:0] //to branch stack
);

    typedef struct packed {
        logic           valid;
        PRF_IDX         t;
        PRF_IDX         told;
        logic           ready_retire;//how many inst can we retire per cycle?
        logic           halt;//for tb
        logic           illegal;//for tb
        ADDR            PC;//for debug
        ADDR            NPC;//for debug
        logic           has_dest;//for debug
        REG_IDX         dest_reg_idx;//for debug
        DATA            data;
        logic           is_store;
        LQ_IDX          lq_index;
        SQ_IDX          sq_index;

    } ROB_ENTRY;

    ROB_ENTRY       rob_array           [`ROB_SZ-1:0];
    ROB_ENTRY       next_rob_array      [`ROB_SZ-1:0];
    ROB_IDX         head_ptr, next_head_ptr;
    ROB_IDX         tail_ptr, next_tail_ptr;//tail pointer point to next free slot
    logic           full, full_n;
    ROB_CNT         free_slots;
    logic [1:0]   retire_num; //how many instructions can we retire in this cycle



    //dispatch
    logic           dispatch_1, dispatch_2;
    assign          dispatch_1 = (dispatch_pack[0].valid && !dispatch_pack[1].valid);
    assign          dispatch_2 = (dispatch_pack[0].valid && dispatch_pack[1].valid);


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
        full_n = full;
        next_rob_array = rob_array;
        rob_commit = '0;
        rob_index = '{default: '0};
        rob_tail_out = '{default: '0};
        free_slots = 0;
///////////////////////////////////////////////////////////////////////
//////////////////////                         ////////////////////////
//////////////////////      Commit(Retire)     ////////////////////////
//////////////////////                         ////////////////////////
///////////////////////////////////////////////////////////////////////

        if (head_ptr == tail_ptr && !full) begin
            // ROB empty
            retire_num = 0;
        end else if (!rob_array[head_ptr].valid || !rob_array[head_ptr].ready_retire) begin
            // head is not ready
            retire_num = 0;
        end else if (rob_array[head_ptr].halt && !halt_safe) begin
            // head is halt but not safe
            retire_num = 0;
        end else if (rob_array[head_ptr].halt && halt_safe) begin
            // head is halt and safe， only retire this one
            retire_num = 1;
        end else begin
            // head是普通指令，看head+1
            if (rob_array[ROB_IDX'(head_ptr+1)].valid && 
                rob_array[ROB_IDX'(head_ptr+1)].ready_retire &&
                ROB_IDX'(head_ptr+1) != tail_ptr) begin
                
                if (rob_array[ROB_IDX'(head_ptr+1)].halt && !halt_safe) begin
                    // head+1是halt但不safe，只retire head
                    retire_num = 1;
                end else begin
                    // head+1是普通指令或halt且safe
                    retire_num = 2;
                end
            end else begin
                retire_num = 1;
            end
        end
        

        if(retire_num == 2)begin
            for(int i = 0; i < `N; i++) begin
                rob_commit[i].valid = 1'b1;
                rob_commit[i].halt = rob_array[(head_ptr+i) % `ROB_SZ].halt;
                rob_commit[i].illegal = rob_array[(head_ptr+i) % `ROB_SZ].illegal;
                rob_commit[i].PC = rob_array[(head_ptr+i) % `ROB_SZ].PC;
                rob_commit[i].NPC = rob_array[(head_ptr+i) % `ROB_SZ].NPC;
                rob_commit[i].has_dest = rob_array[(head_ptr+i) % `ROB_SZ].has_dest;
                rob_commit[i].dest_reg_idx = rob_array[(head_ptr+i) % `ROB_SZ].dest_reg_idx;
                rob_commit[i].t_old = rob_array[(head_ptr+i) % `ROB_SZ].told;
                rob_commit[i].data = rob_array[(head_ptr+i) % `ROB_SZ].data;
                rob_commit[i].is_store = rob_array[(head_ptr+i) % `ROB_SZ].is_store;
                rob_commit[i].sq_index = rob_array[(head_ptr+i) % `ROB_SZ].sq_index;
                next_rob_array[(head_ptr+i) % `ROB_SZ].valid = 0;
            end
            next_head_ptr = head_ptr + 2;

        end else if(retire_num == 1)begin
            rob_commit[0].valid = 1'b1;
            rob_commit[0].halt = rob_array[head_ptr].halt;
            rob_commit[0].illegal = rob_array[head_ptr].illegal;
            rob_commit[0].PC = rob_array[head_ptr].PC;
            rob_commit[0].NPC = rob_array[head_ptr].NPC;
            rob_commit[0].has_dest = rob_array[head_ptr].has_dest;
            rob_commit[0].dest_reg_idx = rob_array[head_ptr].dest_reg_idx;
            rob_commit[0].t_old = rob_array[head_ptr].told;
            rob_commit[0].data = rob_array[head_ptr].data;
            rob_commit[0].is_store = rob_array[head_ptr].is_store;
            rob_commit[0].sq_index = rob_array[head_ptr].sq_index;
            next_rob_array[head_ptr].valid = 0;
            next_head_ptr = head_ptr + 1;


        end 

///////////////////////////////////////////////////////////////////////
//////////////////////                          ///////////////////////
//////////////////////          Complete        ///////////////////////
//////////////////////                          ///////////////////////
///////////////////////////////////////////////////////////////////////

        for(int i = 0; i < `N; i++) begin
            if(cdb[i].valid) begin
                next_rob_array[cdb[i].complete_index].ready_retire = 1'b1;
                next_rob_array[cdb[i].complete_index].data = cdb[i].result;
            end
        end

        if(cond_branch_in.valid) begin
                next_rob_array[cond_branch_in.br_rob_idx].ready_retire = 1'b1;
        end

        if(sq_in.valid) begin
                next_rob_array[sq_in.rob_index].ready_retire = 1'b1;
        end


///////////////////////////////////////////////////////////////////////
//////////////////////                         ////////////////////////
//////////////////////  Mispredict Recovery    ////////////////////////
//////////////////////                         ////////////////////////
///////////////////////////////////////////////////////////////////////
        if(mispredicted) begin
            next_tail_ptr = rob_tail_in;
        end else begin


    ///////////////////////////////////////////////////////////////////////
    //////////////////////                         ////////////////////////
    //////////////////////  Enqueue(Dispatch)      ////////////////////////
    //////////////////////                         ////////////////////////
    ///////////////////////////////////////////////////////////////////////
            if(dispatch_1 ) begin   
                next_rob_array[tail_ptr].valid = 1;          
                next_rob_array[tail_ptr].t = dispatch_pack[0].T;
                next_rob_array[tail_ptr].told = dispatch_pack[0].Told;
                next_rob_array[tail_ptr].ready_retire = 1'b0;
                next_rob_array[tail_ptr].halt = dispatch_pack[0].halt;
                next_rob_array[tail_ptr].illegal = dispatch_pack[0].illegal;
                next_rob_array[tail_ptr].PC = dispatch_pack[0].PC;
                next_rob_array[tail_ptr].NPC = dispatch_pack[0].NPC;
                next_rob_array[tail_ptr].has_dest = dispatch_pack[0].has_dest;
                next_rob_array[tail_ptr].dest_reg_idx = dispatch_pack[0].dest_reg_idx;
                next_rob_array[tail_ptr].lq_index = dispatch_pack[0].lq_index;
                next_rob_array[tail_ptr].sq_index = dispatch_pack[0].sq_index;
                next_rob_array[tail_ptr].is_store = dispatch_pack[0].wr_mem;
                next_tail_ptr = tail_ptr + 1;  

                rob_index[0] = tail_ptr;          

                if(is_branch[0]) begin
                    rob_tail_out[0] = next_tail_ptr;
                end
            end else if (dispatch_2 ) begin
                next_rob_array[tail_ptr].valid = 1;  
                next_rob_array[tail_ptr].t = dispatch_pack[0].T;
                next_rob_array[tail_ptr].told = dispatch_pack[0].Told;
                next_rob_array[tail_ptr].ready_retire = 1'b0;
                next_rob_array[tail_ptr].halt = dispatch_pack[0].halt;
                next_rob_array[tail_ptr].illegal = dispatch_pack[0].illegal;
                next_rob_array[tail_ptr].PC = dispatch_pack[0].PC;
                next_rob_array[tail_ptr].NPC = dispatch_pack[0].NPC;
                next_rob_array[tail_ptr].has_dest = dispatch_pack[0].has_dest;
                next_rob_array[tail_ptr].dest_reg_idx = dispatch_pack[0].dest_reg_idx; 
                next_rob_array[tail_ptr].lq_index = dispatch_pack[0].lq_index;
                next_rob_array[tail_ptr].sq_index = dispatch_pack[0].sq_index;   
                next_rob_array[tail_ptr].is_store = dispatch_pack[0].wr_mem;        

                next_rob_array[ROB_IDX'(tail_ptr + 1)].valid = 1;
                next_rob_array[ROB_IDX'(tail_ptr + 1)].t = dispatch_pack[1].T;
                next_rob_array[ROB_IDX'(tail_ptr + 1)].told = dispatch_pack[1].Told;
                next_rob_array[ROB_IDX'(tail_ptr + 1)].ready_retire = 1'b0;
                next_rob_array[ROB_IDX'(tail_ptr + 1)].halt = dispatch_pack[1].halt;
                next_rob_array[ROB_IDX'(tail_ptr + 1)].illegal = dispatch_pack[1].illegal;
                next_rob_array[ROB_IDX'(tail_ptr + 1)].PC = dispatch_pack[1].PC;
                next_rob_array[ROB_IDX'(tail_ptr + 1)].NPC = dispatch_pack[1].NPC;
                next_rob_array[ROB_IDX'(tail_ptr + 1)].has_dest = dispatch_pack[1].has_dest;
                next_rob_array[ROB_IDX'(tail_ptr + 1)].dest_reg_idx = dispatch_pack[1].dest_reg_idx;
                next_rob_array[ROB_IDX'(tail_ptr + 1)].lq_index = dispatch_pack[1].lq_index;
                next_rob_array[ROB_IDX'(tail_ptr + 1)].sq_index = dispatch_pack[1].sq_index;
                next_rob_array[ROB_IDX'(tail_ptr + 1)].is_store = dispatch_pack[1].wr_mem;

                rob_index[0] = tail_ptr;
                rob_index[1] = tail_ptr + 1;

                next_tail_ptr = tail_ptr + 2;  
                for(int i = 0; i < `N; i++)begin
                    if(is_branch[i])begin
                        rob_tail_out[i] = tail_ptr + i + 1;
                    end
                end
            end
        end

        full_n = mispredicted ? (next_head_ptr == next_tail_ptr && full) :  
                                full ? (next_head_ptr == next_tail_ptr) :
                                ((next_tail_ptr == next_head_ptr) && (next_tail_ptr != tail_ptr));
        //calculate available space
        free_slots = (full_n)? 0 : 
                        (next_head_ptr == next_tail_ptr) ? `ROB_SZ :
                        (next_head_ptr > next_tail_ptr) ? ROB_IDX'(next_head_ptr - next_tail_ptr) : 
                        ROB_IDX'(`ROB_SZ - (next_tail_ptr - next_head_ptr));


    
        rob_space_avail = full_n             ? 0 :
                            (next_head_ptr == next_tail_ptr) ? 2 : // empty
                            (free_slots >= 2)  ? 2 :
                            (free_slots == 1)  ? 1 : 0;
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
           rob_array <= '{default: '0};
           full <= '0;
        end
        else begin
           head_ptr <= next_head_ptr;
           tail_ptr <= next_tail_ptr;
           full<= full_n;
           rob_array <= next_rob_array;
        end
    end

    
endmodule 