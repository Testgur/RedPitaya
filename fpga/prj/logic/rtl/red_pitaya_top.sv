////////////////////////////////////////////////////////////////////////////////
// Red Pitaya TOP module. It connects external pins and PS part with
// other application modules.
// Authors: Matej Oblak, Iztok Jeras
// (c) Red Pitaya  http://www.redpitaya.com
////////////////////////////////////////////////////////////////////////////////

module red_pitaya_top #(
  // identification
  bit [0:5*32-1] GITH = '0,
  // module numbers
  int unsigned MNA = 2,  // number of acquisition modules
  int unsigned MNG = 2   // number of generator   modules
)(
  // PS connections
  inout  logic [54-1:0] FIXED_IO_mio     ,
  inout  logic          FIXED_IO_ps_clk  ,
  inout  logic          FIXED_IO_ps_porb ,
  inout  logic          FIXED_IO_ps_srstb,
  inout  logic          FIXED_IO_ddr_vrn ,
  inout  logic          FIXED_IO_ddr_vrp ,
  // DDR
  inout  logic [15-1:0] DDR_addr   ,
  inout  logic [ 3-1:0] DDR_ba     ,
  inout  logic          DDR_cas_n  ,
  inout  logic          DDR_ck_n   ,
  inout  logic          DDR_ck_p   ,
  inout  logic          DDR_cke    ,
  inout  logic          DDR_cs_n   ,
  inout  logic [ 4-1:0] DDR_dm     ,
  inout  logic [32-1:0] DDR_dq     ,
  inout  logic [ 4-1:0] DDR_dqs_n  ,
  inout  logic [ 4-1:0] DDR_dqs_p  ,
  inout  logic          DDR_odt    ,
  inout  logic          DDR_ras_n  ,
  inout  logic          DDR_reset_n,
  inout  logic          DDR_we_n   ,

  // Red Pitaya periphery

  // ADC
  input  logic [MNA-1:0] [16-1:0] adc_dat_i,  // ADC data
  input  logic           [ 2-1:0] adc_clk_i,  // ADC clock {p,n}
  output logic           [ 2-1:0] adc_clk_o,  // optional ADC clock source (unused)
  output logic                    adc_cdcs_o, // ADC clock duty cycle stabilizer
  // DAC
  output logic [14-1:0] dac_dat_o  ,  // DAC combined data
  output logic          dac_wrt_o  ,  // DAC write
  output logic          dac_sel_o  ,  // DAC channel select
  output logic          dac_clk_o  ,  // DAC clock
  output logic          dac_rst_o  ,  // DAC reset
  // PDM DAC
  output logic [ 4-1:0] dac_pwm_o  ,  // 1-bit PDM DAC
  // XADC
  input  logic [ 5-1:0] vinp_i     ,  // voltages p
  input  logic [ 5-1:0] vinn_i     ,  // voltages n
  // Expansion connector
  input  logic [ 8-1:0] exp_p_io   ,
  output logic [ 8-1:0] exp_n_io   ,
  // SATA connector
  output logic [ 2-1:0] daisy_p_o  ,  // line 1 is clock capable
  output logic [ 2-1:0] daisy_n_o  ,
  input  logic [ 2-1:0] daisy_p_i  ,  // line 1 is clock capable
  input  logic [ 2-1:0] daisy_n_i  ,
  // LED
  inout  logic [ 8-1:0] led_o
);

////////////////////////////////////////////////////////////////////////////////
// local signals
////////////////////////////////////////////////////////////////////////////////

// GPIO parameter
localparam int unsigned GDW = 8+8;

logic [4-1:0] fclk ;  // {200MHz, 166MHz, 142MHz, 125MHz}
logic [4-1:0] frstn;

// PLL signals
logic                 adc_clk_in;
logic                 pll_adc_clk;
logic                 pll_dac_clk_1x;
logic                 pll_dac_clk_2x;
logic                 pll_dac_clk_2p;
logic                 pll_ser_clk;
logic                 pll_pdm_clk;
logic                 pll_locked;
// fast serial signals
logic                 ser_clk ;
// PDM clock and reset
logic                 pdm_clk ;
logic                 pdm_rstn;

// ADC clock/reset
logic                 adc_clk;
logic                 adc_rstn;

// stream bus type
localparam type SBA_T = logic signed [ 14-1:0];  // acquire
localparam type SBG_T = logic signed [ 14-1:0];  // generate
localparam type SBL_T = logic        [GDW-1:0];  // logic ananlyzer/generator

