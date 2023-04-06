ISSUE Module
===============

Description
-----------

Functionality
-------------

Architecture and Submodules
---------------------------


CVA6 Scoreboard
~~~~~~~~~~~~~~~

Miscellaneous Scoreboard Interface Signals 
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
.. list-table:: Scoreboard interface signals
   :header-rows: 1

   * - Signal
     - IO
     - connection
     - Type
     - Description

   * - ``clk_i``
     - in
     - SUBSYSTEM
     - logic
     - Subsystem Clock

   * - ``rst_ni``
     - in
     - SUBSYSTEM
     - logic
     - Asynchronous reset active low

   * - ``sb_full_o``
     - out
     - ISSUE
     - logic
     - The issue queue is full don't issue any new instructions

   * - ``flush_unissued_instr_i``
     - in
     - CONTROLLER
     - logic
     - Flush only un-issued instructions

   * - ``flush_i``
     - in
     - CONTROLLER
     - logic
     - Flush whole scoreboard

   * - ``unresolved_branch_i``
     - in
     - ISSUE
     - logic
     - We have an unresolved branch

   * - ``rd_clobber_gpr_o``
     - out
     - ISSUE
     - ariane_pkg::fu_t [2**ariane_pkg::REG_ADDR_SIZE-1:0]
     - List of clobbered registers to issue stage for gpr


   * - ``rd_clobber_fpr_o``
     - out
     - ISSUE
     - ariane_pkg::fu_t [2**ariane_pkg::REG_ADDR_SIZE-1:0]
     - List of clobbered registers to issue stage for fpr

   * - ``rs1_i``
     - in
     - ISSUE
     - logic[5:0]
     - register source address 1
  
   * - ``rs1_o``
     - out
     - ISSUE
     - logic[63:0]
     - rs1 register data  

   * - ``rs1_valid_o``
     - out
     - ISSUE
     - logic
     - Indicates whether the data for rs1 register is valid

   * - ``rs2_i``
     - in
     - ISSUE
     - logic[5:0]
     - register source address 2

   * - ``rs2_o``
     - out
     - ISSUE
     - logic[63:0]
     - rs2 register data
   
   * - ``rs2_valid_o``
     - out
     - ISSUE
     - logic
     - Indicates whether the data for rs2 register is valid
   
   * - ``rs3_i``
     - in
     - ISSUE
     - logic[5:0]
     - register source address 3

   * - ``rs3_o``
     - out
     - ISSUE
     - logic[63:0]
     - rs3 register data
   
   * - ``rs3_valid_o``
     - out
     - ISSUE
     - logic
     - Indicates whether the data for rs3 register is valid
   
   * - ``commit_instr_o``
     - out
     - COMMIT
     - scoreboard_entry_t [NR_COMMIT_PORTS-1:0]
     - Advertise instruction to commit stage, if commit_ack_i is asserted advance the commit pointer

   * - ``commit_ack_i``
     - in
     - COMMIT
     - logic
     - Handshake signal for commiting an instruction
    
   * - ``decoded_instr_i``
     - in
     - DECODE
     - scoreboard_entry_t
     - Instruction to put on top of scoreboard e.g.: top pointer. We can always put this instruction to the top unless we signal with asserted full_o

   * - ``decoded_instr_valid_i``
     - in
     - DECODE
     - logic
     - Decoded instruction is valid
   
   * - ``decoded_instr_ack_o``
     - out
     - DECODE
     - logic
     - Handshake signal for issuing Decoded Instruction
   
   * - ``issue_instr_o``
     - out
     - ISSUE
     - scoreboard_entry_t 
     - Instruction to issue logic, if issue_instr_valid and issue_ready is asserted, advance the issue pointer

   * - ``issue_instr_valid_o``
     - out
     - ISSUE
     - logic 
     - Instruction being issued is valid

   * - ``issue_ack_i``
     - in
     - ISSUE
     - logic
     - Acknowledge the issue of an instruction
    
   * - ``resolved_branch_i``
     - in
     - EXCUTE
     - bp_resolve_t
     - write-back port - resolved branch info


   * - ``trans_id_i``
     - in
     - EXCUTE
     - logic [NR_WB_PORTS-1:0][ariane_pkg::TRANS_ID_BITS-1:0]
     - Transaction ID at which to write the result back
   
   * - ``wbdata_i``
     - in
     - EXCUTE
     - logic [NR_WB_PORTS-1:0][riscv::XLEN-1:0]
     - Write data in
   
   * - ``ex_i``
     - in
     - EXCUTE
     - ariane_pkg::exception_t [NR_WB_PORTS-1:0] 
     - Exception from a functional unit (e.g.: ld/st exception)

   * - ``wt_valid_i``
     - in
     - EXCUTE
     - [NR_WB_PORTS-1:0]
     - Writeback Data is valid
    
   * - ``x_we_i``
     - in
     - EXCUTE
     - logic
     - cvxif we for writeback
   
   * - ``lsu_addr_i``
     - in
     - ISSUE
     - [riscv::VLEN-1:0]
     - Address to the Load store unit
   
   * - ``lsu_rmask_i``
     - in
     - ISSUE
     - [(riscv::XLEN/8)-1:0]
     - read maskfor the load store unit 
   
   * - ``lsu_wmask_i``
     - in
     - ISSUE
     - [(riscv::XLEN/8)-1:0]  
     - write mask for the load store unit
   
   * - ``lsu_addr_trans_id_i``
     - in
     - ISSUE
     - [ariane_pkg::TRANS_ID_BITS-1:0]  
     - Transaction identifier
   
   * - ``rs1_forwarding_i``
     - in
     - ISSUE
     - riscv::xlen_t
     - unregistered version of fu_data_o.operanda
    
   * - ``rs2_forwarding_i``
     - in
     - ISSUE
     - riscv::xlen_t 
     - unregistered version of fu_data_o.operandb

