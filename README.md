# Hardware-Accelerated 4x4 Systolic Array Coprocessor

Hardware-accelerated 2D Systolic Array matrix multiplier coprocessor in VHDL, integrated into an Intel Agilex 5 FPGA SoC via Avalon-MM and Avalon-ST interconnects.

---

## Overview

* **Architecture:** Fixed $4 \times 4$ 2D Systolic Array (16 Multiply-Accumulate Processing Elements).
* **Target Silicon:** Intel Agilex 5 FPGA SoC (`A5ED013BB32AE4SCS`).
* **Status:** Verified on physical hardware (50 MHz).

---

## Specifications

| Parameter | Specification | Notes |
|---|---|---|
| **Matrix Size** | $4 \times 4$ (fixed) | Computes $C = A \times B$ |
| **Input Data** | Signed 8-bit (`INT8`) | Range: $-128$ to $+127$ |
| **Accumulator** | Signed 32-bit (`INT32`) | No overflow |
| **Clock** | 50.0 MHz (`PIN_D8`) | Single synchronous domain |
| **Latency** | ~18 clock cycles | ~360 ns compute phase |
| **Throughput** | 16 MACs / cycle | Peak 800 MMACs/sec @ 50 MHz |
| **Input Interface** | Avalon-ST Sink (32-bit) | Fed by `msgdma_0` (32 bytes total) |
| **Output Interface** | Avalon-ST Source (32-bit) | Drained by `msgdma_1` (64 bytes total) |
| **Control** | Avalon-MM Slave (32-bit) | CSR base: `0x00001000` |

---

## Architecture

* **`systolic_pe.vhd`:** Pipelined MAC cell ($C \leftarrow C + A \times B$) passing operands eastward and southward each clock.
* **`sa_skew_fsm.vhd`:** Mealy/Moore controller handling 7-cycle input skewing, 7-cycle flush, settling, and atomic capture.
* **`sa_fifo.vhd`:** Synchronous FWFT buffer with 0-cycle combinational read latency.
* **`sa_result_capture.vhd`:** Latches 512-bit parallel result bus and serializes into sixteen 32-bit words.
* **`sa_csr.vhd`:** Avalon-MM registers (`0x00` CTRL, `0x04` STATUS, `0x08` CONFIG).
* **`system_top.vhd`:** Board top-level mapping clock, reset push-button, and status LEDs.

---

## Notes

* **Post-Programming Reset:** Must press `KEY[0]` (`PIN_BW59`) after programming over JTAG to clear configuration glitches and sync Avalon/DMA engines.
* **JTAG Endianness:** System Console JTAG master writes in Big-Endian byte-lane order; pack row words with Column 0 in the MSB (bits `[31:24]`).
* **FIFO Synthesis:** `sa_fifo` must use distributed LUTs (`ramstyle = "logic"`) to avoid M20K 1-cycle synchronous read latency.
* **Pipeline Flush:** `SA_FLUSH_CYCLES` set to 7 to allow the deepest node (`PE(3,3)`) to complete accumulation before capture.

---

## Verification

### Running the Test
1. Compile `systolic_array.qpf` in Quartus Prime Pro.
2. Program `.sof` using Programmer.
3. Press `KEY[0]` on the board.
4. In System Console, navigate to the project directory and run:
   ```tcl
   source scripts/test_systolic_array.tcl
   ```

### Verified Test Case
* **Matrix A:** $[1..16]$
* **Matrix B:** $[17..32]$
* **Matrix C ($A \times B$):**
  ```text
   250   260   270   280
   618   644   670   696
   986  1028  1070  1112
  1354  1412  1470  1528
  ```
