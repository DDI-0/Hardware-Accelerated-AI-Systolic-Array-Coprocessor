# Hardware-Accelerated AI Systolic Array Coprocessor

## Project Overview
This project implements a parameterizable $N \times N$ Systolic Array accelerator in VHDL, designed specifically for high-throughput matrix multiplication workloads common in quantized (INT8/UINT8) neural network inference. 

The core IP is integrated into an **Intel Agilex 5 SoC** using Intel Platform Designer (Qsys). It utilizes Avalon-MM (Memory-Mapped) for Control and Status Registers (CSRs) and Avalon-ST (Streaming) pipelines to interface with Modular Scatter-Gather DMAs (mSGDMA) for high-bandwidth data ingestion and result extraction.

This hardware/software co-design was brought up and verified directly on the **Terasic DE25-Standard** development board.

## Architecture & Features

### 1. Compute Core (Parameterized $N \times N$ Array)
The computational heart of the system is the `systolic_array` core. It is fully parameterized (`generic N`) and highly scalable. For this specific SoC implementation, it is instantiated as a $4 \times 4$ array to perfectly match the 32-bit streaming DMA bus (capable of feeding exactly four 8-bit operands per clock cycle).
*   **AI Tensor Blocks:** The INT8 MAC (Multiply-Accumulate) operations are designed to map directly to the Agilex 5 DSP elements (AI Tensor Blocks), maximizing $F_{MAX}$ and minimizing logic utilization.
*   **Synopsys Design Constraints (SDC):** The datapath is heavily pipelined and constrained via SDC files to achieve strict timing closure.

### 2. Control & Data Flow (Mealy FSM)
Systolic Arrays require precise, clock-cycle-accurate diagonal data skewing to function correctly. This project eschews a software-managed data flow in favor of a **Custom Hardware Mealy FSM**. 
*   **Autonomous Pipelining:** The FSM handles diagonal data skewing automatically, relieving the CPU of cycle-by-cycle management.
*   **Result Serialization:** Captures the massive 512-bit parallel result vector (16 MAC accumulators $\times$ 32-bits) and serializes it out to the downstream Avalon-ST FIFOs.

### 3. System-on-Chip (SoC) Integration
*   **Platform Designer:** The IP is packaged and integrated via standard AMBA-style Avalon interconnects.
*   **Avalon-MM:** Provides a memory-mapped CSR interface for the CPU to assert start pulses, monitor busy/done flags, and check FIFO levels.
*   **Avalon-ST:** Dual streaming interfaces connect directly to mSGDMAs, allowing the CPU to point the DMAs at physical memory addresses and let the hardware handle the movement.

## Toolchain
*   **Hardware Description:** VHDL-2008
*   **Synthesis & Implementation:** Intel Quartus Prime Pro
*   **SoC Integration:** Platform Designer (Qsys)
*   **On-Chip Verification:** System Console, TCL, JTAG Master

## Verification & Bring-Up
Silicon bring-up was executed entirely over a JTAG bridge using **System Console**. TCL scripts were developed to:
1. Act as the Avalon-MM Master to configure the IP's CSRs.
2. Load Matrix A and Matrix B into SDRAM.
3. Configure and arm the Scatter-Gather DMAs.
4. Read the resultant Matrix C from memory and mathematically verify it against a golden reference model.

## Known Errata & Debugging Notes
During on-silicon verification, two critical integration hurdles were encountered and documented:

### 1. JTAG / System Console Endianness
The System Console `master_write_32` commands byte-swap data under the hood when writing to the Avalon fabric. To counter this, the verification TCL scripts pack input matrix vectors using explicit Big-Endian formatting, and a `swap_endian_32` helper function is used to un-swap the 32-bit results for mathematical verification.

### 2. Synchronous FIFO 1-Cycle Read Latency (M20K Block RAM)
When the `sa_fifo` component was mapped to physical Agilex M20K Block RAMs, the Fitter successfully inferred the memory but introduced an unavoidable 1-cycle synchronous read latency. 

Because the Mealy FSM was originally designed assuming a combinational FWFT (First-Word Fall-Through) FIFO, this 1-cycle latency misaligned the data ingestion. The result was a mathematically correct MAC calculation, but with a spatial row-shift anomaly (outputting `220, 230, 240, 210` instead of the expected `210, 220, 230, 240`). 

