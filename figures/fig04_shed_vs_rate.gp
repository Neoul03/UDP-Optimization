set terminal pngcairo size 1000,650 noenhanced font "Sans,11"
set output "/home/chanseo/lab/figures/fig04_shed_vs_rate.png"
set title "Driver-level shed turns post-ceiling collapse into a plateau (udp_blast to udp_sink)" font "Sans,13"
set xlabel "Offered rate (Gbit/s)"
set ylabel "Goodput (Gbit/s)"
set grid
set key outside right top
set label "source: shedclean_20260922_1451/1457" at screen 0.01,0.02 font "Sans,8" tc rgb "#666666"
set bmargin 5


set arrow from 48,graph 0 to 48,graph 1 nohead lc rgb "#888888" dt 3
set label "CPU ceiling (48G)" at 48.4,graph 0.06 tc rgb "#888888" font "Sans,9"
plot "/home/chanseo/lab/figures/fig04.dat" index 0 using 1:2:3 with yerrorlines lw 2 pt 5 ps 1.2 title "shed off", "/home/chanseo/lab/figures/fig04.dat" index 1 using 1:2:3 with yerrorlines lw 2 pt 6 ps 1.2 title "shed on"
