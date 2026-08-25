set jtag_master [lindex [get_service_paths master] 0]
open_service master $jtag_master

puts "Reading RAM at 0x0000..."
set ram_data [master_read_32 $jtag_master 0x00000000 8]
puts $ram_data

close_service master $jtag_master
