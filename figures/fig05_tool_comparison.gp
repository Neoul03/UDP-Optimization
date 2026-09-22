set terminal pngcairo size 1000,650 noenhanced font "Sans,11"
set output "/home/chanseo/lab/figures/fig05_tool_comparison.png"
set title "Same receiver, two load generators: iperf3 pacing fabricates loss below the ceiling" font "Sans,13"
set xlabel "Offered rate (Gbit/s)"
set ylabel "Goodput (Gbit/s)"
set grid
set key outside right top
set label "source: ladder_ring128smooth_*, tools_*" at screen 0.01,0.02 font "Sans,8" tc rgb "#666666"
set bmargin 5



plot "/home/chanseo/lab/figures/fig05.dat" index 0 using 1:2:3 with yerrorlines lw 2 pt 5 ps 1.2 title "iperf3 (-b, tick pacing)", "/home/chanseo/lab/figures/fig05.dat" index 1 using 1:2:3 with yerrorlines lw 2 pt 6 ps 1.2 title "udp_blast (byte-budget) to udp_sink"
