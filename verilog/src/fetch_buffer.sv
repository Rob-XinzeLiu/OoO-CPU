`include "verilog/sys_defs.svh"

module fetch_buffer #(
    parameter int DEPTH = 5 * `N,
)(
    input logic                clock,
    input logic                reset,
    input logic                mispredicted,
    input logic [1:0]          dispatch_num_req,//from dispatch stage
    input F_D_PACKET           fetch_pack [`N-1:0],          //from fetch stage

    output logic  [1:0]         space_avail,                   //to fetch stage
    output F_D_PACKET           dispatch_pack [`N-1:0],       //to dispatch stage
);

    typedef struct packed {
        F_D_PACKET packet;
        logic      valid;
    } FB_ENTRY;

    FB_ENTRY         buffer         [DEPTH-1:0];
    FB_ENTRY         buffer_n       [DEPTH-1:0];

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
                buffer_n[tail_n].packet = fetch_pack[i];
                buffer_n[tail_n].valid = 'b1;

                if(tail_n == DEPTH -1) begin
                    tail_n = '0;
                end else begin
                    tail_n = tail_n + 1;
                end
                count_n = count_n + 1;
            end
        end

        //dequeue
        for (int i = 0; i < `N; i++) begin
            if (dispatch_num_req == 'd2 && count_n > 'd1) begin

            end else if (dispatch_num_req == 'd2 && count_n == 'd1) begin

            end
        end
    end

    always_ff @(posedge clock) begin
        if (reset || halt_mem || mispredict) begin
            head  <= '0;
            tail  <= '0;
            count <= '0;
            buffer <= '{default:'0};
        end else begin
            head   <= head_n;
            tail   <= tail_n;
            count  <= count_n;
            buffer <= buffer_n;
        end
    end





endmodule