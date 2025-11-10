// SD_Controller – 64-byte block size, Verilog-2001 only
module SD_Controller (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [511:0] write_data,
    input  wire        write_data_ready,
    output reg  [511:0] read_data,
    output reg         read_ready,
    output reg         ready,
    output wire        spi_clk,
    output wire        spi_cs_n,
    output wire        spi_mosi,
    input  wire        spi_miso
);
parameter CLK_DIV            = 5;
parameter POWERUP_CLK_CYCLES = 80;
parameter CMD_RETRY_MAX      = 2000;
parameter BLOCK_BYTES        = 64;
parameter READ_TIMEOUT       = 1024;

// -------------------------------------------------
// SPI clock divider (Mode 0)
// -------------------------------------------------
reg [3:0] clk_div_cnt;
reg       spi_clk_reg;
reg       spi_clk_rise_reg;
reg       spi_clk_fall_reg;
assign    spi_clk = spi_clk_reg;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        clk_div_cnt       <= 4'd0;
        spi_clk_reg       <= 1'b0;
        spi_clk_rise_reg  <= 1'b0;
        spi_clk_fall_reg  <= 1'b0;
    end else begin
        spi_clk_rise_reg  <= 1'b0;
        spi_clk_fall_reg  <= 1'b0;
        if (clk_div_cnt == (CLK_DIV-1)) begin
            clk_div_cnt       <= 4'd0;
            spi_clk_reg       <= ~spi_clk_reg;
            if (~spi_clk_reg) spi_clk_rise_reg <= 1'b1;
            else              spi_clk_fall_reg <= 1'b1;
        end else begin
            clk_div_cnt <= clk_div_cnt + 1'd1;
        end
    end
end

// -------------------------------------------------
// SPI byte transactor (unchanged)
// -------------------------------------------------
reg        tx_start;
reg  [7:0] tx_data;
wire [7:0] rx_data;
wire       tx_done;
wire       spi_mosi_wire;
assign     spi_mosi = spi_mosi_wire;

spi_transactor u_spi (
    .clk            (clk),
    .rst_n          (rst_n),
    .spi_clk_rising (spi_clk_rise_reg),
    .spi_clk_falling(spi_clk_fall_reg),
    .start          (tx_start),
    .tx_data        (tx_data),
    .rx_data        (rx_data),
    .done           (tx_done),
    .spi_mosi       (spi_mosi_wire),
    .spi_miso       (spi_miso)
);

reg spi_cs_n_reg;
assign spi_cs_n = spi_cs_n_reg;

// -------------------------------------------------
// State encoding (expanded with per-command WAIT states)
// -------------------------------------------------
localparam
    S_IDLE          = 8'd0,
    S_POWERUP       = 8'd1,

    // CMD0
    S_CMD0          = 8'd2, S_CMD0_SEND = 8'd3, S_CMD0_WAIT = 8'd4,

    // CMD8
    S_CMD8          = 8'd5, S_CMD8_SEND = 8'd6, S_CMD8_WAIT = 8'd7,

    // CMD59
    S_CMD59         = 8'd8, S_CMD59_SEND = 8'd9, S_CMD59_WAIT = 8'd10,

    // CMD55
    S_CMD55         = 8'd11, S_CMD55_SEND = 8'd12, S_CMD55_WAIT = 8'd13,

    // ACMD41
    S_ACMD41        = 8'd14, S_ACMD41_SEND = 8'd15, S_ACMD41_WAIT = 8'd16,

    // CMD58
    S_CMD58         = 8'd17, S_CMD58_SEND = 8'd18, S_CMD58_WAIT = 8'd19,

    // CMD16
    S_CMD16         = 8'd20, S_CMD16_SEND = 8'd21, S_CMD16_WAIT = 8'd22,

    // READ (CMD17)
    S_READ_CMD      = 8'd23, S_READ_SEND = 8'd24, S_READ_WAIT = 8'd25,
    S_READ_TOKEN    = 8'd26,
    S_READ_DATA     = 8'd27,

    // WRITE (CMD24)
    S_WRITE_WAIT    = 8'd28,
    S_WRITE_CMD     = 8'd29, S_WRITE_SEND = 8'd30,
    S_WRITE_TOKEN   = 8'd32,
    S_WRITE_DATA    = 8'd33,
    S_WRITE_RESP    = 8'd34,
    S_WRITE_BUSY    = 8'd35,

    S_ERROR         = 8'd99;

