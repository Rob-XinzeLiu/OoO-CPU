`include "sys_defs.svh"
module rob(
    input logic                 clock                           ,
    input logic                 reset                           ,
    input D_S_PACKET            dispatch_pack           [`N-1:0],
    input logic                 mispredicted                    ,
    input ROB_IDX               mispredicted_index              ,
    input X_C_PACKET            cdb                     [`N-1:0],

    output PRF_IDX              told_to_freelist        [`N-1:0],//retire
    output ROB_CNT              space_avail                     ,//to dispatch stage
    output ROB_IDX              rob_index               [`N-1:0] //to rs
);

    typedef struct packed {
        PRF_IDX t;
        PRF_IDX told;
        logic ready_retire;//how many inst can we retire per cycle?
        ROB_IDX index;
        //logic is_load;
        //logic is_store;
    } ROB_ENTRY;

    ROB_ENTRY       rob_array           [`ROB_SZ-1:0];
    ROB_ENTRY       next_rob_array      [`ROB_SZ-1:0];
    ROB_IDX         head_ptr, next_head_ptr;
    ROB_IDX         tail_ptr, next_tail_ptr;//tail pointer point to next free slot
    ROB_CNT         rob_count, next_rob_count;//how many entries used
    //retire
    logic           retire_1, retire_2;
    assign          retire_1 = (rob_array[head_ptr].ready_retire && !rob_array[head_ptr + 1 ].ready_retire);
    assign          retire_2 = (rob_array[head_ptr].ready_retire && rob_array[head_ptr + 1 ].ready_retire);
    //combinational output to rs
    assign          rob_index[0] = tail_ptr;
    assign          rob_index[1] = tail_ptr + 1'b1;
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
        next_rob_count = rob_count;
        next_rob_array = rob_array;
        told_to_freelist    = '{default: '0};
///////////////////////////////////////////////////////////////////////
//////////////////////                         ////////////////////////
//////////////////////      Commit(Retire)     ////////////////////////
//////////////////////                         ////////////////////////
///////////////////////////////////////////////////////////////////////

        if(retire_2)begin
            for(int i = 0; i < `N; ++i)begin

                told_to_freelist[i] = rob_array[head_ptr+i].told;
                next_rob_array[head_ptr+i].ready_retire = 1'b0; 
            end

            next_head_ptr = head_ptr + 2;
            next_rob_count = rob_count - 2;

        end else if(retire_1)begin

            told_to_freelist[0] = rob_array[head_ptr].told;
            next_head_ptr = head_ptr + 1;
            next_rob_count = rob_count - 1;
            next_rob_array[head_ptr].ready_retire = 1'b0;

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
            next_tail_ptr = mispredicted_index + 1;
            next_rob_count = ROB_CNT'(ROB_IDX'(mispredicted_index - next_head_ptr) + 1'b1) ;
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
        if(dispatch_1 && !mispredicted) begin              // Just in case that we dispatch when it's mispredicted
            next_rob_array[tail_ptr].t = dispatch_pack[0].T;
            next_rob_array[tail_ptr].told = dispatch_pack[0].Told;
            next_rob_array[tail_ptr].ready_retire = 1'b0;

            next_tail_ptr = tail_ptr + 1;            
            next_rob_count = next_rob_count + 1;
        end else if (dispatch_2 && !mispredicted) begin
            next_rob_array[tail_ptr].t = dispatch_pack[0].T;
            next_rob_array[tail_ptr].told = dispatch_pack[0].Told;
            next_rob_array[tail_ptr].ready_retire = 1'b0;

            next_rob_array[tail_ptr + 1].t = dispatch_pack[1].T;
            next_rob_array[tail_ptr + 1].told = dispatch_pack[1].Told;
            next_rob_array[tail_ptr + 1].ready_retire = 1'b0;

            next_tail_ptr = tail_ptr + 2;            
            next_rob_count = next_rob_count + 2;
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