The Scoreboard logic sits between the issue queue and the functional
units and as stated in the CVA6 documentation its main purpose is to
“…\ *decouple the check for data (WAW, RAW) and structural hazards*.” It
takes full responsibility for:

1. Issuing instructions to the appropriate functional units.

2. Tracking instructions as they get executed.

3. Controlling the bypass paths to supply operands,

4. Committing the instructions when they have finished execution at the
      appropriate time (when they are at the head of the scoreboard
      circular buffer) by updating the appropriate destination registers

5. Signaling appropriate exceptions if the instruction to be committed
      has generated an exception.

Inserting an Instructions in the Scoreboard
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

   A scalar instruction (referred to as a *new* instruction) is inserted
   into the scoreboard **(i.e., moves from the issue queue to the
   scoreboard)** when all the following conditions are met:

1. There is no WAW dependency between the new instruction and any
      instruction present in the scoreboard. This prevents WAW data
      dependencies by holding to the new instruction in the instruction
      queue if there is an earlier *uncommitted* instruction with the
      same destination register as the new instruction.

..

   **Note**: In case of back to back WAW dependent instructions the new
   instruction can be inserted in the scoreboard in the same cycle as
   the earlier dependent instruction is committed.

2. There is no RAW dependency between the new instruction and any
      *incomplete* instruction (not finished execution) present in the
      scoreboard. A RAW dependent instruction is only inserted in the
      scoreboard when all its operands are available (see section
      Issuing Instructions from the Scoreboard.)

