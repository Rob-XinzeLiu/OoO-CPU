`include "sys_defs.svh"
module freelist(
    input logic                             clock               ,
    input logic                             reset               ,
    input logic [1:0]                       retire_num          ,  //from retire
    input FLIST_IDX                         Branch_stack_H      ,  // Head output from BS
    input logic                             dispatch_valid [`N-1:0],  // from dispatcher
    input logic                             is_branch [`N-1:0],
    input logic                             mispredicted        ,

    output FLIST_IDX                        BS_tail [`N-1:0]    ,  //to BS
    output PRF_IDX          [`N-1:0]        t                   ,  // to dispatch
    output FLIST_CNT                        avail_num              // to dispatch
);

    FLIST_CNT cnt_list [`ROB_SZ-1:0];    
    FLIST_IDX head, head_n;
    FLIST_IDX tail, tail_n;   
    FLIST_CNT   cnt,  cnt_n;
    logic do_disp;//do dispatch this cycle

    PRF_IDX             freelist [`FLIST_SZ-1:0];//freelist register
    logic [1:0]         req_num;

    always_comb begin
        //default
        head_n  = head;
        tail_n  = tail;
        cnt_n   = cnt;
        t       = '{default:'0};
        req_num = '0;
        
        // count requests 
        for (int i = 0; i < `N; i++) begin
            if (dispatch_valid[i]) begin
                req_num++;
            end
        end

        do_disp = (req_num != 0) && (cnt >= req_num);
        // recovery wins
        if (mispredicted) begin
            head_n = Branch_stack_H;
            cnt_n  = cnt_list[Branch_stack_H];
        end
        else begin
            if (do_disp) begin
                head_n = head + req_num;
            end
                
            tail_n = tail + retire_num;
               
            if (do_disp && req_num == 1) begin
                t[0] = freelist[head];
            end
                
            if (do_disp && req_num == 2) begin
                t[0] = freelist[head];
                if (head == `ROB_SZ-1)
                    t[1] = freelist[0];
                else
                    t[1] = freelist[head + 1];
            end

            if (is_branch[0]) begin 
                BS_tail[0] = head;
            end
            if (is_branch[1]) begin
                BS_tail[1] = head + 1;
            end

               
            cnt_n  = cnt + retire_num - (do_disp ? req_num : '0);
        end

        avail_num = cnt_n;
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            head <= '0;
            tail <= FLIST_IDX'(`ROB_SZ-1);
            cnt  <= `ROB_SZ;

            for (int i = 0; i < `ROB_SZ; i++) begin
                freelist[i] <= PRF_IDX'(`ARCH_REG_SZ + i);
                cnt_list[i] <= '0;
            end

            cnt_list[0] <= `ROB_SZ;
        end
        else begin
            head <= head_n;
            tail <= tail_n;
            cnt  <= cnt_n;

            cnt_list[head_n] <= cnt_n;
        end
    end
endmodule