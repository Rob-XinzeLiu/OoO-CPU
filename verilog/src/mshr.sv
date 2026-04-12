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
    output logic                mshr_wait_for_trans,
    output logic                mshr_currently_waiting

);

    miss_fifo_entry_t miss_fifo      [ENTRIES-1:0];
    miss_fifo_entry_t next_miss_fifo [ENTRIES-1:0];

    logic [$clog2(ENTRIES)-1:0] miss_head, miss_tail;
    logic [$clog2(ENTRIES)-1:0] next_miss_head, next_miss_tail;
    logic [$clog2(ENTRIES):0]   miss_count, next_miss_count;

    // req_state_t req_state, next_req_state;
    // miss_fifo_entry_t active_req, next_active_req;

    //completed_mshr_t     next_com_miss_req;

    outstanding_entry_t outstanding_table      [ENTRIES-1:0];
    outstanding_entry_t next_outstanding_table [ENTRIES-1:0];

    logic [$clog2(ENTRIES)-1:0] out_head, out_tail;
    logic [$clog2(ENTRIES)-1:0] next_out_head, next_out_tail;
    logic [$clog2(ENTRIES):0]   out_count, next_out_count;

    logic outstanding_full;
    //logic next_miss_returned;

    assign outstanding_full  = (out_count == ENTRIES);

    // logic found_completed;
    logic [$clog2(ENTRIES)-1:0] completed_idx;

    assign miss_queue_full = (miss_count == ENTRIES) || (out_count == ENTRIES);
    //assign next_miss_returned   = found_completed;

    //assign mshr_currently_waiting = miss_count != 'd0 || out_count != 'd0 || req_state != REQ_IDLE ;
    assign mshr_currently_waiting =
    (miss_count != 'd0) || (next_miss_count != 'd0) ||
    (out_count  != 'd0) || (next_out_count  != 'd0) ||
    (dcache_miss_req.valid && !miss_queue_full);
    
    //logic miss_merged;

    logic found_in_outstanding;
    //logic found_in_active;
    logic found_in_fifo;

    always_comb begin: MISS_QUEUE_LOGIC

        next_miss_head         = miss_head;
        next_miss_tail         = miss_tail;
        next_miss_count        = miss_count;

        next_miss_fifo         = miss_fifo;
        //next_req_state         = req_state;
        //next_active_req        = active_req;
        next_outstanding_table = outstanding_table;

        mshr2mem_command = MEM_NONE;
        mshr2mem_addr    = '0;
        //next_com_miss_req     = '0;
        mshr2mem_size    = DOUBLE;
        mshr2mem_data    = '0;
        mshr_wait_for_trans = 1'b0;

        next_out_head  = out_head;
        next_out_tail  = out_tail;
        next_out_count = out_count;

        
        //found_completed = 1'b0;
        completed_idx   = '0;
        miss_returned   = 1'b0;

        //miss_merged = 1'b0;
        found_in_outstanding = 1'b0;
        //found_in_active      = 1'b0;
        found_in_fifo        = 1'b0;
        com_miss_req = '0;

        ///////////////////////
        // Enqueue new miss request
        ////////////////////////
        if (dcache_miss_req.valid && !miss_queue_full) begin

            for (int i = 0; i < ENTRIES; i++) begin
                if (outstanding_table[i].valid &&
                    outstanding_table[i].miss_req_tag == dcache_miss_req.miss_req_tag &&
                    outstanding_table[i].miss_req_set == dcache_miss_req.miss_req_set) begin
                    found_in_outstanding = 1'b1;
                end
            end

            if (!found_in_outstanding) begin
                for (int i = 0; i < ENTRIES; i++) begin
                    if (miss_fifo[i].valid &&
                        miss_fifo[i].miss_req_tag == dcache_miss_req.miss_req_tag &&
                        miss_fifo[i].miss_req_set == dcache_miss_req.miss_req_set) begin
                        found_in_fifo = 1'b1;
                    end
                end
            end
            if (found_in_outstanding && !outstanding_full) begin
                // already requested to memory, so add directly to outstanding as dependent
                next_outstanding_table[next_out_tail].valid             = 1'b1;
                next_outstanding_table[next_out_tail].ready             = 1'b0;
                next_outstanding_table[next_out_tail].dep_miss          = 1'b1;
                next_outstanding_table[next_out_tail].trans_tag         = '0;
                next_outstanding_table[next_out_tail].miss_req_address  = dcache_miss_req.miss_req_address;
                next_outstanding_table[next_out_tail].miss_req_tag      = dcache_miss_req.miss_req_tag;
                next_outstanding_table[next_out_tail].miss_req_set      = dcache_miss_req.miss_req_set;
                next_outstanding_table[next_out_tail].miss_req_offset   = dcache_miss_req.miss_req_offset;
                next_outstanding_table[next_out_tail].req_is_load       = dcache_miss_req.req_is_load;
                next_outstanding_table[next_out_tail].miss_req_size     = dcache_miss_req.miss_req_size;
                next_outstanding_table[next_out_tail].miss_req_unsigned = dcache_miss_req.miss_req_unsigned;
                next_outstanding_table[next_out_tail].miss_req_data     = dcache_miss_req.miss_req_data;
                next_outstanding_table[next_out_tail].lq_index          = dcache_miss_req.lq_index;
                next_outstanding_table[next_out_tail].refill_data       = '0;

                next_out_tail  = next_out_tail + 1'd1;
                next_out_count = next_out_count + 1'd1;

            end else begin
                
                next_miss_fifo[next_miss_tail].valid             = 1'b1;
                next_miss_fifo[next_miss_tail].dependent         = found_in_fifo;
                next_miss_fifo[next_miss_tail].miss_req_address  = dcache_miss_req.miss_req_address;
                next_miss_fifo[next_miss_tail].miss_req_tag      = dcache_miss_req.miss_req_tag;
                next_miss_fifo[next_miss_tail].miss_req_set      = dcache_miss_req.miss_req_set;
                next_miss_fifo[next_miss_tail].miss_req_offset   = dcache_miss_req.miss_req_offset;
                next_miss_fifo[next_miss_tail].req_is_load       = dcache_miss_req.req_is_load;
                next_miss_fifo[next_miss_tail].miss_req_size     = dcache_miss_req.miss_req_size;
                next_miss_fifo[next_miss_tail].miss_req_unsigned = dcache_miss_req.miss_req_unsigned;
                next_miss_fifo[next_miss_tail].miss_req_data     = dcache_miss_req.miss_req_data;
                next_miss_fifo[next_miss_tail].lq_index          = dcache_miss_req.lq_index;

                next_miss_tail  = next_miss_tail + 1'd1;
                next_miss_count = next_miss_count + 1'd1;
            end
        end
            
        if (next_miss_count != 0 )begin
            if(!next_miss_fifo[next_miss_head].dependent && !outstanding_full ) begin
                mshr2mem_command = MEM_LOAD;
               mshr2mem_addr = {
                    next_miss_fifo[next_miss_head].miss_req_tag,
                    next_miss_fifo[next_miss_head].miss_req_set,
                    3'b000
                };  
                mshr_wait_for_trans = 1'b1;

                if(mem2proc_transaction_tag != '0 && grant ) begin 
                    next_outstanding_table[next_out_tail].valid             = 1'b1;
                    next_outstanding_table[next_out_tail].ready             = 1'b0; 
                    next_outstanding_table[next_out_tail].trans_tag         = mem2proc_transaction_tag;
                    next_outstanding_table[next_out_tail].dep_miss          = 1'b0;
                    next_outstanding_table[next_out_tail].miss_req_address  = next_miss_fifo[next_miss_head].miss_req_address;
                    next_outstanding_table[next_out_tail].miss_req_tag      = next_miss_fifo[next_miss_head].miss_req_tag;
                    next_outstanding_table[next_out_tail].miss_req_set      = next_miss_fifo[next_miss_head].miss_req_set;
                    next_outstanding_table[next_out_tail].miss_req_offset   = next_miss_fifo[next_miss_head].miss_req_offset;
                    next_outstanding_table[next_out_tail].req_is_load       = next_miss_fifo[next_miss_head].req_is_load;
                    next_outstanding_table[next_out_tail].miss_req_size     = next_miss_fifo[next_miss_head].miss_req_size;
                    next_outstanding_table[next_out_tail].miss_req_unsigned = next_miss_fifo[next_miss_head].miss_req_unsigned;
                    next_outstanding_table[next_out_tail].miss_req_data     = next_miss_fifo[next_miss_head].miss_req_data;
                    next_outstanding_table[next_out_tail].lq_index          = next_miss_fifo[next_miss_head].lq_index;
                    next_outstanding_table[next_out_tail].refill_data       = '0; //will change

                    next_out_tail  = next_out_tail + 1'd1;
                    next_out_count = next_out_count + 1'd1;

                    next_miss_fifo[next_miss_head] = '0;
                    next_miss_head  = next_miss_head + 1'd1;
                    next_miss_count = next_miss_count - 1'd1;
                end 
            end else begin // if dependent just add from fifo on to oustanding table as prev entry shouldve been serviced
                next_outstanding_table[next_out_tail].valid             = 1'b1;
                next_outstanding_table[next_out_tail].ready             = 1'b1; 
                next_outstanding_table[next_out_tail].trans_tag         = '0;
                next_outstanding_table[next_out_tail].dep_miss          = 1'b1; //it is depednant
                next_outstanding_table[next_out_tail].miss_req_address  = next_miss_fifo[next_miss_head].miss_req_address;
                next_outstanding_table[next_out_tail].miss_req_tag      = next_miss_fifo[next_miss_head].miss_req_tag;
                next_outstanding_table[next_out_tail].miss_req_set      = next_miss_fifo[next_miss_head].miss_req_set;
                next_outstanding_table[next_out_tail].miss_req_offset   = next_miss_fifo[next_miss_head].miss_req_offset;
                next_outstanding_table[next_out_tail].req_is_load       = next_miss_fifo[next_miss_head].req_is_load;
                next_outstanding_table[next_out_tail].miss_req_size     = next_miss_fifo[next_miss_head].miss_req_size;
                next_outstanding_table[next_out_tail].miss_req_unsigned = next_miss_fifo[next_miss_head].miss_req_unsigned;
                next_outstanding_table[next_out_tail].miss_req_data     = next_miss_fifo[next_miss_head].miss_req_data;
                next_outstanding_table[next_out_tail].lq_index          = next_miss_fifo[next_miss_head].lq_index;
                next_outstanding_table[next_out_tail].refill_data       = '0; //we zont care

                next_out_tail  = next_out_tail + 1'd1;
                next_out_count = next_out_count + 1'd1;
                //next_active_req = '0;
                //next_req_state  = REQ_IDLE;

                next_miss_fifo[next_miss_head] = '0;
                next_miss_head  = next_miss_head + 1'd1;
                next_miss_count = next_miss_count - 1'd1;
            end        
        end

        if(mem2proc_data_tag != 'd0)begin
            for(int i = 0; i < ENTRIES; i++)begin
                if (!outstanding_table[i].dep_miss && outstanding_table[i].trans_tag == mem2proc_data_tag) begin
                    next_outstanding_table[i].ready             = 1'b1;
                    next_outstanding_table[i].refill_data       = mem2proc_data;
                end
            end
        end
            
        if (outstanding_table[out_head].valid && (outstanding_table[out_head].ready || outstanding_table[out_head].dep_miss) ) begin
            miss_returned = 1'b1;
            com_miss_req.valid             = 1'b1;
            com_miss_req.dep_miss          = outstanding_table[out_head].dep_miss;
            com_miss_req.miss_req_address  = outstanding_table[out_head].miss_req_address;
            com_miss_req.miss_req_tag      = outstanding_table[out_head].miss_req_tag;
            com_miss_req.miss_req_set      = outstanding_table[out_head].miss_req_set;
            com_miss_req.miss_req_offset   = outstanding_table[out_head].miss_req_offset;
            com_miss_req.req_is_load       = outstanding_table[out_head].req_is_load;
            com_miss_req.miss_req_size     = outstanding_table[out_head].miss_req_size;
            com_miss_req.miss_req_unsigned = outstanding_table[out_head].miss_req_unsigned;
            com_miss_req.miss_req_data     = outstanding_table[out_head].miss_req_data;
            com_miss_req.refill_data       = outstanding_table[out_head].refill_data;
            com_miss_req.lq_index          = outstanding_table[out_head].lq_index;

            next_outstanding_table[next_out_head] = '0; // clear it
            next_out_head  = next_out_head + 1'd1;
            next_out_count = next_out_count - 1'd1;
        end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            miss_head <= '0;
            miss_tail <= '0;
            miss_count <= '0;
            //req_state <= REQ_IDLE;
            //active_req <= '0;
            out_head  <= '0;
            out_tail  <= '0;
            out_count <= '0;
            //com_miss_req <= '0;
            //miss_returned <= '0;
            for (int i = 0; i < ENTRIES; i++) begin
                miss_fifo[i] <= '0;
                outstanding_table[i] <= '0;
            end

        end else begin
            //miss_returned <= next_miss_returned;
            miss_head <= next_miss_head;
            miss_tail <= next_miss_tail;
            miss_count <= next_miss_count;
            //req_state <= next_req_state;
            //active_req <= next_active_req;
            out_head  <= next_out_head;
            out_tail  <= next_out_tail;
            out_count <= next_out_count;
            //com_miss_req <= next_com_miss_req;
            for (int i = 0; i < ENTRIES; i++) begin
                miss_fifo[i] <= next_miss_fifo[i];
                outstanding_table[i] <= next_outstanding_table[i];
            end
        end
    end
endmodule