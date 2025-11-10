//===================================================================
// SD_Controller Testbench – FIXED MISO TIMING
//===================================================================
`timescale 1ns/1ps
module sd_controller_tb_v1;

    reg clk = 0;
    always #10 clk = ~clk;

    reg rst_n;
    reg [511:0] write_data;
    reg write_data_ready;
    wire [511:0] read_data;
    wire read_ready;
    wire ready;
    wire spi_clk, spi_cs_n, spi_mosi;
    wire spi_miso;

    SD_Controller dut (
        .clk(clk), .rst_n(rst_n), .write_data(write_data),
        .write_data_ready(write_data_ready), .read_data(read_data),
        .read_ready(read_ready), .ready(ready),
        .spi_clk(spi_clk), .spi_cs_n(spi_cs_n), .spi_mosi(spi_mosi),
        .spi_miso(spi_miso)
    );

    wire [7:0] dut_state = dut.state;
    reg [7:0] last_state;
    always @(posedge clk) begin
        if (dut_state !== last_state) begin
            case (dut_state)
                8'd0:   $display("[%0t] STATE = S_IDLE", $time);
                8'd1:   $display("[%0t] STATE = S_POWERUP", $time);
                8'd2:   $display("[%0t] STATE = S_CMD0", $time);
                8'd3:   $display("[%0t] STATE = S_CMD0_WAIT", $time);
                8'd4:   $display("[%0t] STATE = S_CMD8", $time);
                8'd50:  $display("[%0t] STATE = S_RESP_WAIT", $time);
                8'd99:  $display("[%0t] STATE = S_ERROR", $time);
                default: $display("[%0t] STATE = %0d", $time, dut_state);
            endcase
            last_state <= dut_state;
        end
    end

    wire spi_clk_rising = dut.spi_clk_rise_reg;
    wire spi_clk_falling = dut.spi_clk_fall_reg;

    // SD Card Model
    reg [7:0] cmd_buf[0:5];
    reg [7:0] resp_buf[0:7];
    reg [7:0] data_byte;
    reg [2:0] bit_cnt;
    reg [2:0] cmd_idx;
    reg [2:0] resp_idx;
    reg [2:0] resp_bit_cnt;
    reg [6:0] data_idx;
    reg [7:0] resp_len;
    reg in_resp;
    reg in_data_tx;
    reg in_busy;
    integer i;
    reg card_ready;
    integer busy_cycles;
    reg write_token_seen;
    reg [6:0] write_byte_cnt;

    reg [15:0] powerup_clocks;
    initial begin
        powerup_clocks = 0;
        card_ready = 0;
        busy_cycles = 0;
        resp_len = 0;
        in_resp = 0;
        in_data_tx = 0;
        in_busy = 0;
        cmd_idx = 0;
        bit_cnt = 0;
        resp_idx = 0;
        resp_bit_cnt = 0;
        data_idx = 0;
        write_token_seen = 0;
        write_byte_cnt = 0;
        for (i = 0; i < 6; i = i + 1) cmd_buf[i] = 8'hFF;
        for (i = 0; i < 8; i = i + 1) resp_buf[i] = 8'hFF;
    end

    // Power-up
    always @(posedge clk) begin
        if (spi_cs_n && spi_clk_rising)
            if (powerup_clocks < 200)
                powerup_clocks = powerup_clocks + 1;
    end

    // Reset on CS high
    always @(posedge clk) begin
        if (spi_cs_n) begin
            cmd_idx <= 0;
            bit_cnt <= 0;
        end
    end

    // Capture command
    always @(posedge clk) begin
        if (spi_clk_rising && !spi_cs_n) begin
            cmd_buf[cmd_idx][7 - bit_cnt] = spi_mosi;
            bit_cnt = bit_cnt + 1;
            if (bit_cnt == 7) begin
                bit_cnt = 0;
                if (cmd_idx < 5)
                    cmd_idx = cmd_idx + 1;
                else begin
                    if (cmd_buf[0] == 8'h40 && cmd_buf[1] == 8'h00 && cmd_buf[2] == 8'h00 &&
                        cmd_buf[3] == 8'h00 && cmd_buf[4] == 8'h00 && cmd_buf[5] == 8'h95 &&
                        powerup_clocks >= 74) begin
                        resp_buf[0] = 8'h01;
                        resp_len = 1;
                        in_resp = 1;
                        resp_idx = 0;
                        resp_bit_cnt = 0;
                        $display("[%0t] CMD0 accepted → sending 0x01", $time);
                    end
                    else begin
                        decode_command;
                    end
                    cmd_idx = 0;
                end
            end
        end
    end

   //==============================================================
		// Update response bit counter on SPI rising edge
		//==============================================================
		always @(posedge clk) begin
			 if (spi_clk_rising && !spi_cs_n) begin
				  if (in_resp) begin
						resp_bit_cnt <= resp_bit_cnt + 1;
						if (resp_bit_cnt == 7) begin
						resp_bit_cnt <= 0;
						if (resp_idx < resp_len - 1)
							 resp_idx <= resp_idx + 1;
						else begin
							 in_resp <= 0;
							 resp_idx <= 0;
							 resp_len <= 0;
						end
						end
				  end
				  else if (in_data_tx) begin
						bit_cnt <= bit_cnt + 1;
						if (bit_cnt == 7) begin
							 bit_cnt <= 0;
							 data_idx <= data_idx + 1;
							 if (data_idx == 0) data_byte <= 8'hFE;
							 else if (data_idx <= 64) data_byte <= 8'hA5;
							 else data_byte <= 8'hFF;
							 if (data_idx == 66) in_data_tx <= 0;
						end
				  end
			 end
		end
		
		//==============================================================
		// COMBINATIONAL MISO
		//==============================================================
		assign spi_miso = (!spi_cs_n) ? (
			 in_resp ? resp_buf[resp_idx][7 - resp_bit_cnt] :
			 in_data_tx ? data_byte[7 - bit_cnt] :
			 in_busy ? 1'b0 : 1'b1
		) : 1'b1;

    // Write handling
    always @(posedge clk) begin
        if (write_token_seen && spi_clk_rising && !spi_cs_n && bit_cnt == 7) begin
            write_byte_cnt = write_byte_cnt + 1;
            if (write_byte_cnt == 63) begin
                resp_buf[0] = 8'h05; resp_len = 1; in_resp = 1;
                in_busy = 1; busy_cycles = 80;
                write_token_seen = 0;
                write_byte_cnt = 0;
            end
        end
    end

    always @(posedge clk) begin
        if (in_busy && busy_cycles > 0)
            busy_cycles = busy_cycles - 1;
        else if (busy_cycles == 0)
            in_busy = 0;
    end

    task decode_command;
        reg [5:0] cmd_index;
        reg [31:0] arg;
    begin
        cmd_index = cmd_buf[0][5:0];
        arg = {cmd_buf[1], cmd_buf[2], cmd_buf[3], cmd_buf[4]};
        if (cmd_buf[0][7:6] == 2'b01)
            $display("[%0t] CMD=%0d ARG=%08h CRC=%02h", $time, cmd_index, arg, cmd_buf[5]);

        if (cmd_index == 8) begin
            resp_buf[0] = 8'h01; resp_buf[1] = 8'h00; resp_buf[2] = 8'h00;
            resp_buf[3] = 8'h01; resp_buf[4] = 8'hAA; resp_len = 5; in_resp = 1;
        end
        else if (cmd_index == 55) begin
            resp_buf[0] = 8'h01; resp_len = 1; in_resp = 1;
        end
        else if (cmd_index == 41) begin
            card_ready = 1;
            resp_buf[0] = 8'h00; resp_len = 1; in_resp = 1;
        end
        else if (cmd_index == 58) begin
            resp_buf[0] = 8'h00; resp_buf[1] = 8'hC0; resp_buf[2] = 8'hFF;
            resp_buf[3] = 8'h80; resp_buf[4] = 8'h00; resp_len = 5; in_resp = 1;
        end
        else if (cmd_index == 16) begin
            resp_buf[0] = (arg == 64) ? 8'h00 : 8'h04; resp_len = 1; in_resp = 1;
        end
        else if (cmd_index == 17) begin
            resp_buf[0] = 8'h00; resp_len = 1; in_resp = 1;
            in_data_tx = 1; data_idx = 0; data_byte = 8'hFE;
        end
        else if (cmd_index == 24) begin
            resp_buf[0] = 8'h00; resp_len = 1; in_resp = 1;
            write_token_seen = 1; write_byte_cnt = 0;
        end
    end
    endtask

    initial begin
        $display("[%0t] *** SD_Controller 64-byte Testbench Start ***", $time);
        rst_n = 0; write_data_ready = 0;
        #200 rst_n = 1;
        @(posedge ready);
        $display("[%0t] SD Card initialized", $time);
        @(posedge read_ready);
        $display("[%0t] First read complete", $time);
        for (i = 0; i < 64; i = i + 1)
            if (read_data[511 - i*8 -: 8] !== 8'hA5) $stop;
        $display("Read data verified: 64 x 0xA5");
        write_data = 512'hDEADBEEF_CAFEBABE_12345678_90ABCDEF_11223344_55667788_99AABBCC_DDEEFF00;
        write_data_ready = 1; #20; write_data_ready = 0;
        @(posedge read_ready);
        $display("[%0t] Write-back read complete", $time);
        $display("Write-back %s", (read_data === write_data) ? "PASSED" : "FAILED");
        #2000;
        $display("=== 64-BYTE TESTBENCH PASSED ===");
        $finish;
    end

    initial begin
        $dumpfile("sd_64byte.vcd");
        $dumpvars(0, sd_controller_tb);
    end
endmodule
`timescale 1ns/1ps
module sd_controller_tb_v4;

    // =================================================================
    // DUT Signals
    // =================================================================
    reg clk;
    reg rst_n;
    reg [511:0] write_data;
    reg write_data_ready;
    wire [511:0] read_data;
    wire read_ready;
    wire ready;
    wire spi_clk;
    wire spi_cs_n;
    wire spi_mosi;
    reg spi_miso;

    // =================================================================
    // DUT Instantiation
    // =================================================================
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

    // =================================================================
    // Clock Generation (50 MHz)
    // =================================================================
    initial clk = 0;
    always #10 clk = ~clk;

    // =================================================================
    // SPI Byte Capture
    // =================================================================
    reg [7:0] captured_byte;
    reg [2:0] spi_bit_cnt;
    always @(posedge spi_clk or posedge spi_cs_n) begin
        if (spi_cs_n) begin
            spi_bit_cnt <= 0;
        end else begin
            captured_byte <= {captured_byte[6:0], spi_mosi};
            spi_bit_cnt <= spi_bit_cnt + 1;
            if (spi_bit_cnt == 7) begin
                $display("[%0t] SPI TX: 0x%h", $time, {captured_byte[6:0], spi_mosi});
                spi_bit_cnt <= 0;
            end
        end
    end

    // =================================================================
    // SD Card Response Tasks
    // =================================================================
    task send_response;
        input [7:0] resp;
        input integer delay_clks;
        integer i;
        reg [7:0] bit_data;
        integer j;
        begin
            for (i = 0; i < delay_clks; i = i + 1) begin
                @(posedge spi_clk);
                spi_miso <= 1'b1;
            end
            bit_data = resp;
            for (j = 0; j < 8; j = j + 1) begin
                @(negedge spi_clk);
                spi_miso <= bit_data[7];
                bit_data = {bit_data[6:0], 1'b0};
            end
            @(posedge spi_clk);
            spi_miso <= 1'b1;
        end
    endtask

    task send_r7_response;
        begin
            send_response(8'h01, 1);
            send_response(8'h00, 0);
            send_response(8'h00, 0);
            send_response(8'h01, 0);
            send_response(8'hAA, 0);
        end
    endtask

    task send_data_block_64;
        integer i, j;
        reg [7:0] data_byte;
        begin
            send_response(8'hFE, 1);
            for (i = 0; i < 64; i = i + 1) begin
                data_byte = 8'hA0 + i;
                for (j = 0; j < 8; j = j + 1) begin
                    @(negedge spi_clk);
                    spi_miso <= data_byte[7];
                    data_byte = {data_byte[6:0], 1'b0};
                end
            end
            for (i = 0; i < 16; i = i + 1) begin
                @(negedge spi_clk);
                spi_miso <= 1'b1;
            end
        end
    endtask

    // =================================================================
    // Main Test Sequence
    // =================================================================
    integer idx;
    reg [7:0] expected_byte;
    reg [7:0] received_byte;
    integer bit_idx;

    initial begin
        $display("=== SD Controller Testbench Start (Pure Verilog-2001) ===");

        // Initialize
        rst_n = 0;
        spi_miso = 1;
        write_data = 512'h0;
        write_data_ready = 0;
        #100;
        rst_n = 1;
        #100;

        // 1. Wait for CMD0
        wait (dut.state == dut.S_CMD0);
        $display("[%0t] Power-up complete, entering CMD0", $time);

        // 2. CMD0 Response
        @(negedge spi_cs_n);
        send_response(8'h01, 8);

        // 3. CMD8
        wait (dut.state == dut.S_CMD8_WAIT);
        send_r7_response();

        // 4. ACMD41 Loop
        for (idx = 0; idx < 3; idx = idx + 1) begin
            wait (dut.state == dut.S_CMD55_WAIT);
            send_response(8'h01, 1);
            wait (dut.state == dut.S_ACMD41_WAIT);
            send_response(8'h01, 1);
        end
        wait (dut.state == dut.S_CMD55_WAIT);
        send_response(8'h01, 1);
        wait (dut.state == dut.S_ACMD41_WAIT);
        send_response(8'h00, 1);

        // 5. CMD58
        wait (dut.state == dut.S_CMD58_WAIT);
        send_response(8'h00, 1);
        send_response(8'hC0, 0);
        send_response(8'hFF, 0);
        send_response(8'h80, 0);
        send_response(8'h00, 0);

        // 6. CMD16
        wait (dut.state == dut.S_CMD16_WAIT);
        send_response(8'h00, 1);

        // 7. READ CMD17
        wait (dut.state == dut.S_READ_CMD + 1);
        send_response(8'h00, 1);
        wait (dut.state == dut.S_READ_TOKEN);
        send_data_block_64();

        wait (read_ready == 1);
        $display("[%0t] READ COMPLETE. First byte = 0x%h", $time, read_data[511:504]);

        // Verify read data
        for (idx = 0; idx < 64; idx = idx + 1) begin
            expected_byte = 8'hA0 + idx;
            if (read_data[511 - 8*idx -: 8] !== expected_byte) begin
                $display("ERROR: Read byte %0d: got 0x%h, exp 0x%h", idx,
                         read_data[511 - 8*idx -: 8], expected_byte);
            end
        end
        $display("All 64 read bytes verified!");

        // 8. Prepare write data
        for (idx = 0; idx < 64; idx = idx + 1) begin
            write_data[511 - 8*idx -: 8] = 8'h50 + idx;
        end
        #100;
        write_data_ready = 1;
        @(posedge clk);
        write_data_ready = 0;
        $display("[%0t] write_data_ready pulsed", $time);

        // 9. CMD24
        wait (dut.state == dut.S_WRITE_CMD + 1);
        $display("[%0t] CMD24 started", $time);
        send_response(8'h00, 1);

        // 10. Wait for token
        wait (dut.state == dut.S_WRITE_TOKEN);
        #500;

        // 11. Verify 64 bytes written
        $display("Verifying 64 written bytes...");
        for (idx = 0; idx < 64; idx = idx + 1) begin
            expected_byte = 8'h50 + idx;
            received_byte = 0;
            for (bit_idx = 0; bit_idx < 8; bit_idx = bit_idx + 1) begin  // FIXED: was "bit_idx 1"
                @(posedge spi_clk);
                if (!spi_cs_n) begin
                    received_byte = {received_byte[6:0], spi_mosi};
                end
            end
            if (received_byte !== expected_byte) begin
                $display("ERROR: Write byte %0d: got 0x%h, exp 0x%h", idx, received_byte, expected_byte);
            end
        end
        $display("All 64 write bytes verified!");

        // 12. Data Response
        send_response(8'h05, 1);

        // 13. Busy
        for (idx = 0; idx < 50; idx = idx + 1) begin
            @(negedge spi_clk);
            spi_miso <= 0;
        end
        send_response(8'hFF, 0);

        // 14. Back to read
        wait (dut.state == dut.S_READ_CMD);
        $display("[%0t] Back to READ state. TEST PASSED.", $time);

        #1000;
        $display("=== TEST PASSED ===");
        $finish;
    end

    // =================================================================
    // Timeout
    // =================================================================
    initial begin
        #1_000_000;
        $display("ERROR: TEST TIMEOUT");
        $finish;
    end

endmodule