3. There is no divide (DIV) instruction in the scoreboard, i.e., a
      divide instruction stalls the scoreboard until the divide
      instruction gets committed (see section.

4. If a multiply (MULT) instruction is in the scoreboard then *only* a
      new multiply or divide instruction can be inserted into the
      scoreboard.

5. If a branch (all types of branch instruction) instruction is in the
      scoreboard then a new branch instruction cannot be inserted in the
      scoreboard.

6. When an instruction which is writing to any CSR is inserted into the
      scoreboard all instruction insertion is stopped. This continues
      until the CSR instruction is committed at which point the
      inserting process restarts.

Note that a new instruction can be inserted into the scoreboard and
issued to the appropriate functional unit for execution in the same
cycle. This allows functional units, which can be used for execution of
back to back instructions, to be used without inserting any dead cycles
between them – there is no cycle penalty for new instructions to be
inserted into the scoreboard.

Issuing Instructions from the Scoreboard
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Instructions are issued from the scoreboard whenever their operands are
available. Note that operands can be supplied from one of the following
three sources:

1. Register file.

2. Scoreboard in case of an earlier completed but non-committed
      instruction.

3. From the output of a functional unit, using its bypass path, for
      instructions which finish in the cycle just before the new
      instruction is issued for execution.

Which source gets used for a particular operand is determined at the
time a new instruction is inserted into the scoreboard. Note that
because of number 3 above, back to back instructions with RAW
dependencies, when allowed, can execute without any dead cycles between
them.

Committing Instructions from the Scoreboard
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

When an instruction gets at the head of the scoreboard (which works like
a circular buffer) and it has completed execution it can get committed
if it has not generated an exception. On commitment:

1. The destination register, if any, is updated.

2. The instruction is deleted from the scoreboard by clearing the
      corresponding *issued* and *valid* bits.

In case it has generated an exception:

1. The scoreboard is flushed.

2. An exception is signaled to the instruction fetch unit along with the
      type of the exception etc., so that the exception handler
      instructions can be fetched.

Furthermore an instruction being committed can update its destination
register and supply it as an operand to a new instruction in the same
cycle.

At most the scoreboard can commit two instructions from the head of the
scoreboard in a single cycle.

Scoreboard Flush
^^^^^^^^^^^^^^^^

The following conditions cause the scoreboard to be flushed:

1. The committed instruction generated an exception.

2. An interrupt is taken.

3. The branch instruction was incorrectly predicted.

On a flush the appropriate scoreboard entries are invalidated by
clearing their *valid* bits.

Scoreboard Structure
^^^^^^^^^^^^^^^^^^^^

The depth of the scoreboard is statically configured as an 8-entry
circular FIFO managed via three pointers and a 3-bit count register.

Scoreboard Pointers
^^^^^^^^^^^^^^^^^^^

When an instruction is issued (i.e., inserted into the scoreboard) the
*Issue Pointer* is incremented and points to the next empty slot of the
scoreboard. The *Issue Pointer* gets wrapped around when it points to
the last location in the scoreboard.

There are two *Commit Pointers* which are always pointing to two
neighboring locations in the scoreboard. They also get individually
wrapped around when either one of them ends pointing to the first
location. Every time an instruction gets committed the corresponding
*Commit Pointer* is decremented by one. In a single cycle either 1 or 2
instructions get committed. If a single instruction gets committed then
it’s always the oldest instruction in the scoreboard and when two
instructions get committed then they are the oldest and the second
oldest instruction in the scoreboard.

The *Count Register* tracks all non-committed instructions. It gets
incremented whenever a new instruction is issued and decremented, by 1
or 2, whenever 1 or 2 instructions can get committed.

Scoreboard Entry
^^^^^^^^^^^^^^^^

Each entry of the scoreboard consists of the following fields and are generated for every instruction that is inserted in the scoreboard.


.. list-table:: 
   :header-rows: 1

   * - Name
     - Abbreviation
     - Description
  
   * - Program Counter
     - pc
     - Program counter of the instruction 
  
   * - Transaction ID
     - trans_id
     - This can take a value from 0-7. It is basically a value representing the issue pointer 

   * -  Functional unit
     -  fu
     -  Which type of functional unit this instruction is going to use. Currently the following units can be:

          1) ALU (for all instructions other than multiply, divide, load & stores)
       
          2) Multiplier (for multiply & divide instructions)
                                                                    
          3) LSU (for load & store instructions)

   * - Operation
     - op
     - The actual operation that the functional unit will perform
  
   * - Source Register 1
     - rs1
     - First source register (*rs1*) address of instruction

   * - Source Register 2
     - rs2
     - Second source register (*rs2*) address of instruction

   * - Destination Register
     - rd
     - Destination register (*rd*) address of instruction
  
   * - Result\*
     - result
     - For finished instructions this field holds the value of the destination register. For unfinished instructions, depending on the instruction type, this filed can hold the  
       following items:                           
      
        1. Instructions which have an immediate field this field hold the immediate value                          
      
        2. For some floating-point instructions that are partially encoded in rs2,this field also holds the rs2 field
      
        3. For some floating-point fused instructions (FMADD, FMSUB, FNMADD,  FNMSUB) this field holds the address of the third source operand (*rs3*)

   * - Valid\*
     - valid
     - Indicates that the result is valid, i.e.,the instruction has finished execution and the result has been updated in the result field
  
   * - Use Immediate
     - use_imm
     - The instruction has an immediate field (the immediate value is in the result field)
  
   * - Use Zero Extended Immediate
     - use_zimm
     - Immediate operand should be zero extended

   * - Use Program Counter
     - use_pc
     - Set if we need to use the PC as an operand (for branches) or PC for an exception 
   
   * - Exception Valid\*
     - ex.valid 
     - Set if the instruction generated an exception
  
   * - Exception Cause\*
     - ex.cause 
     - Exception cause as listed in the RISC V Privileged Specification
 
   * - Exception Trap Value\*
     - ex.tval 
     - Additional information regarding the exception (e.g.: instruction causing it)
  
   * - Branch predict scoreboard entry
     - bp 
     - Branch predict scoreboard data structure (used for debug purposes)
  
   * - Compressed Instruction Flag
     - is_compressed 
     - Signals a compressed instructions, we need his information at the commit stage to compute the target address/link address appropriately e.g.: +4, +2 


   * - Instruction issue valid\*
     - issued
     - This bit indicates whether this instruction has been issued for execution  It gets cleared when an instruction gets committed or the entry gets flushed 

   * - FP destination register valid
     - is_rd_fpr_flag
     - Redundant meta info, added for speed

