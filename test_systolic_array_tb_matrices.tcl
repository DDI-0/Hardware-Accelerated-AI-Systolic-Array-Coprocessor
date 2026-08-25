# System Console fifo fix JTAG Test Script for Systolic Array (Testbench Matrices)
set jtag_master [lindex [get_service_paths master] 0]
open_service master $jtag_master

puts "Phase 1: Safe Soft Reset"
master_write_32 $jtag_master 0x00001000 0x00000002
after 10

puts "Phase 2: Writing Input Matrices to RAM"
# Matrix A (Big Endian packing to counter System Console byte-swapping)
master_write_32 $jtag_master 0x00000000 0x01020304
master_write_32 $jtag_master 0x00000004 0x05060708
master_write_32 $jtag_master 0x00000008 0x090A0B0C
master_write_32 $jtag_master 0x0000000C 0x0D0E0F10

# Matrix B
master_write_32 $jtag_master 0x00000010 0x11121314
master_write_32 $jtag_master 0x00000014 0x15161718
master_write_32 $jtag_master 0x00000018 0x191A1B1C
master_write_32 $jtag_master 0x0000001C 0x1D1E1F20
puts "Matrices written."

puts "Phase 3 & 4: Configuring DMAs"
master_write_32 $jtag_master 0x00001084 0x00000100
master_write_32 $jtag_master 0x00001088 64
master_write_32 $jtag_master 0x0000108C 0x80000000

master_write_32 $jtag_master 0x00001090 0x00000000
master_write_32 $jtag_master 0x00001098 32
master_write_32 $jtag_master 0x0000109C 0x80000000
puts "DMAs armed."
 
puts "Phase 5: Starting Systolic Array"
master_write_32 $jtag_master 0x00001000 0x00000001
after 100 

puts "Phase 6: Reading Results"
set results [master_read_32 $jtag_master 0x00000100 16]

puts "\nResult Matrix C:"
for {set r 0} {$r < 4} {incr r} {
    set r0 [lindex $results [expr {$r*4 + 0}]]
    set r1 [lindex $results [expr {$r*4 + 1}]]
    set r2 [lindex $results [expr {$r*4 + 2}]]
    set r3 [lindex $results [expr {$r*4 + 3}]]
    puts [format "%8d %8d %8d %8d" $r0 $r1 $r2 $r3]
}

close_service master $jtag_master
