`timescale 1ns/1ps
module sd_encr_device_tb;

    // ------------------------------------------------------------
    // DUT ports
    // ------------------------------------------------------------
    reg  clk;
    reg  rst;
    reg  start;
    reg  rw_flag;
    wire done;

    wire sd_clk;
    wire sd_cs_n;
    wire sd_mosi;
    reg  sd_miso;

    reg  key_rw;
    reg  key_sel;
    reg  [511:0] key_data_in;
    wire [511:0] key_data_out;

    // ------------------------------------------------------------
    // DUT
    // ------------------------------------------------------------
    sd_encr_device dut (
        .clk           (clk),
        .rst           (rst),
        .start         (start),
        .rw_flag       (rw_flag),
        .done          (done),
        .sd_clk        (sd_clk),
        .sd_cs_n       (sd_cs_n),
        .sd_mosi       (sd_mosi),
        .sd_miso       (sd_miso),
        .key_rw        (key_rw),
        .key_sel       (key_sel),
        .key_data_in   (key_data_in),
        .key_data_out  (key_data_out)
    );

    // Tie off SD SPI
    assign sd_clk  = 1'b0;
    assign sd_cs_n = 1'b1;
    assign sd_mosi = 1'b0;

    // ------------------------------------------------------------
    // FORCE BYPASS: SD_Controller
    // ------------------------------------------------------------
    assign dut.sd_ready      = 1'b1;
    assign dut.sd_read_ready = 1'b1;
    assign dut.sd_data_in    = 512'd0;

    // ------------------------------------------------------------
    // Direct access to XOR engine
    // ------------------------------------------------------------
    reg         xor_start;
    reg         xor_rw;
    reg  [511:0] xor_data_in;
    reg         xor_data_valid;
    wire        xor_ready;
    wire [511:0] xor_data_out;
    wire        xor_done;

    assign dut.u_xor_encr.start         = xor_start;
    assign dut.u_xor_encr.rw_flag       = xor_rw;
    assign dut.u_xor_encr.sd_data_in    = xor_data_in;
    assign dut.u_xor_encr.sd_data_valid = xor_data_valid;
    assign xor_ready                    = dut.u_xor_encr.sd_ready;
    assign xor_data_out                 = dut.u_xor_encr.sd_data_out;
    assign xor_done                     = dut.u_xor_encr.done;

    // ------------------------------------------------------------
    // Clock
    // ------------------------------------------------------------
    initial clk = 0;
    always #10 clk = ~clk;

    // ------------------------------------------------------------
    // Tasks
    // ------------------------------------------------------------
    task load_key(input [511:0] k);
        begin
            key_rw = 1; key_sel = 0; key_data_in = k; #20; key_rw = 0;
            $display("[%0t] Key loaded into regfile", $time);
            repeat(3) @(posedge clk);
        end
    endtask

    task run_xor(input [511:0] data, input enc);
        begin
            // Step 1: Provide data + valid
            xor_data_in = data;
            xor_data_valid = 1;
            xor_rw = enc;
            @(posedge clk);
            xor_data_valid = 0;

            // Step 2: Wait one cycle for FSM to see valid
            @(posedge clk);

            // Step 3: Pulse start
            xor_start = 1;
            @(posedge clk);
            xor_start = 0;

            // Step 4: Wait for done
            @(posedge xor_done);
            $display("[%0t] XOR %s done", $time, enc ? "encrypt" : "decrypt");
        end
    endtask

    // ------------------------------------------------------------
    // Main Test
    // ------------------------------------------------------------
    integer i;
    reg [511:0] plain, cipher, key, expected;

    initial begin
        $display("=== FINAL XOR-ONLY TESTBENCH (CORRECT TIMING) ===");

        // Reset
        rst = 1;
        xor_start = 0; xor_data_valid = 0; sd_miso = 1;
        #200; rst = 0; #200;

        // Load key
        key = 512'h0123_4567_89AB_CDEF_FEDC_BA98_7654_3210_1122_3344_5566_7788_99AA_BBCC_DDEE_FF00;
        load_key(key);

        // Build plain block
        plain = 0;
        for (i = 0; i < 64; i = i + 1)
            plain[511 - 8*i -: 8] = i[7:0];

        // ------------------------------------------------
        // ENCRYPTION
        // ------------------------------------------------
        $display("\n--- ENCRYPTION ---");
        run_xor(plain, 1);
        cipher = xor_data_out;

        expected = plain ^ key;
        if (cipher !== expected) begin
            $error("ENCRYPT FAIL");
            $display("  Got: %h", cipher);
            $display("  Exp: %h", expected);
            $finish;
        end else $display("ENCRYPT SUCCESS");

        // ------------------------------------------------
        // DECRYPTION
        // ------------------------------------------------
        $display("\n--- DECRYPTION ---");
        run_xor(cipher, 0);
        plain = xor_data_out;

        expected = cipher ^ key;
        if (plain !== expected) begin
            $error("DECRYPT FAIL");
            $display("  Got: %h", plain);
            $display("  Exp: %h", expected);
            $finish;
        end else $display("DECRYPT SUCCESS");

        #1000;
        $display("=== ALL TESTS PASSED (SD BYPASSED) ===");
        $finish;
    end

    initial #10_000_000 begin $error("TIMEOUT"); $finish; end
endmodule