`include "sys_defs.svh"

module fetch_buffer(
    input logic                clock,
    input logic                reset,
    input logic                mispredicted,
    input logic [1:0]          dispatch_num_req,//from dispatch stage
    input F_D_PACKET           fetch_pack [`N-1:0],          //from fetch stage


    output logic  [1:0]         can_fetch_num,                   //to fetch stage
    output F_D_PACKET           dispatch_pack [`N-1:0]        //to dispatch stage
);

    F_D_PACKET         buffer         [`FB_SZ-1:0];
    F_D_PACKET         buffer_n       [`FB_SZ-1:0];

    FB_IDX head, head_n;
    FB_IDX tail, tail_n;
    logic full, full_n;
    FB_CNT   free_slots;
    FB_CNT   valid_entries, valid_entries_n;

    
    always_comb begin
        //default
        head_n   = head;
        tail_n   = tail;
        full_n   = full;
        buffer_n = buffer;
        valid_entries_n = valid_entries;
        dispatch_pack = '{default:'0};


        //enqueue
        for(int i = 0; i < `N; i++) begin
            if(fetch_pack[i].valid) begin
                buffer_n[FB_IDX'(tail + i)] = fetch_pack[i];
                tail_n = tail_n + 1;
            end
        end

        //dequeue
        //request 2 instructions, but only 1 instruction is available
        //request 2 instructions, and 2 or more instructions are available
        //request 1 instruction, and at least 1 instruction is available
        //request 1 instruction, but no instruction is available
        //request 0 instruction
        for (int i = 0; i < `N; i++) begin
            if (i < dispatch_num_req && valid_entries > i) begin
                dispatch_pack[i] = buffer[FB_IDX'(head + i)];
                head_n = head_n + 1;
            end
        end

        //calculate available slots
        free_slots = (head_n >= tail_n) ? FB_IDX'(head_n - tail_n) :
                                          FB_IDX'(`FB_SZ - (tail_n - head_n));
        
       full_n = full ? (head_n == tail_n) :  // 继承：满了之后只有dequeue才能变不满//inherit: if already full, only dequeue can make it not full
                ((tail_n == head_n) && (tail_n != tail)); // 新满：这周期tail追上了head//new full: tail caught up with head this cycle
        
        valid_entries_n = `FB_SZ - free_slots;

        can_fetch_num = full_n             ? 0 :
                        (head_n == tail_n) ? 2 : // empty
                        (free_slots >= 2)  ? 2 :
                        (free_slots == 1)  ? 1 : 0;

    end

    always_ff @(posedge clock) begin
        if (reset || mispredicted) begin
            head  <= '0;
            tail  <= '0;
            full <= '0;
            buffer <= '{default:'0};
            valid_entries <= '0;
        end else begin
            head   <= head_n;
            tail   <= tail_n;
            full   <= full_n;
            buffer <= buffer_n;
            valid_entries <= valid_entries_n;
        end
    end

endmodule