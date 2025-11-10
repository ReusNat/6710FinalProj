`timescale 1ns / 1ps

module tb_regfile_1024bit;

    // Testbench signals
    reg clk;
    reg rw;              // 1 = write, 0 = read
    reg sel;             // 0 = lower half, 1 = upper half
    reg [511:0] data_in;
    wire [511:0] data_out;


    regfile_1024bit dut (
        .clk(clk),
        .rw(rw),
        .sel(sel),
        .data_in(data_in),
        .data_out(data_out)
    );

    initial clk = 0;
    always begin
	clk <= ~clk;
	#10;
    end

    // Stimulus
    initial begin
        // Initialize
        rw = 0;
        sel = 0;
        data_in = 512'd0;

        // Display header
        $display("Time\tRW\tSEL\tData_in[15:0]\t\tData_out[15:0]");
        $monitor("%0t\t%b\t%b\t%h\t%h", $time, rw, sel, data_in[15:0], data_out[15:0]);

        // Wait for a few clock cycles
        #100;

        // ----------------------------
        // Write lower 512 bits
        // ----------------------------
        rw = 1;                  // write mode
        sel = 0;                  // select lower half
        data_in = 512'hAAAA_BBBB_CCCC_DDDD_1111_2222_3333_4444_5555_6666_7777_8888_9999_AAAA_BBBB_CCCC;
        #20; // wait one clock cycle

        // ----------------------------
        // Write upper 512 bits
        // ----------------------------
        rw = 1;
        sel = 1;                  // select upper half
        data_in = 512'hFFFF_EEEE_DDDD_CCCC_BBBB_AAAA_9999_8888_7777_6666_5555_4444_3333_2222_1111_0000;
        #20;

        // ----------------------------
        // Read lower 512 bits
        // ----------------------------
        rw = 0;                  // read mode
        sel = 0;
        #20;

        // ----------------------------
        // Read upper 512 bits
        // ----------------------------
        rw = 0;
        sel = 1;
        #20;

        // End of simulation
        $stop;
    end

endmodule