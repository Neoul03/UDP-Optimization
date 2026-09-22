set terminal pngcairo size 1000,650 noenhanced font "Sans,11"
set output "/home/chanseo/lab/figures/fig03_rate_ladder_by_ring.png"
set title "Offered rate vs goodput, by RX ring size (iperf3; TCP shown for reference)" font "Sans,13"
set xlabel "Offered rate (Gbit/s)"
set ylabel "Goodput (Gbit/s)"
set grid
set key outside right top
set label "source: ladder_ring*" at screen 0.01,0.02 font "Sans,8" tc rgb "#666666"
set bmargin 5


set arrow from graph 0,first 51.4 to graph 1,first 51.4 nohead lc rgb "#cc0000" dt 2 lw 2
set label "TCP 51.4 (default tcp\_rmem)" at graph 0.02,first 52.6 tc rgb "#cc0000" font "Sans,9"
plot "/home/chanseo/lab/figures/fig03.dat" index 0 using 1:2:3 with yerrorlines lw 2 pt 5 ps 1.2 title "RX ring 1024", "/home/chanseo/lab/figures/fig03.dat" index 1 using 1:2:3 with yerrorlines lw 2 pt 6 ps 1.2 title "RX ring 128"