// digital input streams
axi4_stream_if #(.DN (2), .DT (SBL_T)) str_lgo (.ACLK (adc_clk), .ARESETn (adc_rstn));  // LG

// DMA sterams RX/TX
axi4_stream_if #(         .DT (SBL_T)) str_drx (.ACLK (adc_clk), .ARESETn (adc_rstn));  // RX

axi4_stream_if #(.DN (2), .DT (SBL_T)) exp_exe (.ACLK (adc_clk), .ARESETn (adc_rstn));
axi4_stream_if #(.DN (2), .DT (SBL_T)) exp_exo (.ACLK (adc_clk), .ARESETn (adc_rstn));
axi4_stream_if #(.DN (2), .DT (SBL_T)) exp_exi (.ACLK (adc_clk), .ARESETn (adc_rstn));

// DAC signals
logic                    dac_clk_1x;
logic                    dac_clk_2x;
logic                    dac_clk_2p;
logic                    dac_rst;
logic [MNG-1:0] [14-1:0] dac_dat;

// multiplexer configuration
logic [MNG-1:0] mux_loop;
logic [MNG-1:0] mux_gen ;
logic           mux_lg  ;

// triggers
typedef struct packed {
  // analog generator
  logic [MNG-1:0] gen_out;  // event    triggers
  logic [MNG-1:0] gen_swo;  // software triggers
  // analog acquire
  logic [MNA-1:0] acq_out;  // event    triggers
  logic [MNA-1:0] acq_swo;  // software triggers
  // logic generator
  logic           lg_out;
  logic           lg_swo;
  // logic analyzer
  logic           la_out;
  logic           la_swo;
} trg_t;

trg_t trg;

// system bus
sys_bus_if   ps_sys       (.clk (adc_clk), .rstn (adc_rstn));
sys_bus_if   sys [16-1:0] (.clk (adc_clk), .rstn (adc_rstn));

// GPIO interface
gpio_if #(.DW (24)) gpio ();

logic [GDW-1:0] exp_e;  // output enable
logic [GDW-1:0] exp_o;  // output
logic [GDW-1:0] exp_i;  // input

////////////////////////////////////////////////////////////////////////////////
// PLL (clock and reset)
////////////////////////////////////////////////////////////////////////////////

// diferential clock input
IBUFDS i_clk (.I (adc_clk_i[1]), .IB (adc_clk_i[0]), .O (adc_clk_in));  // differential clock input

red_pitaya_pll pll (
  // inputs
  .clk         (adc_clk_in),  // clock
  .rstn        (frstn[0]  ),  // reset - active low
  // output clocks
  .clk_adc     (pll_adc_clk   ),  // ADC clock
  .clk_dac_1x  (pll_dac_clk_1x),  // DAC clock 125MHz
  .clk_dac_2x  (pll_dac_clk_2x),  // DAC clock 250MHz
  .clk_dac_2p  (pll_dac_clk_2p),  // DAC clock 250MHz -45DGR
  .clk_ser     (pll_ser_clk   ),  // fast serial clock
  .clk_pdm     (pll_pdm_clk   ),  // PDM clock
  // status outputs
  .pll_locked  (pll_locked)
);

BUFG bufg_adc_clk    (.O (adc_clk   ), .I (pll_adc_clk   ));
BUFG bufg_dac_clk_1x (.O (dac_clk_1x), .I (pll_dac_clk_1x));
BUFG bufg_dac_clk_2x (.O (dac_clk_2x), .I (pll_dac_clk_2x));
BUFG bufg_dac_clk_2p (.O (dac_clk_2p), .I (pll_dac_clk_2p));
BUFG bufg_ser_clk    (.O (ser_clk   ), .I (pll_ser_clk   ));
BUFG bufg_pdm_clk    (.O (pdm_clk   ), .I (pll_pdm_clk   ));

// TODO: reset is a mess
logic top_rst;
assign top_rst = ~frstn[0] | ~pll_locked;

// ADC reset (active low)
always_ff @(posedge adc_clk, posedge top_rst)
if (top_rst) adc_rstn <= 1'b0;
else         adc_rstn <= ~top_rst;

// DAC reset (active high)
always_ff @(posedge dac_clk_1x, posedge top_rst)
if (top_rst) dac_rst  <= 1'b1;
else         dac_rst  <= top_rst;

