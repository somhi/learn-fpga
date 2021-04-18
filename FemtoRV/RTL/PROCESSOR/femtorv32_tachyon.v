/**************************************************************************/
// FemtoRV32-Tachyon, small and fast RISC-V RV32I core for the IceStick.
//   Features: 
//      a two-level shifter, a tick counters.
//      maxfreq on the IceStick: validated:65 MHz  experimental:90 MHz
//
// Parameters:
//    RESET_ADDR initial value of PC (default = 0)
//    ADDR_WIDTH number of bits in internal address bus (default = 24)
//
// Macros: 
//    optionally one may define NRV_IS_IO_ADDR(addr), that is supposed to:
//              evaluate to 1 if addr is in mapped IO space, 
//              evaluate to 0 otherwise
//    (additional wait states are used when in IO space).
//    If left undefined, wait states are always used.
//
//    NRV_COUNTER_WIDTH may be defined to reduce the number of bits used
//    by the ticks counter. If not defined, a 32-bits counter is generated.
//    (reducing its width may be useful for space-constrained designs).
//
//    NRV_TWOLEVEL_SHIFTER may be defined to make shift operations faster
//    (uses a two-level shifter inspired by picorv32).
//
// Bruno Levy & Matthias Koch, 2020-2021
/**************************************************************************/

// The ALU, used for reg-reg, reg-imm and branch tests
module ALU(
  input 	clk, 
  input 	wr,    // write strobe to start ALU and predicate computation
  input 	isALU, // asserted is current instr is ALUimm or ALUreg
  input [31:0] 	in1,   // \
  input [31:0] 	in2,   //  > ALU input and output
  output [31:0] out,   // /
  output reg 	predicate, // test result for branch (available 1 clock after wr)
  output 	busy,      // asserted if ALU is busy shifting
  input [2:0] 	funct3,    // 3-bits code for ALU and tests (instr[14:12])
  input 	add_sub,   // 0 for add, 1 for sub
  input 	srl_sra	   // 0 for logical right shift, 1 for arithmetic right shift
);
   reg [31:0] A;    // The internal register of the ALU.
   reg [4:0] shamt; // Current shift amount.
   assign out = A;
   assign busy = |shamt;

   wire [31:0] plus = in1 + in2;
   
   // Use a single 33 bits subtract to do subtraction and all comparisons
   // (trick borrowed from swapforth/J1)
   wire [32:0] minus = {1'b1, ~in2} + {1'b0,in1} + 33'b1;

   // Predicates
   wire LT  = (in1[31] ^ in2[31]) ? in1[31] : minus[32];
   wire LTU = minus[32];
   wire EQ  = (minus[31:0] == 0);

   always @(posedge clk) begin
      if(wr && isALU) begin
         case(funct3) 
            3'b000: A <= add_sub ? minus[31:0] : plus;             // ADD/SUB
            3'b010: A <= {31'b0, LT} ;                             // SLT
            3'b011: A <= {31'b0, LTU};                             // SLTU
            3'b100: A <= in1 ^ in2;                                // XOR
            3'b110: A <= in1 | in2;                                // OR
            3'b111: A <= in1 & in2;                                // AND
            3'b001, 3'b101: begin A <= in1; shamt <= in2[4:0]; end // SLL, SRA, SRL
         endcase
      end else begin
	 // Shift (multi-cycle)
`ifdef NRV_TWOLEVEL_SHIFTER	 
	 if(|shamt[3:2]) begin
            shamt <= shamt - 4;
	    // Compact form of:
	    //   funct3=101 &  instr[30] -> SRA  (A <= {{4{A[31]}}, A[31:4]})
	    //   funct3=101 & !instr[30] -> SRL  (A <= { 4'b0000,        A[31:4]})		      
            //   funct3=001              -> SLL  (A <= A << 4)
	    A <= funct3[2] ? {{4{srl_sra & A[31]}}, A[31:4]} : A << 4 ;	    
	 end else
`endif 	   
         if (|shamt) begin
            shamt <= shamt - 1;
	    // Compact form of:
	    //   funct3=101 &  srl_sra -> SRA  (A <= {A[31], A[31:1]})
	    //   funct3=101 & !srl_sra -> SRL  (A <= {1'b0,       A[31:1]})		      
            //   funct3=001            -> SLL  (A <= A << 1)
	    A <= funct3[2] ? {srl_sra & A[31], A[31:1]} : A << 1 ;
         end
      end
   end

   always @(posedge clk) begin
      if(wr && !isALU) begin
	 case(funct3)
           3'b000:  predicate <=  EQ;  // BEQ
           3'b001:  predicate <= !EQ;  // BNE
           3'b100:  predicate <=  LT;  // BLT
           3'b101:  predicate <= !LT;  // BGE
           3'b110:  predicate <=  LTU; // BLTU
           3'b111:  predicate <= !LTU; // BGEU
           default: predicate <= 1'bx; // don't care...
	 endcase
      end 
   end 
