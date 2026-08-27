// ============================================================================
// reciprocal_interp_q8_24
//
// 11-bit LUT + linear interpolation reciprocal for x in [0.5, 2.5], Q8.24
//
// REV 7 + P1 COMPARATOR OPTIMIZATION
//
// Pipeline:
//   P0  : register x_in + above-range detection
//   P1  : below-range detection + offset
//   P2  : index/fraction split
//   P3a : BRAM internal register
//   P3b : BRAM internal register
//   P4  : BRAM output decoupling
//   P5  : DSP A/B registers
//   P6  : DSP M register
//   P7  : DSP P register
//   P8  : DSP output decoupling register
//   P9  : chunk 0
//   P10 : chunk 1
//   P11 : chunk 2
//   P12 : chunk 3
//   P13 : saturation compare
//   P14 : saturation select
//
// Throughput: 1 result/cycle
// ============================================================================

module reciprocal_interp_q8_24 #(
    parameter int IDX_BITS        = 11,
    parameter int SHIFT           = 14,
    parameter int FRAC_BITS       = 14,
    parameter int SLOPE_FRAC_BITS = 21
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        valid_in,
    input  logic [31:0] x_in,
    output logic        valid_out,
    output logic [31:0] recip_out
);

    localparam logic [31:0] X_LO = 32'h0080_0000;
    localparam logic [31:0] X_HI = 32'h0280_0000;
    localparam int N = (1 << IDX_BITS);

    // -------------------------------------------------------------- P0 --
    //
    // Detect x > X_HI before the x_r0 register.
    //
    // X_HI = 2.5 = 0x02800000.
    //
    // Therefore:
    //   sign bit set        -> above
    //   integer field > 2   -> above
    //   integer field < 2   -> not above
    //   integer field == 2  -> compare fractional field > 0x800000
    //
    // The result is registered together with x_in so P1 receives an
    // already-registered above-range flag.
    //

    logic [31:0] x_r0;
    logic        v_r0;
    logic        above_r0;
    logic        above_comb_p0;

    always_comb begin
        if (x_in[31])
            above_comb_p0 = 1'b1;
        else if (x_in[30:24] > 7'd2)
            above_comb_p0 = 1'b1;
        else if (x_in[30:24] < 7'd2)
            above_comb_p0 = 1'b0;
        else
            above_comb_p0 = (x_in[23:0] > 24'h80_0000);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_r0     <= '0;
            v_r0     <= 1'b0;
            above_r0 <= 1'b0;
        end else begin
            x_r0     <= x_in;
            v_r0     <= valid_in;
            above_r0 <= above_comb_p0;
        end
    end

    // -------------------------------------------------------------- P1 --
    //
    // above_r0 is now already registered from P0.
    // P1 therefore no longer contains the x_r0 > X_HI comparator.
    //

    logic        below_r0;
    logic [25:0] offset_comb;

    always_comb begin
        below_r0   = (x_r0 < X_LO);
        offset_comb = below_r0 ? 26'd0 : (x_r0 - X_LO);
    end

    logic [25:0] offset_r1;
    logic        above_r1;
    logic        v_r1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            offset_r1 <= '0;
            above_r1  <= 1'b0;
            v_r1      <= 1'b0;
        end else begin
            offset_r1 <= offset_comb;
            above_r1  <= above_r0;
            v_r1      <= v_r0;
        end
    end

    // -------------------------------------------------------------- P2 --

    logic [IDX_BITS-1:0] idx_comb;
    logic [IDX_BITS-1:0] idx_r2;

    logic [FRAC_BITS-1:0] frac_comb;
    logic [FRAC_BITS-1:0] frac_r2;

    logic [IDX_BITS+3:0] idx_full;
    logic                 v_r2;

    always_comb begin
        idx_full = offset_r1 >> SHIFT;

        if (above_r1 || (idx_full > (N-1))) begin
            idx_comb  = N-1;
            frac_comb = {FRAC_BITS{1'b1}};
        end else begin
            idx_comb  = idx_full[IDX_BITS-1:0];
            frac_comb = offset_r1 & ((1 << FRAC_BITS) - 1);
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            idx_r2  <= '0;
            frac_r2 <= '0;
            v_r2    <= 1'b0;
        end else begin
            idx_r2  <= idx_comb;
            frac_r2 <= frac_comb;
            v_r2    <= v_r1;
        end
    end

    // -------------------------------------------------------------- P3 --

    localparam int SEED_BITS  = 32;
    localparam int SLOPE_BITS = 25;

    logic [31:0] seed_dout;
    logic [24:0] slope_dout;

    xpm_memory_sprom #(
        .ADDR_WIDTH_A       (IDX_BITS),
        .MEMORY_INIT_FILE   ("interp_seed.mem"),
        .MEMORY_PRIMITIVE   ("block"),
        .MEMORY_SIZE        (N * SEED_BITS),
        .READ_DATA_WIDTH_A  (SEED_BITS),
        .READ_LATENCY_A     (2),
        .READ_RESET_VALUE_A ("0"),
        .RST_MODE_A         ("SYNC"),
        .USE_MEM_INIT       (1)
    ) seed_rom_inst (
        .clka   (clk),
        .ena    (1'b1),
        .regcea (1'b1),
        .rsta   (1'b0),
        .sleep  (1'b0),
        .addra  (idx_r2),
        .douta  (seed_dout)
    );

    xpm_memory_sprom #(
        .ADDR_WIDTH_A       (IDX_BITS),
        .MEMORY_INIT_FILE   ("interp_slope.mem"),
        .MEMORY_PRIMITIVE   ("block"),
        .MEMORY_SIZE        (N * SLOPE_BITS),
        .READ_DATA_WIDTH_A  (SLOPE_BITS),
        .READ_LATENCY_A     (2),
        .READ_RESET_VALUE_A ("0"),
        .RST_MODE_A         ("SYNC"),
        .USE_MEM_INIT       (1)
    ) slope_rom_inst (
        .clka   (clk),
        .ena    (1'b1),
        .regcea (1'b1),
        .rsta   (1'b0),
        .sleep  (1'b0),
        .addra  (idx_r2),
        .douta  (slope_dout)
    );

    logic [FRAC_BITS-1:0] frac_r3a;
    logic [FRAC_BITS-1:0] frac_r3b;
    logic                 v_r3a;
    logic                 v_r3b;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frac_r3a <= '0;
            frac_r3b <= '0;
            v_r3a    <= 1'b0;
            v_r3b    <= 1'b0;
        end else begin
            frac_r3a <= frac_r2;
            frac_r3b <= frac_r3a;
            v_r3a    <= v_r2;
            v_r3b    <= v_r3a;
        end
    end

    // -------------------------------------------------------------- P4 --

    (* dont_touch = "true", keep = "true" *)
    logic [31:0] seed_r4;

    (* dont_touch = "true", keep = "true" *)
    logic signed [24:0] slope_r4;

    (* dont_touch = "true", keep = "true" *)
    logic [FRAC_BITS-1:0] frac_r4;

    logic v_r4;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            seed_r4  <= '0;
            slope_r4 <= '0;
            frac_r4  <= '0;
            v_r4     <= 1'b0;
        end else begin
            seed_r4  <= seed_dout;
            slope_r4 <= slope_dout;
            frac_r4  <= frac_r3b;
            v_r4     <= v_r3b;
        end
    end

    // -------------------------------------------------------------- P5/P6/P7 --

    logic [29:0] dsp_a_in;
    logic [17:0] dsp_b_in;
    logic [47:0] dsp_p_out;

    assign dsp_a_in = {{5{slope_r4[24]}}, slope_r4};
    assign dsp_b_in = {4'b0, frac_r4};

    DSP48E1 #(
        .A_INPUT            ("DIRECT"),
        .B_INPUT            ("DIRECT"),
        .USE_DPORT          ("FALSE"),
        .USE_MULT           ("MULTIPLY"),
        .USE_SIMD           ("ONE48"),
        .AREG               (1),
        .BREG               (1),
        .MREG               (1),
        .PREG               (1),
        .ACASCREG           (1),
        .BCASCREG           (1),
        .ADREG              (0),
        .ALUMODEREG         (0),
        .CARRYINREG         (0),
        .CARRYINSELREG      (0),
        .CREG               (0),
        .DREG               (0),
        .INMODEREG          (0),
        .OPMODEREG          (0)
    ) dsp_slope_mult_inst (
        .CLK                (clk),

        .A                  (dsp_a_in),
        .B                  (dsp_b_in),
        .C                  (48'b0),
        .D                  (25'b0),
        .ACIN               (30'b0),
        .BCIN               (18'b0),
        .PCIN               (48'b0),
        .CARRYCASCIN        (1'b0),
        .MULTSIGNIN         (1'b0),

        .INMODE             (5'b00000),
        .ALUMODE            (4'b0000),
        .OPMODE             (7'b0000101),
        .CARRYINSEL         (3'b000),
        .CARRYIN            (1'b0),

        .CEA1               (1'b1),
        .CEA2               (1'b1),
        .CEB1               (1'b1),
        .CEB2               (1'b1),
        .CEM                (1'b1),
        .CEP                (1'b1),
        .CEAD               (1'b0),
        .CEALUMODE          (1'b0),
        .CEC                (1'b0),
        .CECARRYIN          (1'b0),
        .CECTRL             (1'b0),
        .CED                (1'b0),
        .CEINMODE           (1'b0),

        .RSTA               (~rst_n),
        .RSTB               (~rst_n),
        .RSTM               (~rst_n),
        .RSTP               (~rst_n),
        .RSTC               (1'b0),
        .RSTD               (1'b0),
        .RSTALLCARRYIN      (1'b0),
        .RSTALUMODE         (1'b0),
        .RSTCTRL            (1'b0),
        .RSTINMODE          (1'b0),

        .P                  (dsp_p_out),
        .ACOUT              (),
        .BCOUT              (),
        .CARRYCASCOUT       (),
        .CARRYOUT           (),
        .MULTSIGNOUT        (),
        .OVERFLOW           (),
        .PATTERNBDETECT     (),
        .PATTERNDETECT      (),
        .PCOUT              (),
        .UNDERFLOW          ()
    );

    // -------------------------------------------------------------- P7 --

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [31:0] seed_r5;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [31:0] seed_r6;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [31:0] seed_r7;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic v_r5;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic v_r6;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic v_r7;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            seed_r5 <= '0;
            seed_r6 <= '0;
            seed_r7 <= '0;
            v_r5    <= 1'b0;
            v_r6    <= 1'b0;
            v_r7    <= 1'b0;
        end else begin
            seed_r5 <= seed_r4;
            seed_r6 <= seed_r5;
            seed_r7 <= seed_r6;
            v_r5    <= v_r4;
            v_r6    <= v_r5;
            v_r7    <= v_r6;
        end
    end

    // -------------------------------------------------------------- P8 --
    //
    // Explicit fabric register immediately after DSP PREG.
    // This isolates DSP clock-to-out/routing from chunk-0 arithmetic.
    //

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [47:0] dsp_p_r8;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [31:0] seed_r8;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic v_r8;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dsp_p_r8 <= '0;
            seed_r8  <= '0;
            v_r8     <= 1'b0;
        end else begin
            dsp_p_r8 <= dsp_p_out;
            seed_r8  <= seed_r7;
            v_r8     <= v_r7;
        end
    end

    logic signed [43:0] seed_ext;
    logic signed [43:0] prod_ext;

    assign seed_ext = {{12{seed_r8[31]}}, seed_r8};

    assign prod_ext = {{22{dsp_p_r8[42]}}, dsp_p_r8[42:21]};

    // -------------------------------------------------------------- P9 --
    //
    // Chunk 0: bits [10:0]
    //

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] sum_c0_r9;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic carry_c0_r9;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] c1_seed_r9;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] c1_prod_r9;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] c2_seed_r9;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] c2_prod_r9;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] c3_seed_r9;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] c3_prod_r9;

    logic v_r9;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum_c0_r9   <= '0;
            carry_c0_r9 <= 1'b0;
            c1_seed_r9  <= '0;
            c1_prod_r9  <= '0;
            c2_seed_r9  <= '0;
            c2_prod_r9  <= '0;
            c3_seed_r9  <= '0;
            c3_prod_r9  <= '0;
            v_r9        <= 1'b0;
        end else begin
            {carry_c0_r9, sum_c0_r9} <=
                {1'b0, seed_ext[10:0]} +
                {1'b0, prod_ext[10:0]};

            c1_seed_r9 <= seed_ext[21:11];
            c1_prod_r9 <= prod_ext[21:11];

            c2_seed_r9 <= seed_ext[32:22];
            c2_prod_r9 <= prod_ext[32:22];

            c3_seed_r9 <= seed_ext[43:33];
            c3_prod_r9 <= prod_ext[43:33];

            v_r9 <= v_r8;
        end
    end

    // ------------------------------------------------------------- P10 --
    //
    // Chunk 1: bits [21:11]
    //

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] sum_c1_r10;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic carry_c1_r10;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] sum_c0_r10;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] c2_seed_r10;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] c2_prod_r10;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] c3_seed_r10;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] c3_prod_r10;

    logic v_r10;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum_c1_r10   <= '0;
            carry_c1_r10 <= 1'b0;
            sum_c0_r10   <= '0;
            c2_seed_r10  <= '0;
            c2_prod_r10  <= '0;
            c3_seed_r10  <= '0;
            c3_prod_r10  <= '0;
            v_r10        <= 1'b0;
        end else begin
            {carry_c1_r10, sum_c1_r10} <=
                {1'b0, c1_seed_r9} +
                {1'b0, c1_prod_r9} +
                {11'b0, carry_c0_r9};

            sum_c0_r10 <= sum_c0_r9;

            c2_seed_r10 <= c2_seed_r9;
            c2_prod_r10 <= c2_prod_r9;

            c3_seed_r10 <= c3_seed_r9;
            c3_prod_r10 <= c3_prod_r9;

            v_r10 <= v_r9;
        end
    end

    // ------------------------------------------------------------- P11 --
    //
    // Chunk 2: bits [32:22]
    //

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] sum_c2_r11;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic carry_c2_r11;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] sum_c0_r11;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] sum_c1_r11;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] c3_seed_r11;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] c3_prod_r11;

    logic v_r11;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum_c2_r11   <= '0;
            carry_c2_r11 <= 1'b0;
            sum_c0_r11   <= '0;
            sum_c1_r11   <= '0;
            c3_seed_r11  <= '0;
            c3_prod_r11  <= '0;
            v_r11        <= 1'b0;
        end else begin
            {carry_c2_r11, sum_c2_r11} <=
                {1'b0, c2_seed_r10} +
                {1'b0, c2_prod_r10} +
                {11'b0, carry_c1_r10};

            sum_c0_r11 <= sum_c0_r10;
            sum_c1_r11 <= sum_c1_r10;

            c3_seed_r11 <= c3_seed_r10;
            c3_prod_r11 <= c3_prod_r10;

            v_r11 <= v_r10;
        end
    end

    // ------------------------------------------------------------- P12 --
    //
    // Chunk 3: bits [43:33]
    //
    // One guard bit is retained at the top.
    //

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic signed [11:0] sum_c3_r12;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] sum_c0_r12;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] sum_c1_r12;

    (* dont_touch = "true", keep = "true", shreg_extract = "no" *)
    logic [10:0] sum_c2_r12;

    logic v_r12;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum_c3_r12 <= '0;
            sum_c0_r12 <= '0;
            sum_c1_r12 <= '0;
            sum_c2_r12 <= '0;
            v_r12      <= 1'b0;
        end else begin
            sum_c3_r12 <=
                $signed({c3_seed_r11[10], c3_seed_r11}) +
                $signed({c3_prod_r11[10], c3_prod_r11}) +
                $signed({11'b0, carry_c2_r11});

            sum_c0_r12 <= sum_c0_r11;
            sum_c1_r12 <= sum_c1_r11;
            sum_c2_r12 <= sum_c2_r11;

            v_r12 <= v_r11;
        end
    end

    // ------------------------------------------------------------- P13 --
    //
    // Reconstruct and register saturation flags.
    //

    logic signed [44:0] sum_full_r12;

    assign sum_full_r12 =
        {sum_c3_r12, sum_c2_r12, sum_c1_r12, sum_c0_r12};

    logic        ovf_pos_r13;
    logic        ovf_neg_r13;
    logic [31:0] sum_lo_r13;
    logic        v_r13;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ovf_pos_r13 <= 1'b0;
            ovf_neg_r13 <= 1'b0;
            sum_lo_r13  <= '0;
            v_r13       <= 1'b0;
        end else begin
            ovf_pos_r13 <=
                (sum_full_r12 > 45'sd2147483647);

            ovf_neg_r13 <=
                (sum_full_r12 < -45'sd2147483648);

            sum_lo_r13 <= sum_full_r12[31:0];
            v_r13      <= v_r12;
        end
    end

    // ------------------------------------------------------------- P14 --
    //
    // Final saturation select.
    //

    logic [31:0] recip_r14;
    logic        v_r14;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            recip_r14 <= '0;
            v_r14     <= 1'b0;
        end else begin
            if (ovf_pos_r13)
                recip_r14 <= 32'h7FFF_FFFF;
            else if (ovf_neg_r13)
                recip_r14 <= 32'h8000_0000;
            else
                recip_r14 <= sum_lo_r13;

            v_r14 <= v_r13;
        end
    end

    assign recip_out = recip_r14;
    assign valid_out = v_r14;

endmodule