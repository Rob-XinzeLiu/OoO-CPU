`include "sys_defs.svh"
`include "ISA.svh"

module mshr #(
    parameter int ENTRIES = 16
)(
    input logic                 clock,
    input logic                 reset,

    input miss_request_t        dcache_miss_req,

    input  MEM_TAG              mem2proc_transaction_tag,
    input  MEM_TAG              mem2proc_data_tag,
    input  MEM_BLOCK            mem2proc_data,

    
    output MEM_COMMAND          mshr2mem_command,
    output ADDR                 mshr2mem_addr,
    output MEM_SIZE             mshr2mem_size,
    output MEM_BLOCK            mshr2mem_data,
    output completed_mshr_t     com_miss_req,
    output logic                miss_queue_full,
    output logic                miss_returned

);

    miss_fifo_entry_t miss_fifo      [ENTRIES-1:0];
    miss_fifo_entry_t next_miss_fifo [ENTRIES-1:0];

    logic [$clog2(ENTRIES)-1:0] miss_head, miss_tail;
    logic [$clog2(ENTRIES)-1:0] next_miss_head, next_miss_tail;
    logic [$clog2(ENTRIES):0]   miss_count, next_miss_count;

    req_state_t req_state, next_req_state;
    miss_fifo_entry_t active_req, next_active_req;

    outstanding_entry_t outstanding_table      [ENTRIES-1:0];
    outstanding_entry_t next_outstanding_table [ENTRIES-1:0];

    logic found_free_outstanding;
    logic [$clog2(ENTRIES)-1:0] free_outstanding_idx;

    logic found_completed;
    logic [$clog2(ENTRIES)-1:0] completed_idx;

    assign miss_queue_full = (miss_count == ENTRIES);
    assign miss_returned   = found_completed;

    always_comb begin: MISS_QUEUE_LOGIC
        next_miss_head         = miss_head;
        next_miss_tail         = miss_tail;
        next_miss_count        = miss_count;

        next_miss_fifo         = miss_fifo;
        next_req_state         = req_state;
        next_active_req        = active_req;
        next_outstanding_table = outstanding_table;

        mshr2mem_command = MEM_NONE;
        mshr2mem_addr    = '0;
        com_miss_req     = '0;
        mshr2mem_size    = DOUBLE;
        mshr2mem_data    = '0;

        found_free_outstanding = 1'b0;
        free_outstanding_idx   = '0;
        
        found_completed = 1'b0;
        completed_idx   = '0;
        ///////////////////////
        // Enqueue new miss request
        ////////////////////////
        if (dcache_miss_req.valid && !miss_queue_full) begin
            next_miss_fifo[miss_tail].valid             = 1'b1;
            next_miss_fifo[miss_tail].miss_req_address  = dcache_miss_req.miss_req_address;
            next_miss_fifo[miss_tail].miss_req_tag      = dcache_miss_req.miss_req_tag;
            next_miss_fifo[miss_tail].miss_req_set      = dcache_miss_req.miss_req_set;
            next_miss_fifo[miss_tail].miss_req_offset   = dcache_miss_req.miss_req_offset;
            next_miss_fifo[miss_tail].req_is_load       = dcache_miss_req.req_is_load;
            next_miss_fifo[miss_tail].miss_req_size     = dcache_miss_req.miss_req_size;
            next_miss_fifo[miss_tail].miss_req_unsigned = dcache_miss_req.miss_req_unsigned;
            next_miss_fifo[miss_tail].miss_req_data     = dcache_miss_req.miss_req_data;
            next_miss_fifo[miss_tail].lq_index          = dcache_miss_req.lq_index;

            next_miss_count = next_miss_count + 1'd1;
            next_miss_tail  = next_miss_tail + 1'd1;
        end

        for (int i = 0; i < ENTRIES; i++) begin
            if (!found_free_outstanding && !outstanding_table[i].valid) begin
                found_free_outstanding = 1'b1;
                free_outstanding_idx   = i[$clog2(ENTRIES)-1:0];
            end
        end

        case (req_state) 
            // REQ_IDLE: begin
            //     if(miss_count != 0) begin
            //         next_active_req = miss_fifo[miss_head];
            //         next_req_state = REQ_WAIT_ACCEPT;

            //         next_miss_fifo[miss_head] = '0;
            //         next_miss_head = miss_head + 1'd1;
            //         next_miss_count = miss_count - 1'd1;
            //     end
            // end
            REQ_IDLE: begin
                if (next_miss_count != 0) begin
                    next_active_req = next_miss_fifo[next_miss_head];
                    next_req_state  = REQ_WAIT_ACCEPT;

                    next_miss_fifo[next_miss_head] = '0;
                    next_miss_head  = next_miss_head + 1'd1;
                    next_miss_count = next_miss_count - 1'd1;
                end
            end
            REQ_WAIT_ACCEPT: begin
                if (found_free_outstanding) begin
                    mshr2mem_command = MEM_LOAD;
                    mshr2mem_addr    = active_req.miss_req_address;        
                    if(mem2proc_transaction_tag != '0) begin 
                        next_outstanding_table[free_outstanding_idx].valid             = 1'b1;
                        next_outstanding_table[free_outstanding_idx].trans_tag         = mem2proc_transaction_tag;
                        next_outstanding_table[free_outstanding_idx].miss_req_address  = active_req.miss_req_address;
                        next_outstanding_table[free_outstanding_idx].miss_req_tag      = active_req.miss_req_tag;
                        next_outstanding_table[free_outstanding_idx].miss_req_set      = active_req.miss_req_set;
                        next_outstanding_table[free_outstanding_idx].miss_req_offset   = active_req.miss_req_offset;
                        next_outstanding_table[free_outstanding_idx].req_is_load       = active_req.req_is_load;
                        next_outstanding_table[free_outstanding_idx].miss_req_size     = active_req.miss_req_size;
                        next_outstanding_table[free_outstanding_idx].miss_req_unsigned = active_req.miss_req_unsigned;
                        next_outstanding_table[free_outstanding_idx].miss_req_data     = active_req.miss_req_data;
                        next_outstanding_table[free_outstanding_idx].lq_index          = active_req.lq_index;

                        next_active_req = '0;
                        next_req_state  = REQ_IDLE;
                    end
                end
            end
        endcase

        if (mem2proc_data_tag != '0) begin
            for (int i = 0; i < ENTRIES; i++) begin
                if (!found_completed &&
                    outstanding_table[i].valid &&
                    outstanding_table[i].trans_tag == mem2proc_data_tag) begin
                    found_completed = 1'b1;
                    completed_idx   = i[$clog2(ENTRIES)-1:0];
                end
            end
        end

        if (found_completed) begin
            com_miss_req.valid             = 1'b1;
            com_miss_req.miss_req_address  = outstanding_table[completed_idx].miss_req_address;
            com_miss_req.miss_req_tag      = outstanding_table[completed_idx].miss_req_tag;
            com_miss_req.miss_req_set      = outstanding_table[completed_idx].miss_req_set;
            com_miss_req.miss_req_offset   = outstanding_table[completed_idx].miss_req_offset;
            com_miss_req.req_is_load       = outstanding_table[completed_idx].req_is_load;
            com_miss_req.miss_req_size     = outstanding_table[completed_idx].miss_req_size;
            com_miss_req.miss_req_unsigned = outstanding_table[completed_idx].miss_req_unsigned;
            com_miss_req.miss_req_data     = outstanding_table[completed_idx].miss_req_data;
            com_miss_req.refill_data       = mem2proc_data;
            com_miss_req.lq_index          = outstanding_table[completed_idx].lq_index;

            next_outstanding_table[completed_idx] = '0;
        end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            miss_head <= '0;
            miss_tail <= '0;
            miss_count <= '0;
            req_state <= REQ_IDLE;
            active_req <= '0;

            for (int i = 0; i < ENTRIES; i++) begin
                miss_fifo[i] <= '0;
                outstanding_table[i] <= '0;
            end
        end else begin
            miss_head <= next_miss_head;
            miss_tail <= next_miss_tail;
            miss_count <= next_miss_count;
            req_state <= next_req_state;
            active_req <= next_active_req;

            for (int i = 0; i < ENTRIES; i++) begin
                miss_fifo[i] <= next_miss_fifo[i];
                outstanding_table[i] <= next_outstanding_table[i];
            end
        end
    end
endmodule