endmodule


module FemtoRV32(
   input          clk,

   output [31:0] mem_addr,  // address bus
   output [31:0] mem_wdata, // data to be written
   output [3:0]  mem_wmask, // write mask for the 4 bytes of each word
   input  [31:0] mem_rdata, // input lines for both data and instr
   output        mem_rstrb, // active to initiate memory read (used by IO)
   input         mem_rbusy, // asserted if memory is busy reading value
   input         mem_wbusy, // asserted if memory is busy writing value
   
   input         reset      // set to 0 to reset the processor
);

   parameter RESET_ADDR       = 0;  // the address that the processor jumps to on reset
   parameter ADDR_WIDTH       = 24; // number of bits in address registers

   localparam ADDR_PAD= {(32-ADDR_WIDTH){1'b0}}; // 32-bits padding for addresses
   reg [ADDR_WIDTH-1:0] addr_reg;                // The internal register plugged to mem_addr
   assign mem_addr = {ADDR_PAD,addr_reg};

   /***************************************************************************/
   // Instruction decoding.
   /***************************************************************************/

   // Extracts rd,rs1,rs2,funct3Equals,imm and opcode from instruction stored in reg instr[31:0]
   // Reference: Table page 104 of:
   // https://content.riscv.org/wp-content/uploads/2017/05/riscv-spec-v2.2.pdf

   // The destination register
   wire [4:0] rd  = instr[11:7];

   // The ALU function
   wire [2:0] funct3 = instr[14:12];

   // Decoded ALU function as 1-hot: funct3Equals[i] <=> funct3 == i
   // (using it reduces overall LUT count)
   (* onehot *)
   wire [7:0] funct3Equals = 8'b00000001 << funct3;  
   
   // The five immediate formats, see RiscV reference (link above), Fig. 2.4 p. 12
   wire [31:0] Uimm = {    instr[31],   instr[30:12], {12{1'b0}}};
   wire [31:0] Iimm = {{21{instr[31]}}, instr[30:20]};
   wire [31:0] Simm = {{21{instr[31]}}, instr[30:25], instr[11:7]};
   /* verilator lint_off UNUSED */ // MSBs of Bimm and Jimm are not used if ADDR_WIDTH is less than 32
   wire [31:0] Bimm = {{20{instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0};
   wire [31:0] Jimm = {{12{instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0};
   /* verilator lint_on UNUSED */

   // Base RISC-V (RV32I) has only 10 different instructions !
   // We do not test for erroneous opcodes (and the two LSBs are ignored)
   wire isLoad    =  (instr[6:2] == 5'b00000); // rd <- mem[rs1+Iimm]
   wire isALUimm  =  (instr[6:2] == 5'b00100); // rd <- rs1 OP Iimm
   wire isAUIPC   =  (instr[6:2] == 5'b00101); // rd <- PC + Uimm
   wire isStore   =  (instr[6:2] == 5'b01000); // mem[rs1+Simm] <- rs2
   wire isALUreg  =  (instr[6:2] == 5'b01100); // rd <- rs1 OP rs2
   wire isLUI     =  (instr[6:2] == 5'b01101); // rd <- Uimm
   wire isBranch  =  (instr[6:2] == 5'b11000); // if(rs1 OP rs2) PC<-PC+Bimm
   wire isJALR    =  (instr[6:2] == 5'b11001); // rd <- PC+4; PC<-rs1+Iimm
   wire isJAL     =  (instr[6:2] == 5'b11011); // rd <- PC+4; PC<-PC+Jimm
   wire isSYSTEM  =  (instr[6:2] == 5'b11100); // rd <- cycles

   wire isALU = isALUimm | isALUreg;

   /***************************************************************************/
   // The register file.
   /***************************************************************************/

   reg [31:0] rs1Data;
   reg [31:0] rs2Data;
   reg [31:0] registerFile [31:0];

   always @(posedge clk) begin
     if (writeBack)
       if (rd != 0)
         registerFile[rd] <= writeBackData;
   end

   /***************************************************************************/
   // The ALU.
   /***************************************************************************/

   wire aluWr;
   wire [31:0] aluOut;
   wire        predicate;
   wire        aluBusy;
   
   ALU alu(
     .clk(clk),
     .wr(aluWr),
     .isALU(isALU),	   
     .in1(rs1Data),
     .in2(isALUreg | isBranch ? rs2Data : Iimm),
     .out(aluOut),
     .predicate(predicate),
     .busy(aluBusy),
     .funct3(funct3),
     .add_sub(instr[30] & instr[5]), // instr[30] is 1 for SUB and 0 for ADD, need to test also instr[5] because ADDI imm uses bit 30 !
     .srl_sra(instr[30]),	   
   );
   
   /***************************************************************************/
   // Program counter and branch target computation.
   /***************************************************************************/

   reg  [ADDR_WIDTH-1:0] PC; // The program counter.
   reg  [31:2] instr;        // Latched instruction. Note that bits 0 and 1 are
                             // ignored (not used in RV32I base instruction set).

   wire [ADDR_WIDTH-1:0] PCplus4 = PC + 4;

   // An adder used to compute branch address, JAL address and AUIPC.
   // branch->PC+Bimm    AUIPC->PC+Uimm    JAL->PC+Jimm
   // Equivalent to PCplusImm = PC + (isJAL ? Jimm : isAUIPC ? Uimm : Bimm)
   // wire [ADDR_WIDTH-1:0] PCplusImm = PC + (instr[3] ? Jimm[ADDR_WIDTH-1:0] : instr[4] ? Uimm[ADDR_WIDTH-1:0] : Bimm[ADDR_WIDTH-1:0]);

   wire [ADDR_WIDTH-1:0] rs1_or_PC = (isLoad | isStore | isJALR) ? rs1Data[ADDR_WIDTH-1:0] : PC;
   wire [ADDR_WIDTH-1:0] addrImm = isJAL    ? Jimm[ADDR_WIDTH-1:0] :
			           isAUIPC  ? Uimm[ADDR_WIDTH-1:0] :
			           isStore  ? Simm[ADDR_WIDTH-1:0] :
			           isBranch ? Bimm[ADDR_WIDTH-1:0] :
			                      Iimm[ADDR_WIDTH-1:0] ; // LOAD and JALR
   reg [ADDR_WIDTH-1:0]  computedAddr;

   /***************************************************************************/
   // The value written back to the register file.
   /***************************************************************************/

   wire [31:0] writeBackData  =
      /* verilator lint_off WIDTH */	       	       
      (isSYSTEM            ? cycles               : 32'b0) |  // SYSTEM
      /* verilator lint_on WIDTH */	       	       	       
      (isLUI               ? Uimm                 : 32'b0) |  // LUI
      (isALU               ? aluOut               : 32'b0) |  // ALU reg reg and ALU reg imm
      (isAUIPC             ? {ADDR_PAD,computedAddr} : 32'b0) |  // AUIPC
      (isJALR   | isJAL    ? {ADDR_PAD,PCplus4  } : 32'b0) |  // JAL, JALR
      (isLoad              ? LOAD_data            : 32'b0);   // Load

   /***************************************************************************/
   // LOAD/STORE
   /***************************************************************************/

   // All memory accesses are aligned on 32 bits boundary. For this
   // reason, we need some circuitry that does unaligned word
   // and byte load/store, based on:
   // - funct3[1:0]:   00->byte 01->halfword 10->word
   // - addr_reg[1:0]: indicates which byte/halfword is accessed

   wire mem_byteAccess     = instr[13:12] == 2'b00; // funct3[0] | funct3[4]; // funct3[1:0] == 2'b00;
   wire mem_halfwordAccess = instr[13:12] == 2'b01; // funct3[1] | funct3[5]; // funct3[1:0] == 2'b01;

   // LOAD, in addition to funct3[1:0], LOAD depends on:
   // - funct3[2]:        0->sign expansion   1->no sign expansion

   wire LOAD_sign = !instr[14] & (mem_byteAccess ? LOAD_byte[7] : LOAD_halfword[15]);

   wire [31:0] LOAD_data =
         mem_byteAccess ? {{24{LOAD_sign}},     LOAD_byte} :
     mem_halfwordAccess ? {{16{LOAD_sign}}, LOAD_halfword} :
                          mem_rdata ;

   wire [15:0] LOAD_halfword = addr_reg[1] ? mem_rdata[31:16]    : mem_rdata[15:0];
   wire  [7:0] LOAD_byte     = addr_reg[0] ? LOAD_halfword[15:8] : LOAD_halfword[7:0];

   // STORE

   assign mem_wdata[ 7: 0] =               rs2Data[7:0];
   assign mem_wdata[15: 8] = addr_reg[0] ? rs2Data[7:0] :                               rs2Data[15: 8];
   assign mem_wdata[23:16] = addr_reg[1] ? rs2Data[7:0] :                               rs2Data[23:16];
   assign mem_wdata[31:24] = addr_reg[0] ? rs2Data[7:0] : addr_reg[1] ? rs2Data[15:8] : rs2Data[31:24];

   // The memory write mask:
   //    1111                     if writing a word
   //    0011 or 1100             if writing a halfword (depending on addr_reg[1])
   //    0001, 0010, 0100 or 1000 if writing a byte     (depending on addr_reg[1:0])

   wire [3:0] STORE_wmask =
       mem_byteAccess ? (addr_reg[1] ? (addr_reg[0] ? 4'b1000 : 4'b0100) :   (addr_reg[0] ? 4'b0010 : 4'b0001) ) :
   mem_halfwordAccess ? (addr_reg[1] ?                4'b1100            :                  4'b0011            ) :
                                                      4'b1111;

   /*************************************************************************/
   // And, last but not least, the state machine.
   /*************************************************************************/
   // The states, using 1-hot encoding (see note [2] at the end of this file).

   localparam FETCH_INSTR_bit     = 0;
   localparam WAIT_INSTR_bit      = 1;
   localparam EXECUTE1_bit        = 2;
   localparam EXECUTE2_bit        = 3;   
   localparam LOAD_bit            = 4;
   localparam STORE_bit           = 5;   
   localparam WAIT_ALU_OR_MEM_bit = 6;
   localparam NB_STATES           = 7;

   localparam FETCH_INSTR     = 1 << FETCH_INSTR_bit;
   localparam WAIT_INSTR      = 1 << WAIT_INSTR_bit;
   localparam EXECUTE1        = 1 << EXECUTE1_bit;
   localparam EXECUTE2        = 1 << EXECUTE2_bit;   
   localparam LOAD            = 1 << LOAD_bit;
   localparam WAIT_ALU_OR_MEM = 1 << WAIT_ALU_OR_MEM_bit;
   localparam STORE           = 1 << STORE_bit;

   (* onehot *)
   reg [NB_STATES-1:0] state;

   // The signals (internal and external) that are determined
   // combinatorially from state and other signals.

   // register write-back enable.
   wire  writeBack = ~(isBranch | isStore ) & (state[EXECUTE2_bit] | state[WAIT_ALU_OR_MEM_bit]);

   // The memory-read signal.
   assign mem_rstrb = state[LOAD_bit] | state[FETCH_INSTR_bit];

   // The mask for memory-write.
   assign mem_wmask = {4{state[STORE_bit]}} & STORE_wmask;

   // aluWr starts computation in the ALU.
   assign aluWr = state[EXECUTE1_bit]; 

   wire jumpOrTakeBranch = isJAL | isJALR | (isBranch & predicate);

   always @(posedge clk) begin
      if(!reset) begin
         state      <= WAIT_ALU_OR_MEM; // Just waiting for !mem_wbusy
         PC         <= RESET_ADDR[ADDR_WIDTH-1:0];
      end else

      // See note [1] at the end of this file.
      (* parallel_case, full_case *)
      case(1'b1)

        // *********************************************************************	
	state[FETCH_INSTR_bit]: begin
	   state <= WAIT_INSTR;
	end
	
        // *********************************************************************
        state[WAIT_INSTR_bit]: begin
           if(!mem_rbusy) begin // rbusy may be high when executing from SPI flash
              rs1Data <= registerFile[mem_rdata[19:15]];
              rs2Data <= registerFile[mem_rdata[24:20]];
              instr <= mem_rdata[31:2]; // Note that bits 0 and 1 are ignored (see
              state <= EXECUTE1;        //          also the declaration of instr).
           end
        end

        // *********************************************************************
        state[EXECUTE1_bit]: begin
	   computedAddr <= rs1_or_PC + addrImm;
	   state <= EXECUTE2;
	end
	
        // *********************************************************************
        state[EXECUTE2_bit]: begin

           // Prepare next PC
           PC <= jumpOrTakeBranch ? computedAddr : PCplus4;

           // Prepare address for:
           //  next instruction fetch: PCplusImm (taken branch, JAL), aluPlus (JALR), PCplus4 (all other instr.)
           //  load/store: aluPlus
           addr_reg <= isStore | isLoad | jumpOrTakeBranch ? computedAddr : PCplus4;

           state <= isLoad            ? LOAD             : 
		    isStore           ? STORE            : 
		    (isALU & aluBusy) ? WAIT_ALU_OR_MEM  : 
		                        FETCH_INSTR      ;
        end 
	
        // *********************************************************************
        state[LOAD_bit]: begin
	   state <= WAIT_ALU_OR_MEM;
	end
	
        // *********************************************************************
        state[STORE_bit]: begin
`ifdef NRV_IS_IO_ADDR
	   state <= `NRV_IS_IO_ADDR(addr_reg) ? WAIT_ALU_OR_MEM : FETCH_INSTR;
	   addr_reg <= PC;
`else
	   state <= WAIT_ALU_OR_MEM;
`endif	   
        end
	
        // *********************************************************************
        state[WAIT_ALU_OR_MEM_bit]: begin
           // Used by LOAD,STORE and by multi-cycle ALU instr (shifts and RV32M ops),
           // writeback from ALU or memory, also waits from data from IO
           // (listens to mem_rbusy and mem_wbusy)
           if(!aluBusy & !mem_rbusy & !mem_wbusy) begin
              addr_reg <= PC;
              state <= FETCH_INSTR;
           end
        end
	
      endcase
   end

   /***************************************************************************/
   // Cycle counter
   /***************************************************************************/

`ifdef NRV_COUNTER_WIDTH
   reg [`NRV_COUNTER_WIDTH-1:0]  cycles;   
`else   
   reg [31:0]  cycles;
`endif   
   always @(posedge clk) cycles <= cycles + 1;

endmodule

/*****************************************************************************/
// Notes:
//
// [1] About the "reverse case" statement, also used in Claire Wolf's picorv32:
// It is just a cleaner way of writing a series of cascaded if() statements,
// To understand it, think about the case statement *in general* as follows:
// case (expr)
//       val_1: statement_1
//       val_2: statement_2
//   ... val_n: statement_n
// endcase
// The first statement_i such that expr == val_i is executed. Now if expr is 1'b1:
// case (1'b1)
//       cond_1: statement_1
//       cond_2: statement_2
//   ... cond_n: statement_n
// endcase
// It is *exactly the same thing*, the first statement_i such that
// expr == cond_i is executed (that is, such that 1'b1 == cond_i,
// in other words, such that cond_i is true)
// More on this: https://stackoverflow.com/questions/15418636/case-statement-in-verilog
//
// [2] state uses 1-hot encoding (at any time, state has only one bit set to 1).
// It uses a larger number of bits (one bit per state), but often results in
// a both more compact (fewer LUTs) and faster state machine.