Almost all the fields are initialized (if needed) when the instruction
is issued. The only fields which are updated when the instruction
actually starts or finishes execution are shown below and are marked
with an asterisk (*) in the table above:

1. | *result* and *valid*. The *result* field is an overloaded field being used to convey certain pieces of information to the execution unit (i.e., getting initialized at the time of instruction insertion) 
   | and getting updated with the result value after the instruction has finished execution.

2. *ex.valid*, *ex.cause* and *ex.tval*.

3. *issued*.

Scoreboard Ports
^^^^^^^^^^^^^^^^

The scoreboard read and write ports are statically configurable in the
design. It is currently configured to have four write ports and two read
ports.

The write ports are used to update the value in the scoreboard *result*
field after the instruction has finished execution. Additionally it is
used for updating the register file if the instruction gets committed in
the cycle after it finishes execution. The four busses are dedicated for
the following four execution units:

1. Load Unit

2. Store buffer

3. FPU

4. ALU, Mult/Div, CSR & branch

Before updating the scoreboard entry or the register file with the write
back data the scoreboard entry is checked to see if it is still valid.
Note that an entry can become invalid after it has been issued because
of a flush.

The read ports are used for committing instructions since 1 or 2
instructions can be committed in each cycle.


Register Clobbering
-------------------

The processor cannot handle WAW data dependencies. As such only a single
instruction which is updating a specific register (has it as its
destination) can exist in the scoreboard at any point in time. This is
managed by a set of bits called the clobber bits. There are a total of
64 bits, one for each of the 32 integer and 32 floating-point registers.

When an instruction, which has a specific destination register, is
inserted into the scoreboard the corresponding destination register
clobber bit is set. Before an instruction, which has a specific
destination register, is inserted into the scoreboard the corresponding
clobber bit is checked. If the bit is set then the pipeline stalls and
nothing is inserted into the scoreboard until that bit is cleared. When
the older instruction which was writing to the register is committed,
the corresponding clobber bit is cleared and the younger instruction is
inserted into the scoreboard again setting the clobber bit.

Note that all CSRs are treated as a single register. When an instruction
which is writing to any CSR is inserted into the scoreboard no new
instruction of *any* type is inserted into the pipeline. This continues
until the CSR instruction is committed at which point the inserting
process restarts.
