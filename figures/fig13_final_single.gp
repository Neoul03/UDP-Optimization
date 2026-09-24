set terminal pngcairo size 1000,650 noenhanced font "Sans,11"
set output "/home/chanseo/lab/figures/fig13_final_single.png"
set title "Single flow: the levers only matter past the ceiling (6.18.53-udpopt9, N=5)" font "Sans,12"
set xlabel "Offered rate (Gbit/s)"
set ylabel "Goodput (Gbit/s)"
set grid
set key outside right top
set xtics (40,48,56)
set arrow from graph 0,first 54.34 to graph 1,first 54.34 nohead lc rgb "#cc0000" dt 2 lw 2
set label "TCP 54.34 (default tcp_rmem)" at graph 0.03,first 55.64 tc rgb "#cc0000" font "Sans,9"
set label "source: final_20260924_122049" at screen 0.01,0.02 font "Sans,8" tc rgb "#666666"
set bmargin 5
plot "/home/chanseo/lab/figures/fig13.dat" index 0 using 1:2:3 with yerrorlines lw 2 pt 5 ps 1.2 title "stock (208K, ring 1024)", "/home/chanseo/lab/figures/fig13.dat" index 1 using 1:2:3 with yerrorlines lw 2 pt 6 ps 1.2 title "rmem 1M (ring 1024)", "/home/chanseo/lab/figures/fig13.dat" index 2 using 1:2:3 with yerrorlines lw 2 pt 7 ps 1.2 title "rmem 1M + ring 128", "/home/chanseo/lab/figures/fig13.dat" index 3 using 1:2:3 with yerrorlines lw 2 pt 8 ps 1.2 title "rmem 1M + ring 128 + shed"
