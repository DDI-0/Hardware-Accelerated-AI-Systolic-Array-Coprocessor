# Makefile for Systolic Array -- GHDL + Questa UVM

GHDL       := ghdl
GHDL_FLAGS := --std=08

SRC_PKG := src/packages
SRC_RTL := src/rtl
SRC_TOP := src/top
SRC_TB  := test

# Design files in dependency order (leaf -> top)
SRCS := \
	$(SRC_RTL)/systolic_pe.vhd \
	$(SRC_TOP)/systolic_pe_wrap.vhd \
	$(SRC_TOP)/systolic_array.vhd

# Avalon wrapper files (depends on base SRCS)
AVALON_SRCS := \
	$(SRC_PKG)/sa_avalon_pkg.vhd \
	$(SRC_RTL)/sa_fifo.vhd \
	$(SRC_RTL)/sa_csr.vhd \
	$(SRC_RTL)/sa_skew_fsm.vhd \
	$(SRC_RTL)/sa_result_capture.vhd \
	$(SRC_TOP)/sa_avalon_top.vhd

ALL_SRCS := $(SRCS) $(AVALON_SRCS)

# VHDL testbench
TB_SRC  := $(SRC_TB)/systolic_array_tb.vhd
TB_UNIT := systolic_array_tb

.PHONY: analyze analyze_avalon sim run wave clean \
        uvm_compile uvm_unsigned uvm_signed uvm_random uvm_clean


analyze: $(SRCS)
	@echo "=== Analyzing VHDL sources ==="
	@for f in $(SRCS); do \
		echo "  ghdl -a $$f"; \
		$(GHDL) -a $(GHDL_FLAGS) $$f || exit 1; \
	done
	@echo "=== Analysis complete ==="

# Analyze all sources including Avalon wrapper
analyze_avalon: $(ALL_SRCS)
	@echo "=== Analyzing all VHDL sources (core + Avalon) ==="
	@for f in $(ALL_SRCS); do \
		echo "  ghdl -a $$f"; \
		$(GHDL) -a $(GHDL_FLAGS) $$f || exit 1; \
	done
	@echo "=== Analysis complete ==="

sim: analyze
	@echo "=== Analyzing testbench ==="
	$(GHDL) -a $(GHDL_FLAGS) $(TB_SRC)
	@echo "=== Elaborating $(TB_UNIT) ==="
	$(GHDL) -e $(GHDL_FLAGS) $(TB_UNIT)

run: sim
	@echo "=== Running $(TB_UNIT) ==="
	$(GHDL) -r $(GHDL_FLAGS) $(TB_UNIT) --stop-time=500ns

wave: sim
	@echo "=== Running $(TB_UNIT) with VCD dump ==="
	$(GHDL) -r $(GHDL_FLAGS) $(TB_UNIT) --stop-time=500ns --vcd=systolic_array.vcd
	@echo "=== Waveform saved to systolic_array.vcd ==="

clean:
	$(GHDL) --clean
	rm -f *.cf *.o *.vcd $(TB_UNIT)


UVM_TB  := test/uvm
WORK    := work

# Compile all sources (VHDL + SystemVerilog)
uvm_compile:
	@echo "=== Creating work library ==="
	vlib $(WORK)
	@echo "=== Compiling VHDL design ==="
	vcom -2008 -work $(WORK) \
		$(SRC_RTL)/systolic_pe.vhd \
		$(SRC_TOP)/systolic_pe_wrap.vhd \
		$(SRC_TOP)/systolic_array.vhd
	@echo "=== Compiling SystemVerilog UVM testbench ==="
	vlog -sv -work $(WORK) +incdir+$(UVM_TB) \
		$(UVM_TB)/sa_if.sv \
		$(UVM_TB)/sa_pkg.sv \
		$(UVM_TB)/sa_top.sv
	@echo "=== Compilation complete ==="

# Run unsigned test (SIGNED_ARITH=false)
uvm_unsigned: uvm_compile
	@echo "=== Running sa_unsigned_test ==="
	vsim -c -do "run -all; quit -f" \
		-g/sa_top/u_dut/SIGNED_ARITH=false \
		+UVM_TESTNAME=sa_unsigned_test \
		+SIGNED_MODE=0 \
		$(WORK).sa_top

# Run signed test (SIGNED_ARITH=true)
uvm_signed: uvm_compile
	@echo "=== Running sa_signed_test ==="
	vsim -c -do "run -all; quit -f" \
		-g/sa_top/u_dut/SIGNED_ARITH=true \
		+UVM_TESTNAME=sa_signed_test \
		+SIGNED_MODE=1 \
		$(WORK).sa_top

# Run random test with configurable mode (default unsigned)
# Usage: make uvm_random SIGNED=0   or   make uvm_random SIGNED=1
SIGNED ?= 0
ifeq ($(SIGNED),1)
  ARITH_VAL := true
else
  ARITH_VAL := false
endif

uvm_random: uvm_compile
	@echo "=== Running sa_random_test (SIGNED_MODE=$(SIGNED)) ==="
	vsim -c -do "run -all; quit -f" \
		-g/sa_top/u_dut/SIGNED_ARITH=$(ARITH_VAL) \
		+UVM_TESTNAME=sa_random_test \
		+SIGNED_MODE=$(SIGNED) \
		$(WORK).sa_top

# Clean Questa artifacts
uvm_clean:
	rm -rf $(WORK) transcript vsim.wlf modelsim.ini