// -------------------------------------------------
// Internal registers
// -------------------------------------------------
reg [15:0] powerup_cnt;
reg [15:0] retry_cnt;
reg [15:0] byte_cnt;
reg  [6:0] block_idx;
reg [15:0] timeout;
reg        waiting;
reg        is_sd2;
reg  [7:0] r7_resp[0:4];
reg [31:0] block_addr;
reg  [7:0] write_buf[0:63];
reg  [7:0] rx_byte;
reg        resp_valid;
reg  [3:0] resp_idx;
reg  [7:0] resp_retry_cnt;
reg [15:0] resp_timeout_cnt;

// response-wait parameters (set per command)
reg  [7:0] resp_mask;
reg  [7:0] resp_value;
reg  [3:0] resp_bytes_needed;
reg  [7:0] next_state_after_resp;

// -------------------------------------------------
// Unpack write_data to write_buf (MSB first)
// -------------------------------------------------
integer i;
always @(write_data) begin
    integer i;
    for (i = 0; i < 64; i = i + 1)
        write_buf[i] = write_data[511 - 8*i : 511 - 8*i - 7];
end

// latch received byte
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) rx_byte <= 8'hFF;
    else if (tx_done) rx_byte <= rx_data;
end

// -------------------------------------------------
// Main FSM
// -------------------------------------------------
reg [7:0] state;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state            <= S_IDLE;
        spi_cs_n_reg     <= 1'b1;
        tx_start         <= 1'b0;
        ready            <= 1'b0;
        read_ready       <= 1'b0;
        powerup_cnt      <= 16'd0;
        retry_cnt        <= 16'd0;
        byte_cnt         <= 16'd0;
        block_idx        <= 7'd0;
        timeout          <= 16'd0;
        waiting          <= 1'b0;
        is_sd2           <= 1'b0;
        block_addr       <= 32'd0;
        read_data        <= 512'd0;
        resp_idx         <= 4'd0;
        resp_valid       <= 1'b0;
        resp_retry_cnt   <= 8'd0;
        resp_timeout_cnt <= 16'd0;
        for (i = 0; i < 5; i = i + 1) r7_resp[i] <= 8'd0;
    end else begin
        tx_start   <= 1'b0;
        read_ready <= 1'b0;
        resp_valid <= 1'b0;

        case (state)
            // -------------------------------------------------
            S_IDLE: begin
                ready        <= 1'b0;
                spi_cs_n_reg <= 1'b1;
                state        <= S_POWERUP;
            end

            // -------------------------------------------------
            S_POWERUP: begin
                spi_cs_n_reg <= 1'b1;
                if (powerup_cnt < POWERUP_CLK_CYCLES) begin
                    if (!waiting) begin
                        tx_data  <= 8'hFF;
                        tx_start <= 1'b1;
                        waiting  <= 1'b1;
                    end else if (tx_done) begin
                        waiting     <= 1'b0;
                        powerup_cnt <= powerup_cnt + 1'd1;
                    end
                end else begin
                    state <= S_CMD0;
                end
            end

            // -------------------------------------------------
            // CMD0
            // -------------------------------------------------
            S_CMD0: begin
                spi_cs_n_reg <= 1'b0;
                byte_cnt     <= 16'd0;
                waiting      <= 1'b0;
                resp_retry_cnt <= 8'd0;
                resp_timeout_cnt <= 16'd0;
                state        <= S_CMD0_SEND;
            end
            S_CMD0_SEND: begin
                if (!waiting && byte_cnt < 6) begin
                    case (byte_cnt)
                        0: tx_data <= 8'h40;
                        1: tx_data <= 8'h00;
                        2: tx_data <= 8'h00;
                        3: tx_data <= 8'h00;
                        4: tx_data <= 8'h00;
                        5: tx_data <= 8'h95;
                    endcase
                    tx_start <= 1'b1;
                    waiting  <= 1'b1;
                    byte_cnt <= byte_cnt + 1'd1;
                end else if (tx_done && waiting) begin
                    waiting <= 1'b0;
                    if (byte_cnt == 6) begin
                        // expect R1 = 0x01
                        resp_mask          <= 8'hFF;
                        resp_value         <= 8'h01;
                        resp_bytes_needed  <= 4'd1;
                        next_state_after_resp <= S_CMD8;
                        state              <= S_CMD0_WAIT;
                    end
                end
            end
            S_CMD0_WAIT: begin
                if (!waiting) begin
                    tx_data  <= 8'hFF;
                    tx_start <= 1'b1;
                    waiting  <= 1'b1;
                    resp_timeout_cnt <= resp_timeout_cnt + 1'd1;
                end else if (tx_done) begin
                    waiting <= 1'b0;
                    if (rx_byte != 8'hFF) begin
                        resp_timeout_cnt <= 16'd0;
                        if ((rx_byte & resp_mask) == resp_value) begin
                            r7_resp[0] <= rx_byte;
                            state      <= next_state_after_resp;
                        end else resp_retry_cnt <= resp_retry_cnt + 1'd1;
                    end else if (resp_timeout_cnt > 16'd1000) begin
                        resp_retry_cnt <= resp_retry_cnt + 1'd1;
                    end

                    if (resp_retry_cnt >= 8'd10) begin
                        retry_cnt <= retry_cnt + 1'd1;
                        if (retry_cnt > CMD_RETRY_MAX) state <= S_ERROR;
                        else state <= S_CMD0;
                    end
                end
            end

            // -------------------------------------------------
            // CMD8
            // -------------------------------------------------
            S_CMD8: begin
                spi_cs_n_reg <= 1'b0;
                byte_cnt     <= 16'd0;
                waiting      <= 1'b0;
                resp_retry_cnt <= 8'd0;
                resp_timeout_cnt <= 16'd0;
                state        <= S_CMD8_SEND;
            end
            S_CMD8_SEND: begin
                if (!waiting && byte_cnt < 6) begin
                    case (byte_cnt)
                        0: tx_data <= 8'h48;
                        1: tx_data <= 8'h00;
                        2: tx_data <= 8'h00;
                        3: tx_data <= 8'h01;
                        4: tx_data <= 8'hAA;
                        5: tx_data <= 8'h87;
                    endcase
                    tx_start <= 1'b1;
                    waiting  <= 1'b1;
                    byte_cnt <= byte_cnt + 1'd1;
                end else if (tx_done && waiting) begin
                    waiting <= 1'b0;
                    if (byte_cnt == 6) begin
                        resp_mask          <= 8'hFF;
                        resp_value         <= 8'h01;
                        resp_bytes_needed  <= 4'd5;
                        next_state_after_resp <= S_CMD59;
                        resp_idx           <= 4'd0;
                        state              <= S_CMD8_WAIT;
                    end
                end
            end
            S_CMD8_WAIT: begin
                if (!waiting) begin
                    tx_data  <= 8'hFF;
                    tx_start <= 1'b1;
                    waiting  <= 1'b1;
                    resp_timeout_cnt <= resp_timeout_cnt + 1'd1;
                end else if (tx_done) begin
                    waiting <= 1'b0;
                    if (rx_byte != 8'hFF) begin
                        resp_timeout_cnt <= 16'd0;
                        if ((rx_byte & resp_mask) == resp_value) begin
                            r7_resp[resp_idx] <= rx_byte;
                            if (resp_idx == resp_bytes_needed-1) begin
                                // SD-v2 detection
                                if (r7_resp[0]==8'h01 && r7_resp[3]==8'h01 && r7_resp[4]==8'hAA)
                                    is_sd2 <= 1'b1;
                                state <= next_state_after_resp;
                            end else begin
                                resp_idx <= resp_idx + 1'd1;
                            end
                        end else resp_retry_cnt <= resp_retry_cnt + 1'd1;
                    end else if (resp_timeout_cnt > 16'd1000) begin
                        resp_retry_cnt <= resp_retry_cnt + 1'd1;
                    end

                    if (resp_retry_cnt >= 8'd10) begin
                        retry_cnt <= retry_cnt + 1'd1;
                        if (retry_cnt > CMD_RETRY_MAX) state <= S_ERROR;
                        else state <= S_CMD0;
                    end
                end
            end

            // -------------------------------------------------
            // CMD59 (CRC OFF)
            // -------------------------------------------------
            S_CMD59: begin
                spi_cs_n_reg <= 1'b0;
                byte_cnt     <= 16'd0;
                waiting      <= 1'b0;
                state        <= S_CMD59_SEND;
            end
            S_CMD59_SEND: begin
                if (!waiting && byte_cnt < 6) begin
                    case (byte_cnt)
                        0: tx_data <= 8'h7B;
                        1: tx_data <= 8'h00;
                        2: tx_data <= 8'h00;
                        3: tx_data <= 8'h00;
                        4: tx_data <= 8'h00;
                        5: tx_data <= 8'h01;
                    endcase
                    tx_start <= 1'b1;
                    waiting  <= 1'b1;
                    byte_cnt <= byte_cnt + 1'd1;
                end else if (tx_done && waiting) begin
                    waiting <= 1'b0;
                    if (byte_cnt == 6) begin
                        resp_mask          <= 8'hFF;
                        resp_value         <= 8'h00;
                        resp_bytes_needed  <= 4'd1;
                        next_state_after_resp <= S_CMD55;
                        state              <= S_CMD59_WAIT;
                    end
                end
            end
            S_CMD59_WAIT: begin
                if (!waiting) begin
                    tx_data  <= 8'hFF;
                    tx_start <= 1'b1;
                    waiting  <= 1'b1;
                    resp_timeout_cnt <= resp_timeout_cnt + 1'd1;
                end else if (tx_done) begin
                    waiting <= 1'b0;
                    if (rx_byte != 8'hFF) begin
                        resp_timeout_cnt <= 16'd0;
                        if ((rx_byte & resp_mask) == resp_value) begin
                            state <= next_state_after_resp;
                        end else resp_retry_cnt <= resp_retry_cnt + 1'd1;
                    end else if (resp_timeout_cnt > 16'd1000) begin
                        resp_retry_cnt <= resp_retry_cnt + 1'd1;
                    end

                    if (resp_retry_cnt >= 8'd10) begin
                        retry_cnt <= retry_cnt + 1'd1;
                        if (retry_cnt > CMD_RETRY_MAX) state <= S_ERROR;
                        else state <= S_CMD0;
                    end
                end
            end

            // -------------------------------------------------
            // CMD55
            // -------------------------------------------------
            S_CMD55: begin
                spi_cs_n_reg <= 1'b0;
                byte_cnt     <= 16'd0;
                waiting      <= 1'b0;
                state        <= S_CMD55_SEND;
            end
            S_CMD55_SEND: begin
                if (!waiting && byte_cnt < 6) begin
                    case (byte_cnt)
                        0: tx_data <= 8'h77;
                        1: tx_data <= 8'h00;
                        2: tx_data <= 8'h00;
                        3: tx_data <= 8'h00;
                        4: tx_data <= 8'h00;
                        5: tx_data <= 8'h65;
                    endcase
                    tx_start <= 1'b1;
                    waiting  <= 1'b1;
                    byte_cnt <= byte_cnt + 1'd1;
                end else if (tx_done && waiting) begin
                    waiting <= 1'b0;
                    if (byte_cnt == 6) begin
                        resp_mask          <= 8'hFF;
                        resp_value         <= 8'h01;
                        resp_bytes_needed  <= 4'd1;
                        next_state_after_resp <= S_ACMD41;
                        state              <= S_CMD55_WAIT;
                    end
                end
            end
            S_CMD55_WAIT: begin
                if (!waiting) begin
                    tx_data  <= 8'hFF;
                    tx_start <= 1'b1;
                    waiting  <= 1'b1;
                    resp_timeout_cnt <= resp_timeout_cnt + 1'd1;
                end else if (tx_done) begin
                    waiting <= 1'b0;
                    if (rx_byte != 8'hFF) begin
                        resp_timeout_cnt <= 16'd0;
                        if ((rx_byte & resp_mask) == resp_value) begin
                            state <= next_state_after_resp;
                        end else resp_retry_cnt <= resp_retry_cnt + 1'd1;
                    end else if (resp_timeout_cnt > 16'd1000) begin
                        resp_retry_cnt <= resp_retry_cnt + 1'd1;
                    end

                    if (resp_retry_cnt >= 8'd10) begin
                        retry_cnt <= retry_cnt + 1'd1;
                        if (retry_cnt > CMD_RETRY_MAX) state <= S_ERROR;
                        else state <= S_CMD0;
                    end
                end
            end

            // -------------------------------------------------
            // ACMD41
            // -------------------------------------------------
            S_ACMD41: begin
                spi_cs_n_reg <= 1'b0;
                byte_cnt     <= 16'd0;
                waiting      <= 1'b0;
                retry_cnt    <= retry_cnt + 1'd1;
                if (retry_cnt > CMD_RETRY_MAX) state <= S_ERROR;
                else state <= S_ACMD41_SEND;
            end
            S_ACMD41_SEND: begin
                if (!waiting && byte_cnt < 6) begin
                    case (byte_cnt)
                        0: tx_data <= 8'h69;
                        1: tx_data <= is_sd2 ? 8'h40 : 8'h00;
                        2: tx_data <= 8'h00;
                        3: tx_data <= 8'h00;
                        4: tx_data <= 8'h00;
                        5: tx_data <= 8'h01;
                    endcase
                    tx_start <= 1'b1;
                    waiting  <= 1'b1;
                    byte_cnt <= byte_cnt + 1'd1;
                end else if (tx_done && waiting) begin
                    waiting <= 1'b0;
                    if (byte_cnt == 6) begin
                        resp_mask          <= 8'hFF;
                        resp_value         <= 8'h00;
                        resp_bytes_needed  <= 4'd1;
                        next_state_after_resp <= S_CMD58;
                        state              <= S_ACMD41_WAIT;
                    end
                end
            end
            S_ACMD41_WAIT: begin
                if (!waiting) begin
                    tx_data  <= 8'hFF;
                    tx_start <= 1'b1;
                    waiting  <= 1'b1;
                    resp_timeout_cnt <= resp_timeout_cnt + 1'd1;
                end else if (tx_done) begin
                    waiting <= 1'b0;
                    if (rx_byte != 8'hFF) begin
                        resp_timeout_cnt <= 16'd0;
                        if ((rx_byte & resp_mask) == resp_value) begin
                            state <= next_state_after_resp;
                        end else resp_retry_cnt <= resp_retry_cnt + 1'd1;
                    end else if (resp_timeout_cnt > 16'd1000) begin
                        resp_retry_cnt <= resp_retry_cnt + 1'd1;
                    end

                    if (resp_retry_cnt >= 8'd10) begin
                        retry_cnt <= retry_cnt + 1'd1;
                        if (retry_cnt > CMD_RETRY_MAX) state <= S_ERROR;
                        else state <= S_CMD0;
                    end
                end
            end

            // -------------------------------------------------
            // CMD58
            // -------------------------------------------------
            S_CMD58: begin
                spi_cs_n_reg <= 1'b0;
                byte_cnt     <= 16'd0;
                waiting      <= 1'b0;
                state        <= S_CMD58_SEND;
            end
            S_CMD58_SEND: begin
                if (!waiting && byte_cnt < 6) begin
                    case (byte_cnt)
                        0: tx_data <= 8'h7A;
                        1: tx_data <= 8'h00;
                        2: tx_data <= 8'h00;
                        3: tx_data <= 8'h00;
                        4: tx_data <= 8'h00;
                        5: tx_data <= 8'hFF;
                    endcase
                    tx_start <= 1'b1;
                    waiting  <= 1'b1;
                    byte_cnt <= byte_cnt + 1'd1;
                end else if (tx_done && waiting) begin
                    waiting <= 1'b0;
                    if (byte_cnt == 6) begin
                        resp_mask          <= 8'hFF;
                        resp_value         <= 8'h00;
                        resp_bytes_needed  <= 4'd5;
                        next_state_after_resp <= S_CMD16;
                        resp_idx           <= 4'd0;
                        state              <= S_CMD58_WAIT;
                    end
                end
            end
            S_CMD58_WAIT: begin
                if (!waiting) begin
                    tx_data  <= 8'hFF;
                    tx_start <= 1'b1;
                    waiting  <= 1'b1;
                    resp_timeout_cnt <= resp_timeout_cnt + 1'd1;
                end else if (tx_done) begin
                    waiting <= 1'b0;
                    if (rx_byte != 8'hFF) begin
                        resp_timeout_cnt <= 16'd0;
                        if ((rx_byte & resp_mask) == resp_value) begin
                            r7_resp[resp_idx] <= rx_byte;
                            if (resp_idx == resp_bytes_needed-1) state <= next_state_after_resp;
                            else resp_idx <= resp_idx + 1'd1;
                        end else resp_retry_cnt <= resp_retry_cnt + 1'd1;
                    end else if (resp_timeout_cnt > 16'd1000) begin
                        resp_retry_cnt <= resp_retry_cnt + 1'd1;
                    end

                    if (resp_retry_cnt >= 8'd10) begin
                        retry_cnt <= retry_cnt + 1'd1;
                        if (retry_cnt > CMD_RETRY_MAX) state <= S_ERROR;
                        else state <= S_CMD0;
                    end
                end
            end

            // -------------------------------------------------
            // CMD16 (set block length = 64)
            // -------------------------------------------------
            S_CMD16: begin
                spi_cs_n_reg <= 1'b0;
                byte_cnt     <= 16'd0;
                waiting      <= 1'b0;
                state        <= S_CMD16_SEND;
            end
            S_CMD16_SEND: begin
                if (!waiting && byte_cnt < 6) begin
                    case (byte_cnt)
                        0: tx_data <= 8'h50;
                        1: tx_data <= 8'h00;
                        2: tx_data <= 8'h00;
                        3: tx_data <= 8'h00;
                        4: tx_data <= 8'h40;   // 64 bytes
                        5: tx_data <= 8'hFF;
                    endcase
                    tx_start <= 1'b1;
                    waiting  <= 1'b1;
                    byte_cnt <= byte_cnt + 1'd1;
                end else if (tx_done && waiting) begin
                    waiting <= 1'b0;
                    if (byte_cnt == 6) begin
                        resp_mask          <= 8'hFF;
                        resp_value         <= 8'h00;
                        resp_bytes_needed  <= 4'd1;
                        next_state_after_resp <= S_READ_CMD;
                        state              <= S_CMD16_WAIT;
                    end
                end
            end
            S_CMD16_WAIT: begin
                if (!waiting) begin
                    tx_data  <= 8'hFF;
                    tx_start <= 1'b1;
                    waiting  <= 1'b1;
                    resp_timeout_cnt <= resp_timeout_cnt + 1'd1;
                end else if (tx_done) begin
                    waiting <= 1'b0;
                    if (rx_byte != 8'hFF) begin
                        resp_timeout_cnt <= 16'd0;
                        if ((rx_byte & resp_mask) == resp_value) begin
                            state <= next_state_after_resp;
                        end else resp_retry_cnt <= resp_retry_cnt + 1'd1;
                    end else if (resp_timeout_cnt > 16'd1000) begin
                        resp_retry_cnt <= resp_retry_cnt + 1'd1;
                    end

                    if (resp_retry_cnt >= 8'd10) begin
                        retry_cnt <= retry_cnt + 1'd1;
                        if (retry_cnt > CMD_RETRY_MAX) state <= S_ERROR;
                        else state <= S_CMD0;
                    end
                end
            end

            // -------------------------------------------------
            // READ (CMD17)
            // -------------------------------------------------
            S_READ_CMD: begin
                spi_cs_n_reg <= 1'b0;
                byte_cnt     <= 16'd0;
                block_idx    <= 7'd0;
                timeout      <= 16'd0;
                read_data    <= 512'd0;
                waiting      <= 1'b0;
                state        <= S_READ_SEND;
            end
            S_READ_SEND: begin
                if (!waiting && byte_cnt < 6) begin
                    case (byte_cnt)
                        0: tx_data <= 8'h51;
                        1: tx_data <= block_addr[23:16];
                        2: tx_data <= block_addr[15:8];
                        3: tx_data <= block_addr[7:0];
                        4: tx_data <= 8'h00;
                        5: tx_data <= 8'h01;
                    endcase
                    tx_start <= 1'b1;
                    waiting  <= 1'b1;
                    byte_cnt <= byte_cnt + 1'd1;
                end else if (tx_done && waiting) begin
                    waiting <= 1'b0;
                    if (byte_cnt == 6) begin
                        resp_mask          <= 8'hFF;
                        resp_value         <= 8'h00;
                        resp_bytes_needed  <= 4'd1;
                        next_state_after_resp <= S_READ_TOKEN;
                        state              <= S_READ_WAIT;
                    end
                end
            end
            S_READ_WAIT: begin
                if (!waiting) begin
                    tx_data  <= 8'hFF;
                    tx_start <= 1'b1;
                    waiting  <= 1'b1;
                    resp_timeout_cnt <= resp_timeout_cnt + 1'd1;
                end else if (tx_done) begin
                    waiting <= 1'b0;
                    if (rx_byte != 8'hFF) begin
                        resp_timeout_cnt <= 16'd0;
                        if ((rx_byte & resp_mask) == resp_value) begin
                            state <= next_state_after_resp;
                        end else resp_retry_cnt <= resp_retry_cnt + 1'd1;
                    end else if (resp_timeout_cnt > 16'd1000) begin
                        resp_retry_cnt <= resp_retry_cnt + 1'd1;
                    end

                    if (resp_retry_cnt >= 8'd10) begin
                        retry_cnt <= retry_cnt + 1'd1;
                        if (retry_cnt > CMD_RETRY_MAX) state <= S_ERROR;
                        else state <= S_CMD0;
                    end
                end
            end
            S_READ_TOKEN: begin
                if (!waiting) begin
                    tx_data  <= 8'hFF;
                    tx_start <= 1'b1;
                    waiting  <= 1'b1;
                end else if (tx_done) begin
                    waiting <= 1'b0;
                    if (rx_byte == 8'hFE) begin
                        block_idx <= 7'd0;
                        state     <= S_READ_DATA;
                    end else begin
                        timeout <= timeout + 1'd1;
                        if (timeout > READ_TIMEOUT) state <= S_ERROR;
                    end
                end
            end
            S_READ_DATA: begin
                if (!waiting) begin
                    tx_data  <= 8'hFF;
                    tx_start <= 1'b1;
                    waiting  <= 1'b1;
                end else if (tx_done) begin
                    waiting <= 1'b0;
                    read_data[511 - 8*block_idx -: 8] <= rx_byte;
                    if (block_idx == 7'd63) state <= S_WRITE_WAIT;
                    else block_idx <= block_idx + 1'd1;
                end
            end

            // -------------------------------------------------
            // WRITE (CMD24)
            // -------------------------------------------------
            S_WRITE_WAIT: begin
                ready <= 1'b1;
                if (write_data_ready) begin
                    ready        <= 1'b0;
                    spi_cs_n_reg <= 1'b0;
                    byte_cnt     <= 16'd0;
                    block_idx    <= 7'd0;
                    waiting      <= 1'b0;
                    state        <= S_WRITE_CMD;
                end
            end
            S_WRITE_CMD: begin
                state <= S_WRITE_SEND;
            end
            S_WRITE_SEND: begin
                if (!waiting && byte_cnt < 6) begin
                    case (byte_cnt)
                        0: tx_data <= 8'h58;
                        1: tx_data <= block_addr[23:16];
                        2: tx_data <= block_addr[15:8];
                        3: tx_data <= block_addr[7:0];
                        4: tx_data <= 8'h00;
                        5: tx_data <= 8'h01;
                    endcase
                    tx_start <= 1'b1;
                    waiting  <= 1'b1;
                    byte_cnt <= byte_cnt + 1'd1;
                end else if (tx_done && waiting) begin
                    waiting <= 1'b0;
                    if (byte_cnt == 6) begin
                        resp_mask          <= 8'hFF;
                        resp_value         <= 8'h00;
                        resp_bytes_needed  <= 4'd1;
                        next_state_after_resp <= S_WRITE_TOKEN;
                        state              <= S_WRITE_WAIT;
                    end
                end
            end
            S_WRITE_WAIT: begin
                if (!waiting) begin
                    tx_data  <= 8'hFF;
                    tx_start <= 1'b1;
                    waiting  <= 1'b1;
                    resp_timeout_cnt <= resp_timeout_cnt + 1'd1;
                end else if (tx_done) begin
                    waiting <= 1'b0;
                    if (rx_byte != 8'hFF) begin
                        resp_timeout_cnt <= 16'd0;
                        if ((rx_byte & resp_mask) == resp_value) begin
                            state <= next_state_after_resp;
                        end else resp_retry_cnt <= resp_retry_cnt + 1'd1;
                    end else if (resp_timeout_cnt > 16'd1000) begin
                        resp_retry_cnt <= resp_retry_cnt + 1'd1;
                    end

                    if (resp_retry_cnt >= 8'd10) begin
                        retry_cnt <= retry_cnt + 1'd1;
                        if (retry_cnt > CMD_RETRY_MAX) state <= S_ERROR;
                        else state <= S_CMD0;
                    end
                end
            end
            S_WRITE_TOKEN: begin
                if (!waiting) begin
                    tx_data  <= 8'hFE;
                    tx_start <= 1'b1;
                    waiting  <= 1'b1;
                end else if (tx_done) begin
                    waiting <= 1'b0;
                    state   <= S_WRITE_DATA;
                end
            end
            S_WRITE_DATA: begin
                if (!waiting) begin
                    tx_data  <= write_buf[block_idx];
                    tx_start <= 1'b1;
                    waiting  <= 1'b1;
                end else if (tx_done) begin
                    waiting <= 1'b0;
                    if (block_idx == 7'd63) state <= S_WRITE_RESP;
                    else block_idx <= block_idx + 1'd1;
                end
            end
            S_WRITE_RESP: begin
                if (!waiting) begin
                    tx_data  <= 8'hFF;
                    tx_start <= 1'b1;
                    waiting  <= 1'b1;
                end else if (tx_done) begin
                    waiting <= 1'b0;
                    if ((rx_byte & 8'h1F) == 8'h05) state <= S_WRITE_BUSY;
                end
            end
            S_WRITE_BUSY: begin
                if (!waiting) begin
                    tx_data  <= 8'hFF;
                    tx_start <= 1'b1;
                    waiting  <= 1'b1;
                end else if (tx_done) begin
                    waiting <= 1'b0;
                    if (rx_byte == 8'hFF) begin
                        block_addr <= block_addr + 32'd64;
                        spi_cs_n_reg <= 1'b1;
                        read_ready   <= 1'b1;
                        state        <= S_READ_CMD;
                    end
                end
            end

            // -------------------------------------------------
            S_ERROR: begin
                ready        <= 1'b0;
                spi_cs_n_reg <= 1'b1;
            end

            default: state <= S_ERROR;
        endcase
    end
end
endmodule