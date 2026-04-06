`include "sys_defs.svh"
`include "ISA.svh"

module mshr #(
    parameter int ENTRIES = `MSHR_ENTRIES
)(
    input logic                 clock,
    input logic                 reset,
    input logic                 grant,

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
    output logic                miss_returned,
    output logic                mshr_wait_for_trans

);

    miss_fifo_entry_t miss_fifo      [ENTRIES-1:0];
    miss_fifo_entry_t next_miss_fifo [ENTRIES-1:0];

    logic [$clog2(ENTRIES)-1:0] miss_head, miss_tail;
    logic [$clog2(ENTRIES)-1:0] next_miss_head, next_miss_tail;
    logic [$clog2(ENTRIES):0]   miss_count, next_miss_count;

    req_state_t req_state, next_req_state;
    miss_fifo_entry_t active_req, next_active_req;

    completed_mshr_t     next_com_miss_req;

    outstanding_entry_t outstanding_table      [ENTRIES-1:0];
    outstanding_entry_t next_outstanding_table [ENTRIES-1:0];
    logic [$clog2(ENTRIES)-1:0] out_head, out_tail;
    logic [$clog2(ENTRIES)-1:0] next_out_head, next_out_tail;
    logic [$clog2(ENTRIES):0]   out_count, next_out_count;

    logic outstanding_full;
    logic next_miss_returned;

    assign outstanding_full  = (out_count == ENTRIES);

    // logic found_completed;
    logic [$clog2(ENTRIES)-1:0] completed_idx;

    assign miss_queue_full = (miss_count == ENTRIES) || (out_count == ENTRIES);
    logic sending_to_dcache;
    //assign next_miss_returned   = found_completed;

    logic miss_merged;
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
        next_com_miss_req     = '0;
        mshr2mem_size    = DOUBLE;
        mshr2mem_data    = '0;
        mshr_wait_for_trans = 1'b0;

        next_out_head  = out_head;
        next_out_tail  = out_tail;
        next_out_count = out_count;

        
        //found_completed = 1'b0;
        completed_idx   = '0;
        next_miss_returned   = 1'b0;

        miss_merged = 1'b0;
        sending_to_dcache = 1'b0;
        ///////////////////////
        // Enqueue new miss request
        ////////////////////////
        if (dcache_miss_req.valid && !miss_queue_full) begin
            //first step is to loop oustanding table to see if this request can be skipped and added directly  to outstanding table
            for( int i = 0; i < ENTRIES; i++) begin
                if (outstanding_table[i].valid && !miss_merged &&
                    outstanding_table[i].miss_req_address == dcache_miss_req.miss_req_address) begin
                    miss_merged = 1'b1;
                end
            end
            if (miss_merged && !outstanding_full) begin
                next_outstanding_table[out_tail].valid             = 1'b1;
                next_outstanding_table[out_tail].dep_miss         = 1'b1;
                next_outstanding_table[out_tail].miss_req_address  = dcache_miss_req.miss_req_address;
                next_outstanding_table[out_tail].trans_tag         = '0; //this field is not used for merged request
                next_outstanding_table[out_tail].miss_req_tag      = dcache_miss_req.miss_req_tag;
                next_outstanding_table[out_tail].miss_req_set      = dcache_miss_req.miss_req_set;
                next_outstanding_table[out_tail].miss_req_offset   = dcache_miss_req.miss_req_offset;
                next_outstanding_table[out_tail].req_is_load       = dcache_miss_req.req_is_load;
                next_outstanding_table[out_tail].miss_req_size     = dcache_miss_req.miss_req_size;
                next_outstanding_table[out_tail].miss_req_unsigned = dcache_miss_req.miss_req_unsigned;
                next_outstanding_table[out_tail].miss_req_data     = dcache_miss_req.miss_req_data;
                next_outstanding_table[out_tail].lq_index          = dcache_miss_req.lq_index;
                next_out_tail  = out_tail + 1'd1;
                next_out_count = out_count + 1'd1;
            end
            else begin

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
        end

        case (req_state) 
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
                if (!outstanding_full) begin
                    mshr2mem_command = MEM_LOAD;
                    mshr2mem_addr    = active_req.miss_req_address;  
                    mshr_wait_for_trans = 1'b1;
                    
                    if(mem2proc_transaction_tag != '0 && grant ) begin 
                        next_outstanding_table[out_tail].valid             = 1'b1;
                        next_outstanding_table[out_tail].trans_tag         = mem2proc_transaction_tag;
                        next_outstanding_table[out_tail].dep_miss           = 1'b0;
                        next_outstanding_table[out_tail].miss_req_address  = active_req.miss_req_address;
                        next_outstanding_table[out_tail].miss_req_tag      = active_req.miss_req_tag;
                        next_outstanding_table[out_tail].miss_req_set      = active_req.miss_req_set;
                        next_outstanding_table[out_tail].miss_req_offset   = active_req.miss_req_offset;
                        next_outstanding_table[out_tail].req_is_load       = active_req.req_is_load;
                        next_outstanding_table[out_tail].miss_req_size     = active_req.miss_req_size;
                        next_outstanding_table[out_tail].miss_req_unsigned = active_req.miss_req_unsigned;
                        next_outstanding_table[out_tail].miss_req_data     = active_req.miss_req_data;
                        next_outstanding_table[out_tail].lq_index          = active_req.lq_index;
                        next_out_tail  = out_tail + 1'd1;
                        next_out_count = out_count + 1'd1;
                        next_active_req = '0;
                        next_req_state  = REQ_IDLE;
                    end
                end
            end
        endcase
        
        if (outstanding_table[out_head].valid) begin
            // 1. PRIMARY completion (memory return)
            if (!outstanding_table[out_head].dep_miss &&
                mem2proc_data_tag != 0 &&
                outstanding_table[out_head].trans_tag == mem2proc_data_tag) begin

                next_miss_returned = 1'b1;
                next_com_miss_req.valid             = 1'b1;
                next_com_miss_req.dep_miss          = 1'b0;
                next_com_miss_req.miss_req_address  = outstanding_table[out_head].miss_req_address;
                next_com_miss_req.miss_req_tag      = outstanding_table[out_head].miss_req_tag;
                next_com_miss_req.miss_req_set      = outstanding_table[out_head].miss_req_set;
                next_com_miss_req.miss_req_offset   = outstanding_table[out_head].miss_req_offset;
                next_com_miss_req.req_is_load       = outstanding_table[out_head].req_is_load;
                next_com_miss_req.miss_req_size     = outstanding_table[out_head].miss_req_size;
                next_com_miss_req.miss_req_unsigned = outstanding_table[out_head].miss_req_unsigned;
                next_com_miss_req.miss_req_data     = outstanding_table[out_head].miss_req_data;
                next_com_miss_req.refill_data       = mem2proc_data;
                next_com_miss_req.lq_index          = outstanding_table[out_head].lq_index;

                next_outstanding_table[out_head] = '0;
                next_out_head  = out_head + 1'd1;
                next_out_count = next_out_count - 1'd1;
            end

            // 2. DEP replay (no memory return)
            else if (outstanding_table[out_head].dep_miss) begin
                next_miss_returned = 1'b1;
                next_com_miss_req.valid             = 1'b1;
                next_com_miss_req.dep_miss          = 1'b1;
                next_com_miss_req.miss_req_address  = outstanding_table[out_head].miss_req_address;
                next_com_miss_req.miss_req_tag      = outstanding_table[out_head].miss_req_tag;
                next_com_miss_req.miss_req_set      = outstanding_table[out_head].miss_req_set;
                next_com_miss_req.miss_req_offset   = outstanding_table[out_head].miss_req_offset;
                next_com_miss_req.req_is_load       = outstanding_table[out_head].req_is_load;
                next_com_miss_req.miss_req_size     = outstanding_table[out_head].miss_req_size;
                next_com_miss_req.miss_req_unsigned = outstanding_table[out_head].miss_req_unsigned;
                next_com_miss_req.miss_req_data     = outstanding_table[out_head].miss_req_data;
                next_com_miss_req.refill_data       = '0;
                next_com_miss_req.lq_index          = outstanding_table[out_head].lq_index;

                next_outstanding_table[out_head] = '0;
                next_out_head  = out_head + 1'd1;
                next_out_count = next_out_count - 1'd1;
            end
        end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            miss_head <= '0;
            miss_tail <= '0;
            miss_count <= '0;
            req_state <= REQ_IDLE;
            active_req <= '0;
            out_head  <= '0;
            out_tail  <= '0;
            out_count <= '0;
            com_miss_req <= '0;
            miss_returned <= '0;
            for (int i = 0; i < ENTRIES; i++) begin
                miss_fifo[i] <= '0;
                outstanding_table[i] <= '0;
            end

        end else begin
            miss_returned <= next_miss_returned;
            miss_head <= next_miss_head;
            miss_tail <= next_miss_tail;
            miss_count <= next_miss_count;
            req_state <= next_req_state;
            active_req <= next_active_req;
            out_head  <= next_out_head;
            out_tail  <= next_out_tail;
            out_count <= next_out_count;
            com_miss_req <= next_com_miss_req;
            for (int i = 0; i < ENTRIES; i++) begin
                miss_fifo[i] <= next_miss_fifo[i];
                outstanding_table[i] <= next_outstanding_table[i];
            end
        end

    end
endmodule