`include "sys_defs.svh"
module freelist(
    input logic                             clock               ,
    input logic                             reset               ,
    input logic [1:0]                       retire_num          ,  //from retire
    input logic                             retire_valid        ,  // from rob
    input FLIST_SZ                          Branch_stack_H      ,  // Head output from BS
    input logic [`N-1:0]                    dispatch_valid      ,  // from dispatcher
    input logic                             is_branch [`N-1:0],
    input logic                             mispredicted        ,

    //output logic                            full,
    output FLIST_CNT                        BS_head [`N-1:0]    ,  //to BS
    output PRF_IDX                          t       [`N-1:0]    ,                              // to dispatch
    output FLIST_CNT                        avail_num     // to dispatch
);

    logic [3:0][4:0] cnt_list;
    FLIST_SZ head, head_n;
    FLIST_SZ tail, tail_n;   
    FLIST_CNT   cnt,  cnt_n;
    logic do_disp;//do dispatch this cycle

    PRF_IDX freelist [`ROB_SZ-1:0];//freelist register
    logic [1:0] req_num;

    always_comb begin
        head_n  = head;
        tail_n  = tail;
        cnt_n   = cnt;

        t       = '{default:'0};
        BS_head = '{default:'0};

        // count requests 
        req_num = '0;
        for (int i = 0; i < `N; i++) begin
            if (dispatch_valid[i]) begin
                req_num++;
            end
        end
        full = 1'b0;

        do_disp = (req_num != 0) && (cnt >= req_num);
        // recovery wins
        if (mispredicted) begin
            head_n = Branch_stack_H;
            cnt_n  = cnt_list[Branch_stack_H];
        end
        else begin
            // if you request more regs than we have stall (full=1) and allocate none.
            if (req_num != 0 && cnt < req_num) begin
                full = 1'b1;
            end
            else begin
                if (do_disp) begin
                    head_n = head + req_num;
                end
                
                if (retire_valid) begin
                    tail_n = tail + retire_num;
                end
               
                if (do_disp && req_num == 1) begin
                    t[0] = freelist[head];
                end
                
                if (do_disp && req_num == 2) begin
                    t[0] = freelist[head];
                    t[1] = freelist[head + 1];
                end

                if (is_branch[0]) BS_head[0] = head;
                if (is_branch[1]) BS_head[1] = head + 1;

               
                cnt_n  = cnt + (retire_valid ? retire_num   : '0)
                             - (do_disp ? req_num : '0);

                cnt_list[head_n] = cnt_n;
            end
        end
    end

    assign avail_num = cnt; 

    always_ff @(posedge clock) begin
        if (reset) begin
            head <= '0;
            tail <= $clog2(`ROB_SZ)'(`ROB_SZ-1);
            cnt  <= `ROB_SZ;
            
            for (int i = 0; i < `ROB_SZ; i++) begin
                freelist[i] <= PRF_IDX'(`ARCH_REG_SZ + i);
            end
        end
        else begin
            head <= head_n;
            tail <= tail_n;
            cnt  <= cnt_n;
        end
    end
endmodule