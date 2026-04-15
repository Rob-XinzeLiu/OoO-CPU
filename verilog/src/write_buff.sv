`include "sys_defs.svh"

module write_buffer #(
    parameter int ENTRIES = `WB_ENTRIES
)(
    input  logic      clock,
    input  logic      reset,

    // dcache miss lookup
    input  logic                        dcache_miss_req_valid,
    input  logic                        req_is_load,
    input  ADDR                         dcache_miss_addr,
    input  logic [`DCACHE_TAG_BITS-1:0] dcache_miss_req_tag,
    input  logic [`DCACHE_SET_BITS-1:0] dcache_miss_req_set,
    input  MEM_SIZE                     dcache_miss_req_size,
    input  logic                        dcache_miss_req_unsigned,
    input  DATA                         dcache_miss_req_store_data, // only valid for store misses
    input  LQ_IDX                       lq_index,
    input  logic [1:0]                  generation,

    output logic                        wb_hit,
    output  ADDR                        wb_hit_addr,//REQUESTED ADDRESS FROM INSTRUCTION
    output LQ_IDX                       wb_hit_lq_index,
    output logic [1:0]                  wb_hit_generation,
    output DATA                         wb_load_data, 

    input logic                         vcache_data_valid,
    input  MEM_BLOCK                    vcache_data,
    input  logic [`DCACHE_TAG_BITS-1:0] vcache_evicted_tag,
    input  logic [`DCACHE_SET_BITS-1:0] vcache_evicted_set,
    input  logic                        grant,
    output logic                        wb_full,

    // MEM commands
    input  MEM_TAG                      mem2proc_transaction_tag,
    output MEM_COMMAND                  wb2mem_command,
    output ADDR                         wb2mem_addr,
    output MEM_BLOCK                    wb2mem_data,
    output MEM_SIZE                     wb2mem_size,

    output wb_entry_t     [`WB_ENTRIES-1: 0] debug_write_buff
  
);

    wb_entry_t          [ENTRIES-1:0] write_buffer;
    wb_entry_t    [ENTRIES-1:0] next_write_buffer ;

    logic [$clog2(ENTRIES)-1:0] head;
    logic [$clog2(ENTRIES)-1:0] next_head;
    logic [$clog2(ENTRIES)-1:0] tail;
    logic [$clog2(ENTRIES)-1:0] next_tail;
    logic[$clog2(ENTRIES):0] count; // To track the number of valid entries in the buffer
    logic[$clog2(ENTRIES):0] next_count;
    

    assign wb_full = (count == ENTRIES);

    logic do_enqueue;
    logic do_dequeue;
    logic will_dequeue;

    assign will_dequeue = write_buffer[head].valid && grant && (mem2proc_transaction_tag != 'd0);
    // Write buffer hit logic
    always_comb begin
        for(int j = 0; j < ENTRIES; ++j)begin
            debug_write_buff[j] = write_buffer[j];
        end


        wb_hit       = 1'b0;
        wb_load_data = '0;
        wb_hit_lq_index = '0;
        wb_hit_generation = '0;
        wb_hit_addr  = '0;

        next_write_buffer = write_buffer;
        next_head         = head;
        next_tail         = tail;
        next_count        = count;
        do_enqueue = 1'b0;
        do_dequeue = 1'b0;

        wb2mem_command = MEM_NONE;
        wb2mem_addr = '0;
        wb2mem_data = '0;
        wb2mem_size = DOUBLE;

        //////////////////////
        //     LOOKUP LOGIC //
        ///////////////////////

        if (dcache_miss_req_valid) begin
            for (int i = 0; i < ENTRIES; i++) begin
                if (write_buffer[i].valid && (write_buffer[i].tag == dcache_miss_req_tag) &&
                    (write_buffer[i].set == dcache_miss_req_set)) begin
                    wb_hit       = 1'b1;
                    wb_hit_addr  = dcache_miss_addr;
                    
                    if (req_is_load) begin
                        wb_hit_lq_index = lq_index;
                        wb_hit_generation = generation;
                        case (dcache_miss_req_size)

                            BYTE: begin
                                if (dcache_miss_req_unsigned) begin
                                    wb_load_data = {24'b0,
                                        write_buffer[i].data.byte_level[dcache_miss_addr[2:0]] // offset in addr
                                    };
                                end else begin
                                    wb_load_data = {{24{write_buffer[i].data.byte_level[dcache_miss_addr[2:0]][7]}},
                                        write_buffer[i].data.byte_level[dcache_miss_addr[2:0]]
                                    };
                                end
                            end
                            HALF: begin
                                if (dcache_miss_req_unsigned) begin
                                    wb_load_data = {16'b0,
                                        write_buffer[i].data.half_level[dcache_miss_addr[2:1]]
                                    };
                                end else begin
                                    wb_load_data = {{16{write_buffer[i].data.half_level[dcache_miss_addr[2:1]][15]}},
                                        write_buffer[i].data.half_level[dcache_miss_addr[2:1]]
                                    };
                                end
                            end
                            WORD: begin
                                wb_load_data = write_buffer[i].data.word_level[dcache_miss_addr[2]];
                            end
                            default: begin
                                wb_load_data = '0;
                            end
                        endcase
                    end
                    if (!req_is_load) begin
                        case (dcache_miss_req_size)
                            BYTE: begin
                                next_write_buffer[i].data.byte_level[dcache_miss_addr[2:0]] 
                                    = dcache_miss_req_store_data[7:0];
                            end

                            HALF: begin
                                next_write_buffer[i].data.half_level[dcache_miss_addr[2:1]] 
                                    = dcache_miss_req_store_data[15:0];
                            end

                            WORD: begin
                                next_write_buffer[i].data.word_level[dcache_miss_addr[2]] 
                                    = dcache_miss_req_store_data;
                            end

                            default: begin
                                next_write_buffer[i].data = write_buffer[i].data;
                            end
                        endcase
                    end
                end
            end
        end
        if(vcache_data_valid && (!wb_full || will_dequeue) ) begin
            next_write_buffer[tail].valid = 1'b1;
            next_write_buffer[tail].tag   = vcache_evicted_tag;
            next_write_buffer[tail].set   = vcache_evicted_set;
            next_write_buffer[tail].data  = vcache_data;
            next_tail = (tail + 'd1) % ENTRIES; // Circular buffer logic
            do_enqueue = 1'b1;
        end

        if(write_buffer[head].valid) begin
            wb2mem_command = MEM_STORE;
            wb2mem_addr    = {write_buffer[head].tag, write_buffer[head].set, 3'b0}; 
            wb2mem_data    = write_buffer[head].data;
            wb2mem_size    = DOUBLE;
            if (grant && mem2proc_transaction_tag != 'd0 ) begin
                next_write_buffer[head] = '0;
                next_head = (head + 'd1) % ENTRIES;
                do_dequeue = 1'b1;
            end 
        end

        next_count = count + (do_enqueue ? 1 : 0) - (do_dequeue ? 1 : 0);
    end

    always_ff @( posedge clock) begin : latch_system
        if(reset)begin
            count <= 'd0;
            head <= 'd0;
            tail <= 'd0;
            write_buffer <=  '0;
        end
        else begin
            write_buffer <= next_write_buffer;
            count <= next_count;
            head <= next_head;
            tail <= next_tail;
        end 
    end

endmodule