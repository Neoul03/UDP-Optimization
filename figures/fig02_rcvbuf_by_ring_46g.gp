set terminal pngcairo size 1000,650 noenhanced font "Sans,11"
set output "/home/chanseo/lab/figures/fig02_rcvbuf_by_ring_46g.png"
set title "Receive buffer vs goodput at 46 Gbit/s offered, by RX ring size (iperf3)" font "Sans,13"
set xlabel "sk_rcvbuf (KiB)"
set ylabel "Goodput (Gbit/s)"
set grid
set key outside right top
set label "source: cnt_ring{128,256,1024}_*" at screen 0.01,0.02 font "Sans,8" tc rgb "#666666"
set bmargin 5
set logscale x 2


plot "/home/chanseo/lab/figures/fig02.dat" index 0 using 1:2:3 with yerrorlines lw 2 pt 5 ps 1.2 title "RX ring 256", "/home/chanseo/lab/figures/fig02.dat" index 1 using 1:2:3 with yerrorlines lw 2 pt 6 ps 1.2 title "RX ring 1024"