// PDM reset (active low)
always_ff @(posedge pdm_clk, posedge top_rst)
if (top_rst) pdm_rstn <= 1'b0;
else         pdm_rstn <= ~top_rst;

////////////////////////////////////////////////////////////////////////////////
//  Connections to PS
////////////////////////////////////////////////////////////////////////////////

red_pitaya_ps ps (
  .FIXED_IO_mio       (  FIXED_IO_mio                ),
  .FIXED_IO_ps_clk    (  FIXED_IO_ps_clk             ),
  .FIXED_IO_ps_porb   (  FIXED_IO_ps_porb            ),
  .FIXED_IO_ps_srstb  (  FIXED_IO_ps_srstb           ),
  .FIXED_IO_ddr_vrn   (  FIXED_IO_ddr_vrn            ),
  .FIXED_IO_ddr_vrp   (  FIXED_IO_ddr_vrp            ),
  // DDR
  .DDR_addr      (DDR_addr    ),
  .DDR_ba        (DDR_ba      ),
  .DDR_cas_n     (DDR_cas_n   ),
  .DDR_ck_n      (DDR_ck_n    ),
  .DDR_ck_p      (DDR_ck_p    ),
  .DDR_cke       (DDR_cke     ),
  .DDR_cs_n      (DDR_cs_n    ),
  .DDR_dm        (DDR_dm      ),
  .DDR_dq        (DDR_dq      ),
  .DDR_dqs_n     (DDR_dqs_n   ),
  .DDR_dqs_p     (DDR_dqs_p   ),
  .DDR_odt       (DDR_odt     ),
  .DDR_ras_n     (DDR_ras_n   ),
  .DDR_reset_n   (DDR_reset_n ),
  .DDR_we_n      (DDR_we_n    ),
  // system signals
  .fclk_clk_o    (fclk        ),
  .fclk_rstn_o   (frstn       ),
  // ADC analog inputs
  .vinp_i        (vinp_i      ),
  .vinn_i        (vinn_i      ),
  // GPIO
  .gpio          (gpio),
  // system read/write channel
  .bus           (ps_sys      ),
  // AXI streams
  .srx           (str_drx     )
);

////////////////////////////////////////////////////////////////////////////////
// system bus decoder & multiplexer (it breaks memory addresses into 8 regions)
////////////////////////////////////////////////////////////////////////////////

sys_bus_interconnect #(
  .SN (16),
  .SW (18)
) sys_bus_interconnect (
  .bus_m (ps_sys),
  .bus_s (sys)
);

// silence unused busses
//sys_bus_stub sys_bus_stub_0  (sys[ 0]);
//sys_bus_stub sys_bus_stub_1  (sys[ 1]);
sys_bus_stub sys_bus_stub_2  (sys[ 2]);
sys_bus_stub sys_bus_stub_3  (sys[ 3]);
sys_bus_stub sys_bus_stub_4  (sys[ 4]);
sys_bus_stub sys_bus_stub_5  (sys[ 5]);
//sys_bus_stub sys_bus_stub_6  (sys[ 6]);
sys_bus_stub sys_bus_stub_7  (sys[ 7]);
sys_bus_stub sys_bus_stub_8  (sys[ 8]);
sys_bus_stub sys_bus_stub_9  (sys[ 9]);
sys_bus_stub sys_bus_stub_10 (sys[10]);
//sys_bus_stub sys_bus_stub_11 (sys[11]);
//sys_bus_stub sys_bus_stub_12 (sys[12]);
sys_bus_stub sys_bus_stub_13 (sys[13]);
sys_bus_stub sys_bus_stub_14 (sys[14]);
sys_bus_stub sys_bus_stub_15 (sys[15]);

////////////////////////////////////////////////////////////////////////////////
// Current time stamp
////////////////////////////////////////////////////////////////////////////////

localparam int unsigned TW = 64;

logic [TW-1:0] cts;

cts cts_i (
  // system signals
  .clk  (adc_clk),
  .rstn (adc_rstn),
  // counter
  .cts  (cts)
);

////////////////////////////////////////////////////////////////////////////////
// Identification
////////////////////////////////////////////////////////////////////////////////

id #(
  .GITH (GITH)
) id (
  .bus (sys[0])
);

////////////////////////////////////////////////////////////////////////////////
// I/O and stream multiplexing
////////////////////////////////////////////////////////////////////////////////

