module xorEncr (clk, rst, start, rw_flag, done,
sd_data_in, sd_data_out, sd_data_valid, sd_ready, 
reg_file_rw, reg_file_sel, reg_file_data_out);

    parameter DATA_WIDTH = 512;// data bus width
    parameter KEY_WIDTH = 512;// key width (half of register file)

    input wire clk;
    input wire rst;
   
    // Control signals
    input wire start; // start operation
    input wire rw_flag; // 1 = write(encrypt), 0 = read(decrypt)
    output wire done; // Operation complete (derived from state)
   
    // SD controller interface
    input wire [DATA_WIDTH-1:0] sd_data_in; // Data from SD card
    output reg [DATA_WIDTH-1:0] sd_data_out; //data to SD card
    input wire sd_data_valid; // signal when SD card has finished getting data to start reading from the SD card
    input wire sd_ready; // signal SD is ready for operation so to prevent writing to the SD Card when SD card is busy
   
    // register file interface which connects to regfile
    output reg reg_file_rw; // 1 = write, 0 = read
    output reg reg_file_sel; // 0 = lower 512 bits, 1 = upper 512 bits
    input wire [KEY_WIDTH-1:0] reg_file_data_out; // key from register file (512 bits)

	 
     // FSM States
    localparam IDLE            = 4'b0000;
    localparam READ_DATA       = 4'b0001;
    localparam READ_KEY        = 4'b0010;
    localparam WAIT_KEY        = 4'b0011;
    localparam ENCRYPT         = 4'b0100;
    localparam WRITE_ENCRYPTED = 4'b0101;
    localparam READ_ENCRYPTED  = 4'b0110;
    localparam DECRYPT         = 4'b0111;
    localparam WRITE_DECRYPTED = 4'b1000;
    localparam DONE_STATE      = 4'b1001;

    // internal registers
    reg [3:0] state, next_state;
    reg [DATA_WIDTH-1:0] data_buffer;      // for data being processed
    reg [KEY_WIDTH-1:0] key_buffer;        // for encryption key
    reg [DATA_WIDTH-1:0] result_buffer;    // for XOR result

    
    // derived outputs (Combinational)
    assign done = (state == DONE_STATE);  //done signal derived from state


	 
    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            data_buffer <= {DATA_WIDTH{1'b0}};
            key_buffer <= {KEY_WIDTH{1'b0}};
            result_buffer <= {DATA_WIDTH{1'b0}};
        end else begin
            state <= next_state;
           
            // datapath operations based on current state
            case (state)
                READ_DATA: begin
                    if (sd_data_valid)
                        data_buffer <= sd_data_in;  // Capture data
                end
               
                READ_ENCRYPTED: begin
                    if (sd_data_valid)
                        data_buffer <= sd_data_in;  // capture encrypted data
                end
               
                WAIT_KEY: begin
                    key_buffer <= reg_file_data_out;  // Capture key from regfile
                end
               
                ENCRYPT: begin
                    result_buffer <= data_buffer ^ key_buffer;  // xor encrypt
                end
               
                DECRYPT: begin
                    result_buffer <= data_buffer ^ key_buffer;  // xor decrypt
                end
            endcase
        end
    end


    always @(*) begin
        // default assignments
        next_state = state;
        sd_data_out = {DATA_WIDTH{1'b0}};
        reg_file_rw = 1'b0;
        reg_file_sel = 1'b0;
       
        case (state)
            IDLE: begin
                // next state logic
                if (start) begin
                    if (rw_flag == 1'b1)
                        next_state = READ_DATA;      // encrypt path
                    else
                        next_state = READ_ENCRYPTED; // decrypt path
                end
            end
           
            // encryption
            READ_DATA: begin
                if (sd_data_valid)
                    next_state = READ_KEY;
            end
           
            READ_KEY: begin
                reg_file_rw = 1'b0;   // read mode
                reg_file_sel = 1'b0;  // lower 512 bits (change if key in upper)
               
                next_state = WAIT_KEY;
            end
           
            WAIT_KEY: begin
                next_state = ENCRYPT;
            end
           
            ENCRYPT: begin
                next_state = WRITE_ENCRYPTED;
            end
           
            WRITE_ENCRYPTED: begin
                sd_data_out = result_buffer;  // output encrypted data
               
                if (sd_ready)
                    next_state = DONE_STATE;
            end
           
            // decryption 
            READ_ENCRYPTED: begin
                if (sd_data_valid)
                    next_state = READ_KEY;
            end
           
            DECRYPT: begin
                next_state = WRITE_DECRYPTED;
            end
           
            WRITE_DECRYPTED: begin
                sd_data_out = result_buffer;  // output decrypted data
               
                if (sd_ready)
                    next_state = DONE_STATE;
            end
           
            // done state
            DONE_STATE: begin
                next_state = IDLE;
            end
           
            default: begin
                next_state = IDLE;
            end
        endcase
    end

endmodule
