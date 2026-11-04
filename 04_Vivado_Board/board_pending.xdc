# Confirmed by user: TOP_RCN.xdc is from a working FACE-VUP-PRO board project.
set_property PACKAGE_PIN AE31 [get_ports sysclk200_p]
set_property PACKAGE_PIN AE32 [get_ports sysclk200_n]
set_property IOSTANDARD DIFF_SSTL12 [get_ports {sysclk200_p sysclk200_n}]
create_clock -name sysclk200 -period 5.000 [get_ports sysclk200_p]