muxctl muxctl (
  // global configuration
  .mux_loop  (mux_loop),
  .mux_gen   (mux_gen ),
  .mux_lg    (mux_lg  ),
   // System bus
  .bus       (sys[1])
);

////////////////////////////////////////////////////////////////////////////////
// LED
////////////////////////////////////////////////////////////////////////////////

IOBUF iobuf_led [8-1:0] (.O (gpio.i[7:0]), .IO(led_o), .I(gpio.o[7:0]), .T(gpio.t[7:0]));

////////////////////////////////////////////////////////////////////////////////
// GPIO ports
////////////////////////////////////////////////////////////////////////////////

assign gpio.i [23:8] = {exp_n_io, exp_p_io};

////////////////////////////////////////////////////////////////////////////////
// extension connector
////////////////////////////////////////////////////////////////////////////////

// temporary solution for unit testing
// IOBUF has been split into separate IBUF & OBUF
// // output enable DDR
// ODDR #(
//   .IS_D1_INVERTED (1'b1), // IOBUF T input is buffer disable, so negation is needed somewhere
//   .IS_D2_INVERTED (1'b1), // IOBUF T input is buffer disable, so negation is needed somewhere
//   .DDR_CLK_EDGE ("SAME_EDGE")
// ) oddr_exp_e [GDW-1:0] (
//   .Q  (exp_e           ),
//   .C  (exp_exe.ACLK    ),
//   .CE (exp_exe.TVALID  ),
//   .D1 (exp_exe.TDATA[0]),  // TODO: add DDR support for LG here
//   .D2 (exp_exe.TDATA[1]),
//   .R  (~exp_exe.ARESETn ),
//   .S  (1'b0)
// );

assign exp_exe.TREADY = 1'b1;

// // output DDR
// ODDR #(
//   .DDR_CLK_EDGE ("SAME_EDGE")
// ) oddr_exp_o [GDW-1:0] (
//   .Q  (exp_o           ),
//   .C  (exp_exo.ACLK    ),
//   .CE (exp_exo.TVALID  ),
//   .D1 (exp_exo.TDATA[0]),
//   .D2 (exp_exo.TDATA[1]),  // TODO: add DDR support for LG here
//   .R  (~exp_exo.ARESETn ),
//   .S  (1'b0            )
// );
assign exp_n_io = exp_exo.TDATA[0];
assign exp_exo.TREADY = 1'b1;

// // input DDR
// IDDR #(
//   .DDR_CLK_EDGE ("SAME_EDGE_PIPELINED")
// ) iddr_exp_i [GDW-1:0] (
//   .Q1 (exp_exi.TDATA[0]),
//   .Q2 (exp_exi.TDATA[1]),  // TODO: add DDR support for LA here
//   .C  (exp_exi.ACLK    ),
//   .CE (exp_exi.TREADY  ),
//   .R  (~exp_exi.ARESETn ),
//   .S  (1'b0            ),
//   .D  (exp_i           )
// );
assign exp_exi.TDATA[0] = exp_p_io ;
assign exp_exi.TDATA[1] = exp_p_io ;
assign exp_exi.TVALID = 1'b1;
assign exp_exi.TKEEP  = '1;
assign exp_exi.TLAST  = 1'b0;

// IO buffer with output enable
// TODO: this is hardcoded, since it somehow did not work before, simulation was fine, but synthesis might have a problem
// IOBUF iobuf_exp [GDW-1:0] (.O (exp_i), .IO({exp_n_io, exp_p_io}), .I(exp_o), .T({8'h00, 8'hff}));
//IOBUF iobuf_exp [GDW-1:0] (.O (exp_i), .IO({exp_n_io, exp_p_io}), .I(exp_o), .T(exp_e));

////////////////////////////////////////////////////////////////////////////////
// PWM
////////////////////////////////////////////////////////////////////////////////

`ifdef ENABLE_PWM

localparam int unsigned PWM_CHN = 4;
localparam int unsigned PWM_DWC = 8;
localparam type PWM_T = logic [PWM_DWC-1:0];

PWM_T [PWM_CHN-1:0] pwm_cfg;

sys_reg_array_o #(
  .RT (PWM_T  ),
  .RN (PWM_CHN)
) regset_pwm (
  .val       (pwm_cfg),
  .bus       (sys[6])
);

pwm #(
  .DWC (PWM_DWC),
  .CHN (PWM_CHN)
) pwm (
  // system signals
  .clk      (pdm_clk ),
  .rstn     (pdm_rstn),
  .cke      (1'b1),
  // configuration
  .ena      (1'b1),
  .rng      (8'd255),
  // input stream
  .str_dat  (pwm_cfg),
  .str_vld  (1'b1   ),
  .str_rdy  (       ),
  // PWM outputs
  .pwm      ()
);

`else

