`include "verilog/sys_defs.svh"

module fetch_buffer #(
    parameter int DEPTH = 5 * `N
)(
    input logic                clock,
    input logic                reset,
    input logic                mispredicted,
    input logic [1:0]          dispatch_num_req,//from dispatch stage
    input F_D_PACKET           fetch_pack [`N-1:0],          //from fetch stage

    output logic  [1:0]         can_fetch_num,                   //to fetch stage
    output F_D_PACKET           dispatch_pack [`N-1:0],       //to dispatch stage
);

    F_D_PACKET         buffer         [DEPTH-1:0];
    F_D_PACKET         buffer_n       [DEPTH-1:0];

    localparam int BUFFER_CNT = $clog2(DEPTH);

    logic [BUFFER_CNT-1:0] head, head_n;
    logic [BUFFER_CNT-1:0] tail, tail_n;
    logic [BUFFER_CNT:0]   count, count_n;
    
    always_comb begin
        //default
        head_n   = head;
        tail_n   = tail;
        count_n  = count;
        buffer_n = buffer;
        dispatch_pack = '{default:'0};

        //enqueue
        for(int i = 0; i < `N; i++) begin
            if(fetch_pack[i].valid) begin
                buffer_n[tail_n] = fetch_pack[i];
                if(tail_n == DEPTH -1) begin
                    tail_n = '0;
                end else begin
                    tail_n = tail_n + 1;
                end
                count_n = count_n + 1;
            end
        end

        //dequeue
        //request 2 instructions, but only 1 instruction is available
        //request 2 instructions, and 2 or more instructions are available
        //request 1 instruction, and at least 1 instruction is available
        //request 1 instruction, but no instruction is available
        //request 0 instruction
        for (int i = 0; i < `N; i++) begin
            if (i < dispatch_num_req && count_n > i) begin
                dispatch_pack[i] = buffer_n[head_n];
                if (head_n == DEPTH - 1)
                    head_n = '0;
                else
                    head_n = head_n + 1;
                count_n = count_n - 1;
            end
        end

    end

    always_ff @(posedge clock) begin
        if (reset || mispredicted) begin
            head  <= '0;
            tail  <= '0;
            count <= '0;
            buffer <= '{default:'0};
            can_fetch_num <= 2'd2; // can fetch 2 instructions when reset or mispredicted
        end else begin
            head   <= head_n;
            tail   <= tail_n;
            count  <= count_n;
            buffer <= buffer_n;
            can_fetch_num <= (DEPTH - count_n >= 2) ? 2'd2 :
                             (DEPTH - count_n >= 1) ? 2'd1 : 2'd0;
        end
    end

endmodule