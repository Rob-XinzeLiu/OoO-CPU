`include "sys_defs.svh"

module freelist(
    input logic         clock,
    input logic         reset,
   // input PRF_IDX       told_from_rob [`N-1:0],
    input logic [$clog2(`N+1)-1:0] retire_num,                  //from rob
    input logic [$clog2(`N+1)-1:0] dispatch_num,                //from dispatcher
    // TODO: is_branch as an input to take snapshots 
    input logic         [$clog2(`ROB_SZ)-1:0] Branch_stack_H,  // Head output from BS
    input logic         [$clog2(`ROB_SZ)-1:0] Branch_stack_C,  // Count output from BS
    input logic         dispatch_valid,                         // from dispatcher
    input logic         retire_valid,                           // from rob
    input logic         cond_branch [`N-1:0],
    input logic         mispredicted,

    output PRF_IDX      t [`N-1:0],
    output logic        full,
    output logic        [$clog2(`ROB_SZ)-1:0] BS_head [`N-1:0]  //to BS

    // TODO: Sent head_ptr to the branch stack
);
    logic remaining_valid;
    logic empty;
    logic do_disp;
    
    logic [$clog2(`ROB_SZ) - 1:0] head,tail,head_n,tail_n;
    logic [$clog2(`ROB_SZ):0] cnt,cnt_n;
    PRF_IDX freelist [`ROB_SZ -1:0];  // 8 total fresslist size


    always_comb begin
    head_n = head;
    tail_n = tail;
    cnt_n  = cnt;
    t       = '{default:'0};
    BS_head = '{default:'0};

    empty = (cnt == 0);
    // only dispatch if we have enough entries
    do_disp = dispatch_valid && (cnt >= dispatch_num);
    
    if (mispredicted) begin
        head_n = Branch_stack_H;
        cnt_n = Branch_stack_C;
    end
    else begin
    if (do_disp) begin
          head_n = head + dispatch_num;
    end
    if (retire_valid) begin
          tail_n = tail + retire_num;
    end

    cnt_n = cnt + (retire_valid ? retire_num   : '0)
                - (do_disp      ? dispatch_num : '0);

    if (do_disp && dispatch_num == 1) begin
        t[0] = freelist[head];
    end
    if (do_disp && dispatch_num == 2) begin
        t[0] = freelist[head];
        t[1] = freelist[head + 1];
    end

    if (cond_branch[0]) BS_head[0] = head;
    if (cond_branch[1]) BS_head[1] = head + 1;

    full = (cnt < dispatch_num);
    
    end
    end

    //assign full = remaining_valid;

     always_ff @(posedge clock) begin
        if (reset) begin
           head <= '0;
           tail <= 3'd7;
           cnt <= `ROB_SZ;
            for (int i=0;i< `ROB_SZ;i++) begin
            freelist[i] <= PRF_IDX'(`ARCH_REG_SZ + i);       //32-63
            end
        end

        else begin
           head <= head_n;
           tail <= tail_n;
           cnt <= cnt_n;

        end
    end

endmodule