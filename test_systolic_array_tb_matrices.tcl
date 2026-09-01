# System Console JTAG Test Script 

set jtag_master [lindex [get_service_paths master] 0]
open_service master $jtag_master

puts "Phase 1: Safe Soft Reset"
master_write_32 $jtag_master 0x00001000 0x00000002
after 10

puts "Phase 1b: Clearing Result Memory"
for {set i 0} {$i < 16} {incr i} {
    master_write_32 $jtag_master [expr {0x0100 + $i*4}] 0xDEADBEEF
}

puts "Phase 2: Writing Input Matrices to RAM"
# Matrix A:
# 1 1 1 1
# 2 2 2 2
# 3 3 3 3
# 4 4 4 4
master_write_32 $jtag_master 0x00000000 0x01010101
master_write_32 $jtag_master 0x00000004 0x02020202
master_write_32 $jtag_master 0x00000008 0x03030303
master_write_32 $jtag_master 0x0000000C 0x04040404

# Matrix B:
# 10 10 10 10
# 20 20 20 20
# 30 30 30 30
# 40 40 40 40
# Hex equivalents: 10=0x0A, 20=0x14, 30=0x1E, 40=0x28
master_write_32 $jtag_master 0x00000010 0x0A0A0A0A
master_write_32 $jtag_master 0x00000014 0x14141414
master_write_32 $jtag_master 0x00000018 0x1E1E1E1E
master_write_32 $jtag_master 0x0000001C 0x28282828

puts "Phase 3: Arming Output DMA (msgdma_1) FIRST"
master_write_32 $jtag_master 0x00001080 0x00000100
master_write_32 $jtag_master 0x00001084 0x00000100
master_write_32 $jtag_master 0x00001088 64
master_write_32 $jtag_master 0x0000108C 0x80000000

puts "Phase 4: Arming Input DMA (msgdma_0)"
master_write_32 $jtag_master 0x00001090 0x00000000
master_write_32 $jtag_master 0x00001094 0x00000000
master_write_32 $jtag_master 0x00001098 32
master_write_32 $jtag_master 0x0000109C 0x80000000

puts "Phase 5: Starting Systolic Array"
master_write_32 $jtag_master 0x00001004 0x00000004
master_write_32 $jtag_master 0x00001000 0x00000001

set timeout 5000
set done 0
for {set i 0} {$i < $timeout} {incr i} {
    set status [master_read_32 $jtag_master 0x00001004 1]
    if {[expr {$status & 0x04}] != 0} {
        set done 1
        puts "Computation FINISHED! (STATUS=0x[format %08X $status], polls=$i)"
        break
    }
    after 1
}

puts "Phase 6: Reading Results"
set results [master_read_32 $jtag_master 0x00000100 16]

puts "\nResult Matrix C (Decimal - Endian Corrected):"
for {set r 0} {$r < 4} {incr r} {
    set row_vals {}
    for {set c 0} {$c < 4} {incr c} {
        set raw [lindex $results [expr {$r*4 + $c}]]
        # TCL reads Big-Endian from JTAG. We must swap the bytes.
        set b0 [expr {($raw >> 24) & 0xFF}]
        set b1 [expr {($raw >> 16) & 0xFF}]
        set b2 [expr {($raw >> 8)  & 0xFF}]
        set b3 [expr {$raw & 0xFF}]
        set val [expr {($b3 << 24) | ($b2 << 16) | ($b1 << 8) | $b0}]
        lappend row_vals [format "%8d" $val]
    }
    puts [join $row_vals " "]
}

close_service master $jtag_master
