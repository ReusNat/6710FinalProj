//=========================================================
// Simplified SD Controller Top - Auto-Init, Sequential Read-Modify-Write
//=========================================================
module SD_Controller_Top (
    input wire clk,
    input wire rst_n,
    // SPI Interface to SD Card
    output wire spi_cs_n,      // Chip select (active low)
    output wire spi_clk,       // SPI clock (~5 MHz)
    output wire spi_mosi,      // Master out, slave in
    input wire spi_miso,       // Master in, slave out
    // Simplified Control Interface
    input wire start_sequence, // Pulse: Start sequential read-modify-write cycle
    input wire write_start,    // Pulse: Provide new data for current block write (after read_data_ready)
    input wire write_data_valid, // Level: Write data stable/ready
    input wire [511:0] write_data, // 512-bit block data for write
    // Simplified Outputs
    output wire [511:0] read_data,    // 512-bit read block data
    output wire read_data_ready,      // High: Read data valid/ready (holds until write_start)
    output wire error                 // High: Error (external skip/retry via reset or new start_sequence)
);
    // Internal signals
    wire init_complete;
    wire busy;
    wire write_complete;
    wire data_valid_int;
    wire [7:0] sd_card_type;
    wire start_init; // Auto-init trigger
    reg write_enable_int; // Internal write enable generator
    reg [31:0] block_addr; // Sequential block address
    wire [31:0] write_addr_int = block_addr;
    reg internal_read_next_block;
    reg [1:0] seq_state; // 0: wait_start, 1: read/wait_write, 2: writing
    // Auto-init
    assign start_init = !init_complete;
    // Read ready: valid during state 1
    assign read_data_ready = data_valid_int && (seq_state == 2'd1);
    // Sequence control
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            seq_state <= 2'd0;
            internal_read_next_block <= 1'b0;
            write_enable_int <= 1'b0;
            block_addr <= 32'd0;
        end else begin
            internal_read_next_block <= 1'b0;
            case (seq_state)
                2'd0: begin // Wait for start_sequence after init
                    if (init_complete && !busy && start_sequence) begin
                        seq_state <= 2'd1;
                        internal_read_next_block <= 1'b1;
                        block_addr <= 32'd0;
                    end
                end
                2'd1: begin // Reading or read done waiting for write_start
                    if (data_valid_int && write_start && write_data_valid && !busy) begin
                        seq_state <= 2'd2;
                        write_enable_int <= 1'b1;
                    end
                    // Stay in 1 during read (data_valid low) or ready (high, waiting write)
                end
                2'd2: begin // Writing
                    if (write_complete) begin
                        write_enable_int <= 1'b0;
                        block_addr <= block_addr + 1;
                        seq_state <= 2'd1;
                        internal_read_next_block <= 1'b1;
                    end
                end
            endcase
            // On error, return to wait (external handles)
            if (error) seq_state <= 2'd0;
        end
    end
    // DUT instantiation
    SD_Controller dut (
        .clk(clk),
        .rst_n(rst_n),
        // SPI Interface
        .spi_cs_n(spi_cs_n),
        .spi_clk(spi_clk),
        .spi_mosi(spi_mosi),
        .spi_miso(spi_miso),
        // Control
        .start_init(start_init),
        .read_next_block(internal_read_next_block),
        .write_enable(write_enable_int),
        .write_addr(write_addr_int),
        .write_data(write_data),
        // Status
        .init_complete(init_complete),
        .busy(busy),
        .error(error),
        .read_data(read_data),
        .data_valid(data_valid_int),
        .write_complete(write_complete),
        .block_addr(block_addr),
        .sd_card_type(sd_card_type)
    );
endmodule