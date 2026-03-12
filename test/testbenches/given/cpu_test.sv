/////////////////////////////////////////////////////////////////////////
//                                                                     //
//   Modulename :  cpu_test.sv                                         //
//                                                                     //
//  Description :  Testbench module for the OOO processor.            //
//                 Directly drives instruction memory to CPU,          //
//                 no cache/memory interface required.                 //
//                                                                     //
/////////////////////////////////////////////////////////////////////////

`include "sys_defs.svh"

import "DPI-C" function string decode_inst(int inst);

`define TB_MAX_CYCLES 50000000

module testbench;

    //////////////////////////////////////////////////
    //                                              //
    //          File / String Parameters            //
    //                                              //
    //////////////////////////////////////////////////

    // run like:
    //   cd build && ./simv +MEMORY=../programs/mem/<prog>.mem +OUTPUT=../output/<prog>
    string program_memory_file, output_name;
    string out_outfile, cpi_outfile, writeback_outfile;
    int    out_fileno, cpi_fileno, wb_fileno;

    //////////////////////////////////////////////////
    //                                              //
    //          Simulation Control Signals          //
    //                                              //
    //////////////////////////////////////////////////

    logic        clock;
    logic        reset;
    logic [31:0] clock_count;
    logic [31:0] instr_count;

    EXCEPTION_CODE error_status = NO_ERROR;

    //////////////////////////////////////////////////
    //                                              //
    //   Testbench-side PC and Instruction Memory   //
    //                                              //
    //////////////////////////////////////////////////

    // The testbench owns the PC and the instruction memory.
    // It directly reads instructions and sends them into the CPU,
    // bypassing all MEM_COMMAND / MEM_TAG handshake logic.

    MEM_BLOCK unified_memory [`MEM_64BIT_LINES - 1 : 0]; // flat instruction/data memory

    ADDR        tb_PC;              // current fetch address (step 3)
    MEM_BLOCK   tb_imem_data;       // 64-bit line driven into the CPU (step 4)

    // From CPU → testbench: how many instructions were accepted this cycle (step 5)
    logic [1:0] fetch_accepted;

    // From CPU → testbench: branch redirect signals (step 8)
    logic       branch_taken;
    ADDR        branch_target;

    // Drive the memory line that contains tb_PC into the CPU
    // The bottom 3 bits select the 8-byte-aligned line
    assign tb_imem_data = unified_memory[tb_PC[31:3]];

    // Step 3 & 6 & 8: advance PC each cycle
    always_ff @(posedge clock) begin
        if (reset) begin
            tb_PC <= 32'b0;
        end else if (branch_taken) begin
            // step 8: branch overrides the increment
            tb_PC <= branch_target;
        end else begin
            // step 6: increment by 4 * accepted instructions
            tb_PC <= tb_PC + (32'(fetch_accepted) << 2);
        end
    end

    //////////////////////////////////////////////////
    //                                              //
    //             Writeback / Retire               //
    //                                              //
    //////////////////////////////////////////////////

    RETIRE_PACKET [`N-1:0] committed_insts; // from CPU (step 7)

    //////////////////////////////////////////////////
    //                                              //
    //          Debug Outputs (unchanged)           //
    //                                              //
    //////////////////////////////////////////////////

    // ADDR  if_NPC_dbg;
    // DATA  if_inst_dbg;
    // logic if_valid_dbg;
    // ADDR  if_id_NPC_dbg;
    // DATA  if_id_inst_dbg;
    // logic if_id_valid_dbg;
    // ADDR  id_ex_NPC_dbg;
    // DATA  id_ex_inst_dbg;
    // logic id_ex_valid_dbg;
    // ADDR  ex_mem_NPC_dbg;
    // DATA  ex_mem_inst_dbg;
    // logic ex_mem_valid_dbg;
    // ADDR  mem_wb_NPC_dbg;
    // DATA  mem_wb_inst_dbg;
    // logic mem_wb_valid_dbg;

    //////////////////////////////////////////////////
    //                                              //
    //              CPU Instantiation               //
    //                                              //
    //////////////////////////////////////////////////

    cpu verisimpleV (
        .clock            (clock),
        .reset            (reset),

        // Step 4: drive memory data directly into CPU's fetch stage
        .tb_PC            (tb_PC),
        .tb_imem_data     (tb_imem_data),

        // Step 5: CPU tells testbench how many instructions were accepted
        .fetch_accepted   (fetch_accepted),

        // Step 7: retiring instructions → testbench writes .wb file
        .committed_insts  (committed_insts),

        // Step 8: branch redirect from CPU back to testbench PC
        .branch_taken     (branch_taken),
        .branch_target    (branch_target)

        // // Debug
        // .if_NPC_dbg       (if_NPC_dbg),
        // .if_inst_dbg      (if_inst_dbg),
        // .if_valid_dbg     (if_valid_dbg),
        // .if_id_NPC_dbg    (if_id_NPC_dbg),
        // .if_id_inst_dbg   (if_id_inst_dbg),
        // .if_id_valid_dbg  (if_id_valid_dbg),
        // .id_ex_NPC_dbg    (id_ex_NPC_dbg),
        // .id_ex_inst_dbg   (id_ex_inst_dbg),
        // .id_ex_valid_dbg  (id_ex_valid_dbg),
        // .ex_mem_NPC_dbg   (ex_mem_NPC_dbg),
        // .ex_mem_inst_dbg  (ex_mem_inst_dbg),
        // .ex_mem_valid_dbg (ex_mem_valid_dbg),
        // .mem_wb_NPC_dbg   (mem_wb_NPC_dbg),
        // .mem_wb_inst_dbg  (mem_wb_inst_dbg),
        // .mem_wb_valid_dbg (mem_wb_valid_dbg)
    );

    //////////////////////////////////////////////////
    //                                              //
    //              Clock Generation                //
    //                                              //
    //////////////////////////////////////////////////

    always begin
        #(`CLOCK_PERIOD / 2.0);
        clock = ~clock;
    end

    //////////////////////////////////////////////////
    //                                              //
    //              Initialization                  //
    //                                              //
    //////////////////////////////////////////////////

    initial begin
        $display("\n---- Starting CPU Testbench (direct-fetch mode) ----\n");

        if ($value$plusargs("MEMORY=%s", program_memory_file)) begin
            $display("Using memory file  : %s", program_memory_file);
        end else begin
            $display("Did not receive '+MEMORY=' argument. Exiting.\n");
            $finish;
        end

        if ($value$plusargs("OUTPUT=%s", output_name)) begin
            $display("Using output files : %s.{out, cpi, wb}", output_name);
            out_outfile       = {output_name, ".out"};
            cpi_outfile       = {output_name, ".cpi"};
            writeback_outfile = {output_name, ".wb"};
        end else begin
            $display("Did not receive '+OUTPUT=' argument. Exiting.\n");
            $finish;
        end

        clock = 1'b0;
        reset = 1'b0;

        $display("\n  %16t : Asserting Reset", $realtime);
        reset = 1'b1;

        @(posedge clock);
        @(posedge clock);

        // Step 1: load program into testbench's unified_memory (not a mem module)
        $display("  %16t : Loading Unified Memory", $realtime);
        $readmemh(program_memory_file, unified_memory);

        @(posedge clock);
        @(posedge clock);
        #1;
        $display("  %16t : Deasserting Reset", $realtime);
        reset = 1'b0;

        wb_fileno  = $fopen(writeback_outfile);
        $fdisplay(wb_fileno, "Register writeback output (hexadecimal)");

        out_fileno = $fopen(out_outfile);

        $display("  %16t : Running Processor", $realtime);
    end

    //////////////////////////////////////////////////
    //                                              //
    //            Main Simulation Loop              //
    //                                              //
    //////////////////////////////////////////////////

    always @(negedge clock) begin
        if (reset) begin
            clock_count = 0;
            instr_count = 0;
        end else begin
            #2;

            clock_count = clock_count + 1;

            if (clock_count % 10000 == 0)
                $display("  %16t : %d cycles", $realtime, clock_count);

            print_custom_data();

            // Step 7: record writeback and check for halt/illegal
            output_reg_writeback_and_maybe_halt();

            if (error_status != NO_ERROR || clock_count > `TB_MAX_CYCLES) begin
                $display("  %16t : Processor Finished", $realtime);

                $fclose(wb_fileno);
                show_final_mem_and_status(error_status);
                output_cpi_file();

                $display("\n---- Finished CPU Testbench ----\n");
                #100 $finish;
            end
        end
    end

    //////////////////////////////////////////////////
    //                                              //
    //       Writeback Recording Task (Step 7)      //
    //                                              //
    //////////////////////////////////////////////////

    task output_reg_writeback_and_maybe_halt;
        ADDR  pc;
        DATA  inst;
        MEM_BLOCK block;
        for (int n = 0; n < `N; ++n) begin
            if (committed_insts[n].valid) begin
                instr_count = instr_count + 1;

                pc    = committed_insts[n].NPC - 4;
                block = unified_memory[pc[31:3]];   // read from TB memory, not a separate module
                inst  = block.word_level[pc[2]];

                // if (committed_insts[n].reg_idx == `ZERO_REG) begin
                    $fdisplay(wb_fileno, "PC %4x:%-8s| ---",
                              pc, decode_inst(inst));
                // end 
                // else begin
                //     $fdisplay(wb_fileno, "PC %4x:%-8s| r%02d=%-8x",
                //               pc,
                //               decode_inst(inst),
                //               committed_insts[n].reg_idx,
                //               committed_insts[n].data);
                // end

                if (committed_insts[n].illegal) begin
                    error_status = ILLEGAL_INST;
                    break;
                end else if (committed_insts[n].halt) begin
                    error_status = HALTED_ON_WFI;
                    break;
                end
            end
        end
    endtask

    //////////////////////////////////////////////////
    //                                              //
    //               CPI Output Task                //
    //                                              //
    //////////////////////////////////////////////////

    task output_cpi_file;
        real cpi;
        begin
            cpi = $itor(clock_count) / instr_count;
            cpi_fileno = $fopen(cpi_outfile);
            $fdisplay(cpi_fileno, "@@@  %0d cycles / %0d instrs = %f CPI",
                      clock_count, instr_count, cpi);
            $fdisplay(cpi_fileno, "@@@  %4.2f ns total time to execute",
                      clock_count * `CLOCK_PERIOD);
            $fclose(cpi_fileno);
        end
    endtask

    //////////////////////////////////////////////////
    //                                              //
    //         Final Memory Dump Task               //
    //                                              //
    //////////////////////////////////////////////////

    task show_final_mem_and_status;
        input EXCEPTION_CODE final_status;
        int showing_data;
        begin
            $fdisplay(out_fileno, "\nFinal memory state and exit status:\n");
            $fdisplay(out_fileno, "@@@ Unified Memory contents hex on left, decimal on right: ");
            $fdisplay(out_fileno, "@@@");
            showing_data = 0;
            for (int k = 0; k <= `MEM_64BIT_LINES - 1; k = k+1) begin
                if (unified_memory[k] != 0) begin
                    $fdisplay(out_fileno, "@@@ mem[%5d] = %x : %0d",
                              k*8, unified_memory[k], unified_memory[k]);
                    showing_data = 1;
                end else if (showing_data != 0) begin
                    $fdisplay(out_fileno, "@@@");
                    showing_data = 0;
                end
            end
            $fdisplay(out_fileno, "@@@");

            case (final_status)
                LOAD_ACCESS_FAULT: $fdisplay(out_fileno, "@@@ System halted on memory error");
                HALTED_ON_WFI:     $fdisplay(out_fileno, "@@@ System halted on WFI instruction");
                ILLEGAL_INST:      $fdisplay(out_fileno, "@@@ System halted on illegal instruction");
                default:           $fdisplay(out_fileno, "@@@ System halted on unknown error code %x",
                                             final_status);
            endcase
            $fdisplay(out_fileno, "@@@");
            $fclose(out_fileno);
        end
    endtask

    //////////////////////////////////////////////////
    //                                              //
    //          Optional Custom Debug Task          //
    //                                              //
    //////////////////////////////////////////////////

    task print_custom_data;
        // Uncomment / expand as needed:
        // $display("%3d: tb_PC=%08x fetch_accepted=%0d branch_taken=%b branch_target=%08x",
        //          clock_count-1, tb_PC, fetch_accepted, branch_taken, branch_target);
    endtask

endmodule // testbench