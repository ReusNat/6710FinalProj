// sd_mock_tb.v – VERILOG-2001 ONLY, NO break, NO SystemVerilog
`timescale 1ns/1ps
module sd_mock_tb;
    reg clk;
    reg rst_n;
    reg spi_cs_n;
    wire spi_mosi;
    wire spi_miso;
    reg spi_clk;
    reg start;
    reg [7:0] tx_data;
    wire [7:0] rx_data;
    wire done;
    reg spi_clk_dly;
    wire spi_clk_rising = spi_clk & ~spi_clk_dly;
    wire spi_clk_falling = ~spi_clk & spi_clk_dly;

    spi_transactor u_spi (
        .clk(clk),
        .rst_n(rst_n),
        .spi_clk_rising(spi_clk_rising),
        .spi_clk_falling(spi_clk_falling),
        .start(start),
        .tx_data(tx_data),
        .rx_data(rx_data),
        .done(done),
        .spi_mosi(spi_mosi),
        .spi_miso(spi_miso)
    );

    sd_mock u_sd (
        .clk(clk),
        .rst_n(rst_n),
        .spi_cs_n(spi_cs_n),
        .spi_clk(spi_clk),
        .spi_mosi(spi_mosi),
        .spi_miso(spi_miso)
    );

    always #10 clk = ~clk;
    always #80 spi_clk = ~spi_clk;
    always @(posedge clk) spi_clk_dly <= spi_clk;

    integer error_cnt;
    integer i, j, k;
    integer resp_cnt;
    reg [7:0] byte_to_send;
    reg [7:0] exp_data;

    task send_byte;
        input [7:0] data;
    begin
        wait (spi_clk);  // Synchronize: start transfer when spi_clk is high
        tx_data = data;
        start = 1;
        @(posedge clk);
        start = 0;
        @(posedge done);
        @(posedge clk);
    end
    endtask

    task send_cmd;
        input [5:0] cmd;
        input [31:0] arg;
        input [7:0] crc;
    begin
        $display("\n[%t] TB: >>> CMD%0d arg=0x%08h crc=0x%02h", $time, cmd, arg, crc);
        spi_cs_n = 1'b0;
        @(posedge clk);
        send_byte({2'b01, cmd});
        send_byte(arg[31:24]);
        send_byte(arg[23:16]);
        send_byte(arg[15:8]);
        send_byte(arg[7:0]);
        send_byte(crc);
        resp_cnt = 0;
        while (resp_cnt < 8) begin
            send_byte(8'hFF);
            if (rx_data !== 8'hFF) begin
                $display("[%t] TB: R1 = 0x%02h", $time, rx_data);
                resp_cnt = 8;
            end else begin
                resp_cnt = resp_cnt + 1;
            end
        end
        if (resp_cnt >= 8 && rx_data === 8'hFF) begin
            $error("R1 timeout after 8 bytes");
            error_cnt = error_cnt + 1;
        end else if (cmd == 0) begin
            if (rx_data !== 8'h01) begin
                $error("R1 for CMD0 wrong: got 0x%02h", rx_data);
                error_cnt = error_cnt + 1;
            end
        end else begin
            if (rx_data !== 8'h00) begin
                $error("R1 for CMD%0d wrong: got 0x%02h", cmd, rx_data);
                error_cnt = error_cnt + 1;
            end
        end
        spi_cs_n = 1'b1;
        repeat (10) @(posedge clk);
    end
    endtask

    task read_block;
        input [31:0] addr;
        reg token_found;
    begin
        $display("[%t] TB: <<< READ BLOCK 0x%08h", $time, addr);
        send_cmd(17, addr, 8'h01);
        spi_cs_n = 1'b0;
        @(posedge clk);
        token_found = 1'b0;
        while (token_found == 1'b0) begin
            send_byte(8'hFF);
            if (rx_data === 8'hFE) begin
                $display("[%t] TB: data token 0xFE received", $time);
                token_found = 1'b1;
                @(posedge clk);
            end
        end
        for (k = 0; k < 64; k = k + 1) begin
            send_byte(8'hFF);
            exp_data = (addr + k) ^ 8'hA5;
            if (rx_data !== exp_data) begin
                $error("READ[%0d] mismatch: exp 0x%02h got 0x%02h", k, exp_data, rx_data);
                error_cnt = error_cnt + 1;
            end
        end
        repeat (2) send_byte(8'hFF);
        spi_cs_n = 1'b1;
        repeat (20) @(posedge clk);
    end
    endtask

    task write_block;
        input [31:0] addr;
    begin
        $display("[%t] TB: >>> WRITE BLOCK 0x%08h", $time, addr);
        send_cmd(24, addr, 8'h01);
        spi_cs_n = 1'b0;
        @(posedge clk);
        send_byte(8'hFE);
        for (k = 0; k < 64; k = k + 1) begin
            send_byte(k[7:0] ^ 8'h5A);
        end
        repeat (2) send_byte(8'hFF);
        send_byte(8'hFF);
        if ((rx_data & 8'h1F) !== 5'h05) begin
            $error("WRITE response error: got 0x%02h", rx_data);
            error_cnt = error_cnt + 1;
        end
        repeat (50) send_byte(8'hFF);
        spi_cs_n = 1'b1;
        repeat (20) @(posedge clk);
    end
    endtask

    initial begin
        clk = 0;
        spi_clk = 0;
        spi_clk_dly = 0;
        rst_n = 0;
        spi_cs_n = 1;
        start = 0;
        tx_data = 8'hFF;
        error_cnt = 0;
        #100 rst_n = 1;
        spi_cs_n = 1'b1;
        repeat (80) send_byte(8'hFF);
        send_cmd( 0, 32'h0000_0000, 8'h95);
        send_cmd( 8, 32'h0000_01AA, 8'h87);
        send_cmd(59, 32'h0000_0000, 8'h01);
        send_cmd(55, 32'h0000_0000, 8'h65);
        send_cmd(41, 32'h4000_0000, 8'h01);
        i = 0;
        while (i < 20) begin
            send_cmd(55, 32'h0000_0000, 8'h65);
            send_cmd(41, 32'h4000_0000, 8'h01);
            if (rx_data === 8'h00) i = 999;
            else i = i + 1;
        end
        send_cmd(58, 32'h0000_0000, 8'hFF);
        send_cmd(16, 32'h0000_0040, 8'hFF);
        read_block(32'd0);
        write_block(32'd0);
        read_block(32'd0);
        #1000;
        if (error_cnt == 0)
            $display("\n=== SD_CARD_MOCK_TB PASSED ===\n");
        else
            $display("\n=== SD_CARD_MOCK_TB FAILED (%0d errors) ===\n", error_cnt);
        $finish;
    end

    initial begin
        #700000 $finish;
    end
endmodule