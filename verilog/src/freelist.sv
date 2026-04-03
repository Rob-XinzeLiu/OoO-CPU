`include "sys_defs.svh"
module freelist(
    input logic                             clock               ,
    input logic                             reset               ,
    input FL_RETIRE_PACKET [`N-1:0]         freelist_pack       , //from retire
    input FLIST_IDX                         Branch_stack_T      ,  // Head output from BS
    input logic                             dispatch_valid [`N-1:0],  // from dispatcher
    input logic                             is_branch [`N-1:0],
    input logic                             mispredicted        ,

    output FLIST_IDX                        BS_tail [`N-1:0]    ,  //to BS
    output PRF_IDX          [`N-1:0]        t                   ,  // to dispatch
    output logic [1:0]                      avail_num              // to dispatch
);

    FLIST_IDX head, head_n;
    FLIST_IDX tail, tail_n;   
    logic full, full_n;//tail catch up with head
    FLIST_CNT free_slots;
    PRF_IDX             freelist [`FLIST_SZ-1:0];//freelist register
    PRF_IDX             freelist_n [`FLIST_SZ-1:0];//freelist register

    always_comb begin
        //default
        head_n  = head;
        tail_n  = tail;
        full_n   = full; 
        freelist_n = freelist;
        t = '0;
        avail_num = '0;
        BS_tail = '{default: '0};

        //retire
        if(freelist_pack[0].valid && freelist_pack[1].valid)begin
            freelist_n[head] = freelist_pack[0].t_old;
            freelist_n[FLIST_IDX'(head+1)] = freelist_pack[1].t_old;
            head_n = head_n + 2;
        end else if (freelist_pack[0].valid && !freelist_pack[1].valid) begin
            freelist_n[head] = freelist_pack[0].t_old;
            head_n = head_n + 1;
        end else if (!freelist_pack[0].valid && freelist_pack[1].valid) begin
            freelist_n[head] = freelist_pack[1].t_old;
            head_n = head_n + 1;
        end

        //mispredict recovery
        if(mispredicted) begin
            tail_n =  Branch_stack_T;
            full_n = 1'b0; // can't be full after mispredict recovery
    
            free_slots = (head_n >= tail_n) ? FLIST_CNT'(head_n - tail_n) :
                                            FLIST_CNT'(`FLIST_SZ - (tail_n - head_n));
            
            avail_num = (free_slots >= 2) ? 2 :
                        (free_slots == 1) ? 1 : 0;
            
        //dispatch
        end else begin 
            
            // dispatch
            if(dispatch_valid[0] && dispatch_valid[1]) begin
                t[0] = freelist[tail];
                t[1] = freelist[FLIST_IDX'(tail+1)];
                tail_n = tail + 2;
            end else if (dispatch_valid[0] && !dispatch_valid[1]) begin
                t[0] = freelist[tail];
                tail_n = tail + 1;
            end else if (!dispatch_valid[0] && dispatch_valid[1]) begin
                t[1] = freelist[tail];
                tail_n = tail + 1;
            end

            // take snapshot 
            if(is_branch[0]) begin
                BS_tail[0] = dispatch_valid[0]? FLIST_IDX'(tail+1) : tail; 
            end
            if(is_branch[1]) begin
                //need to consider if dispatch pack 0 has dest reg
                BS_tail[1] = tail_n;
            end
            //calculate free slots
            free_slots = (head_n >= tail_n) ? FLIST_IDX'(head_n - tail_n) :
                                  FLIST_IDX'(`FLIST_SZ - (tail_n - head_n));
                                  
            full_n = (tail_n == head_n) && (tail_n != tail);

            avail_num = full_n        ? 0 :
                        (head_n == tail_n) ? 2 : // empty
                        (free_slots >= 2)  ? 2 :
                        (free_slots == 1)  ? 1 : 0;
        end
    end
    

    always_ff @(posedge clock) begin
        if (reset) begin
            head <= '0;
            tail <= '0;
            full  <= '0;
            for (int i = 0; i < `FLIST_SZ; i++) begin
                freelist[i] <= PRF_IDX'(`ARCH_REG_SZ + i);
            end
        end
        else begin
            head <= head_n;
            tail <= tail_n;
            full  <= full_n;
            freelist <= freelist_n;
        end
    end
    
endmodule  