sys_bus_stub sys_bus_stub_6 (sys[6]);

`endif // ENABLE_PWM

////////////////////////////////////////////////////////////////////////////////
// Daisy dummy code
////////////////////////////////////////////////////////////////////////////////

assign daisy_p_o = 1'bz;
assign daisy_n_o = 1'bz;

////////////////////////////////////////////////////////////////////////////////
// ADC IO
////////////////////////////////////////////////////////////////////////////////

// generating ADC clock is disabled
assign adc_clk_o = 2'b10;

// ADC clock duty cycle stabilizer is enabled
assign adc_cdcs_o = 1'b1 ;

////////////////////////////////////////////////////////////////////////////////
// DAC IO
////////////////////////////////////////////////////////////////////////////////

generate
for (genvar i=0; i<MNA; i++) begin: for_dac

  // output registers + signed to unsigned (also to negative slope)
  assign dac_dat[i] = {1'b0, 13'h1fff};

end: for_dac
endgenerate

// DDR outputs
// TODO set parameter #(.DDR_CLK_EDGE ("SAME_EDGE"))
ODDR oddr_dac_clk          (.Q(dac_clk_o), .D1(1'b0      ), .D2(1'b1      ), .C(dac_clk_2p), .CE(1'b1), .R(1'b0   ), .S(1'b0));
ODDR oddr_dac_wrt          (.Q(dac_wrt_o), .D1(1'b0      ), .D2(1'b1      ), .C(dac_clk_2x), .CE(1'b1), .R(1'b0   ), .S(1'b0));
ODDR oddr_dac_sel          (.Q(dac_sel_o), .D1(1'b1      ), .D2(1'b0      ), .C(dac_clk_1x), .CE(1'b1), .R(dac_rst), .S(1'b0));
ODDR oddr_dac_rst          (.Q(dac_rst_o), .D1(dac_rst   ), .D2(dac_rst   ), .C(dac_clk_1x), .CE(1'b1), .R(1'b0   ), .S(1'b0));
ODDR oddr_dac_dat [14-1:0] (.Q(dac_dat_o), .D1(dac_dat[0]), .D2(dac_dat[1]), .C(dac_clk_1x), .CE(1'b1), .R(dac_rst), .S(1'b0));

////////////////////////////////////////////////////////////////////////////////
// LG (logic generator)
////////////////////////////////////////////////////////////////////////////////

lg_top #(
  .DT (SBL_T),
  .TN ($bits(trg))
) lg (
  // stream output
  .sto       (str_lgo),
  // triggers
  .trg_ext   (trg),
  .trg_swo   (trg.lg_swo),
  .trg_out   (trg.lg_out),
  // interrupts
  .irq_trg   (),
  .irq_stp   (),
  // System bus
  .bus       (sys[11])
);

assign exp_exe.TDATA  = {2{str_lgo.TDATA[1]}};
assign exp_exe.TKEEP  =    str_lgo.TKEEP   ;
assign exp_exe.TLAST  =    str_lgo.TLAST   ;
assign exp_exe.TVALID =    str_lgo.TVALID  ;

assign exp_exo.TDATA  = {2{str_lgo.TDATA[0]}};
assign exp_exo.TKEEP  =    str_lgo.TKEEP   ;
assign exp_exo.TLAST  =    str_lgo.TLAST   ;
assign exp_exo.TVALID =    str_lgo.TVALID  ;

assign str_lgo.TREADY = exp_exo.TREADY;

////////////////////////////////////////////////////////////////////////////////
// LA (logic analyzer)
////////////////////////////////////////////////////////////////////////////////

la_top #(
  .DT (SBL_T),
  .TN ($bits(trg)),
  .CW (32)
) la (
  // streams
  .sti       (exp_exi),
  .sto       (str_drx),
  // current time stamp
  .cts       (cts),
  // triggers
  .trg_ext   (trg),
  .trg_swo   (trg.la_swo),
  .trg_out   (trg.la_out),
  // interrupts
  .irq_trg   (),
  .irq_stp   (),
  // System bus
  .bus       (sys[12])
);

endmodule: red_pitaya_top
