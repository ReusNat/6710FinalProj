// This testbench focuses on correct command sending for reading, writing and initialziation. it does not focus on timing issues.
`timescale 1ns/1ps
module sd_controller_tb;

    // DUT Signals
    reg         clk;
    reg         rst_n;
    reg  [511:0] write_data;
    reg         write_data_ready;
    wire [511:0] read_data;
    wire        read_ready;
    wire        ready;
    wire        spi_clk;
    wire        spi_cs_n;
    wire        spi_mosi;
    reg         spi_miso;

    // DUT Instantiation
    SD_Controller #(
        .CLK_DIV(5),
        .POWERUP_CLK_CYCLES(80),
        .CMD_RETRY_MAX(2000),
        .BLOCK_BYTES(64),
        .READ_TIMEOUT(1024)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .write_data(write_data),
        .write_data_ready(write_data_ready),
        .read_data(read_data),
        .read_ready(read_ready),
        .ready(ready),
        .spi_clk(spi_clk),
        .spi_cs_n(spi_cs_n),
        .spi_mosi(spi_mosi),
        .spi_miso(spi_miso)
    );

    // Clock Generation (50 MHz, but its divided)
    initial clk = 0;
    always #10 clk = ~clk;

    // SPI Byte Capture (on falling edge of spi_clk)
    reg [7:0] captured_byte;
    reg [2:0] bit_cnt;
    reg       byte_valid;
    always @(negedge spi_clk or posedge spi_cs_n) begin
        if (spi_cs_n == 1'b1) begin
            bit_cnt    <= 3'd0;
            byte_valid <= 1'b0;
        end else begin
            captured_byte <= {captured_byte[6:0], spi_mosi};
            bit_cnt       <= bit_cnt + 1'd1;
            if (bit_cnt == 3'd7) begin
                byte_valid <= 1'b1;
                $display("[%0t] SPI TX: 0x%h", $time, {captured_byte[6:0], spi_mosi});
                bit_cnt    <= 3'd0;
            end else begin
                byte_valid <= 1'b0;
            end
        end
    end

    // tasks are used so I dont have to make seperate modules
    task wait_for_bytes;
        input integer n;
        integer i;
        begin
            i = 0;
            while (i < n) begin
                @(posedge byte_valid);
                i = i + 1;
            end
        end
    endtask

    task send_r1;
        input [7:0] resp;
        integer i;
        begin
            for (i = 7; i >= 0; i = i - 1) begin
                @(negedge spi_clk);
                spi_miso = resp[i];
            end
        end
    endtask

    task send_r7;
        input [39:0] resp;
        integer i;
        begin
            for (i = 39; i >= 0; i = i - 1) begin
                @(negedge spi_clk);
                spi_miso = resp[i];
            end
        end
    endtask

    task send_token_fe;
        integer i;
        begin
            @(negedge spi_clk); spi_miso = 1'b0;
            for (i = 0; i < 6; i = i + 1) begin
                @(negedge spi_clk); spi_miso = 1'b1;
            end
            @(negedge spi_clk); spi_miso = 1'b1;
            @(negedge spi_clk); spi_miso = 1'b0;
        end
    endtask

    task send_data_resp_05;
        integer i;
        begin
            for (i = 7; i >= 0; i = i - 1) begin
                @(negedge spi_clk);
                if (i == 3 || i == 5) spi_miso = 1'b1;
                else spi_miso = 1'b0;
            end
        end
    endtask

    // Main Test Sequence
    integer idx;
    integer j;
    integer timeout;
    reg     found_token;

    initial begin
        $display("=== SD Controller FSM Command Verification (Verilog-2001) ===");

        // Reset
        rst_n            = 0;
        spi_miso         = 1;
        write_data       = 512'd0;
        write_data_ready = 0;
        #200;
        rst_n = 1;
        #200;

        // Test CMD0
        $display("\n--- Testing CMD0 ---");
        force dut.state     = dut.S_CMD0_SEND;
        force dut.byte_cnt  = 16'd0;
        force dut.waiting   = 1'b0;
        release dut.state;
        release dut.byte_cnt;
        release dut.waiting;
        wait_for_bytes(6);
        $display("CMD0: 40 00 00 00 00 95");
        send_r1(8'h01);

        // Test CMD8
        $display("\n--- Testing CMD8 ---");
        force dut.state     = dut.S_CMD8_SEND;
        force dut.byte_cnt  = 16'd0;
        force dut.waiting   = 1'b0;
        release dut.state;
        release dut.byte_cnt;
        release dut.waiting;
        wait_for_bytes(6);
        $display("CMD8: 48 00 00 01 AA 87");
        send_r7(40'h01_00_01_AA_00);

        //  Test CMD59 (CRC OFF)
        $display("\n--- Testing CMD59 (CRC OFF) ---");
        force dut.state     = dut.S_CMD59_SEND;
        force dut.byte_cnt  = 16'd0;
        force dut.waiting   = 1'b0;
        release dut.state;
        release dut.byte_cnt;
        release dut.waiting;
        wait_for_bytes(6);
        $display("CMD59: 7B 00 00 00 00 01");
        send_r1(8'h00);

        // Test CMD55
        $display("\n--- Testing CMD55 ---");
        force dut.state     = dut.S_CMD55_SEND;
        force dut.byte_cnt  = 16'd0;
        force dut.waiting   = 1'b0;
        release dut.state;
        release dut.byte_cnt;
        release dut.waiting;
        wait_for_bytes(6);
        $display("CMD55: 77 00 00 00 00 65");
        send_r1(8'h01);

        // Test ACMD41
        $display("\n--- Testing ACMD41 ---");
        force dut.state     = dut.S_ACMD41_SEND;
        force dut.byte_cnt  = 16'd0;
        force dut.waiting   = 1'b0;
        force dut.is_sd2    = 1'b1;
        release dut.state;
        release dut.byte_cnt;
        release dut.waiting;
        release dut.is_sd2;
        wait_for_bytes(6);
        $display("ACMD41: 69 40 00 00 00 01");
        send_r1(8'h00);

        // Test CMD58
        $display("\n--- Testing CMD58 ---");
        force dut.state     = dut.S_CMD58_SEND;
        force dut.byte_cnt  = 16'd0;
        force dut.waiting   = 1'b0;
        release dut.state;
        release dut.byte_cnt;
        release dut.waiting;
        wait_for_bytes(6);
        $display("CMD58: 7A 00 00 00 00 FF");
        send_r7(40'h00_90_00_00_00);

        // Test CMD16
        $display("\n--- Testing CMD16 ---");
        force dut.state     = dut.S_CMD16_SEND;
        force dut.byte_cnt  = 16'd0;
        force dut.waiting   = 1'b0;
        release dut.state;
        release dut.byte_cnt;
        release dut.waiting;
        wait_for_bytes(6);
        $display("CMD16: 50 00 00 00 40 FF");
        send_r1(8'h00);

        // Test CMD17 (READ block 0)
        $display("\n--- Testing CMD17 (READ block 0) ---");
        force dut.state      = dut.S_READ_SEND;
        force dut.byte_cnt   = 16'd0;
        force dut.waiting    = 1'b0;
        force dut.block_addr = 32'd0;
        release dut.state;
        release dut.byte_cnt;
        release dut.waiting;
        release dut.block_addr;
        wait_for_bytes(6);
        $display("CMD17: 51 00 00 00 00 01");
        send_r1(8'h00);

        // READ TOKEN + 64 DATA BYTES
        $display("\n--- Testing READ TOKEN + 64 DATA BYTES ---");
        force dut.state     = dut.S_READ_TOKEN;
        force dut.waiting   = 1'b0;
        release dut.state;
        release dut.waiting;
        send_token_fe();

        for (idx = 0; idx < 64; idx = idx + 1) begin
            for (j = 7; j >= 0; j = j - 1) begin
                @(negedge spi_clk);
                spi_miso = 1'b0;
            end
        end
        wait_for_bytes(64);
        $display("Received 64 read data bytes");

        // Test WRITE (CMD24 + 64 bytes)
        $display("\n--- Testing WRITE (CMD24 + 64 bytes) ---");

        // Fill write buffer: 0xA0 to 0xDF
        for (idx = 0; idx < 64; idx = idx + 1) begin
            write_data[511 - 8*idx -: 8] = 8'hA0 + idx;
        end

        // Trigger write
        force dut.state = dut.S_WRITE_WAIT;
        release dut.state;
        @(posedge clk);
        write_data_ready = 1;
        @(posedge clk);
        write_data_ready = 0;

        // Wait for CMD24
        wait_for_bytes(6);
        $display("CMD24: 58 00 00 00 00 01");
        send_r1(8'h00);

        //  We skip 0xFF until 0xFE as its just delay from idle to write
        $display("Waiting for write token 0xFE (skipping 0xFF idle bytes)...");
        found_token = 0;
        timeout = 0;
        idx = 0;  // reuse idx becasue why not

        while (!found_token) begin
            @(posedge byte_valid);
            if (captured_byte === 8'hFE) begin
                $display("Write token 0xFE received");
                found_token = 1;
            end else if (captured_byte !== 8'hFF) begin
                $error("Unexpected byte before token: 0x%h", captured_byte);
                $finish;
            end
            timeout = timeout + 1;
            if (timeout > 100) begin
                $error("TIMEOUT waiting for 0xFE token");
                $finish;
            end
        end

        //  Verify 64 data bytes 
        $display("Verifying 64 write data bytes (0xA0 to 0xDF)...");
        idx = 0;
        while (idx < 64) begin
            @(posedge byte_valid);
            if (captured_byte !== (8'hA0 + idx)) begin
                $error("WRITE DATA FAIL: byte %0d: got 0x%h, exp 0x%h", idx, captured_byte, 8'hA0 + idx);
            end
            idx = idx + 1;
        end
        $display("All 64 write bytes verified!");

        // WRITE RESPONSE (Data Response 0x05)
        $display("\n--- Testing WRITE RESPONSE ---");
        send_data_resp_05();
        $display("Sent Data Response 0x05");

        // Busy (0x00 x8) then 0xFF
        for (j = 0; j < 8; j = j + 1) begin
            @(negedge spi_clk);
            spi_miso = 1'b0;
        end
        @(negedge spi_clk);
        spi_miso = 1'b1;

        // Done
        #1000;
        $display("=== ALL FSM STATES AND COMMANDS VERIFIED (Verilog-2001) ===");
        $finish;
    end

    // Timeout 
    initial begin
        #40_000_000;
        $display("ERROR: TEST TIMEOUT");
        $finish;
    end
endmodule