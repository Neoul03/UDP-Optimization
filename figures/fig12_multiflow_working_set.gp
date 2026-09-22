set terminal pngcairo size 1000,650 noenhanced font "Sans,11"
set output "/home/chanseo/lab/figures/fig12_multiflow_working_set.png"
set title "The cliff is set by the aggregate, not by how many sockets share it (48 Gbit/s offered)" font "Sans,12"
set xlabel "Total working set = ring descriptor pages + sum of all sk_rcvbuf (MiB)"
set ylabel "Total goodput (Gbit/s)"
set grid
set key outside right top
set logscale x 2
set xtics (2,4,8,16,32)
set arrow from 18,graph 0 to 18,graph 1 nohead lc rgb "#cc0000" dt 2 lw 2
set label "L3 = 18 MiB" at 18.5,graph 0.35 tc rgb "#cc0000" font "Sans,10"
set label "source: cachecnt_* and mfws_*" at screen 0.01,0.02 font "Sans,8" tc rgb "#666666"
set bmargin 5
plot "/home/chanseo/lab/figures/fig12.dat" index 0 using 1:2:3 with yerrorlines lw 2 pt 7 ps 1.3 title "1 socket (ring + one sk_rcvbuf)", "/home/chanseo/lab/figures/fig12.dat" index 1 using 1:2:3 with yerrorlines lw 2 pt 9 ps 1.3 title "8 sockets (ring + 8 x sk_rcvbuf)"
