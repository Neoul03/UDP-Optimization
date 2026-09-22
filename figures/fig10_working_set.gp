set terminal pngcairo size 1000,650 noenhanced font "Sans,11"
set output "/home/chanseo/lab/figures/fig10_working_set.png"
set title "Working set, not the individual knob, predicts the cliff (offered 44 Gbit/s)" font "Sans,13"
set xlabel "Working set = Rx ring descriptor pages + sk_rcvbuf (MiB)"
set ylabel "Goodput (Gbit/s)"
set y2label "L3 load-miss (%)"
set ytics nomirror
set y2tics
set grid
set key outside right top
set logscale x 2
set xtics (2,4,8,16,32)
set arrow from 18,graph 0 to 18,graph 1 nohead lc rgb "#cc0000" dt 2 lw 2
set label "L3 = 18 MiB" at 18.4,graph 0.30 tc rgb "#cc0000" font "Sans,10"
set label "source: cachecnt_* (ring 128 and 1024 pooled)" at screen 0.01,0.02 font "Sans,8" tc rgb "#666666"
set bmargin 5
plot "/home/chanseo/lab/figures/fig10.dat" index 0 using 1:2:3 with yerrorlines lw 2 pt 7 ps 1.3 axes x1y1 title "goodput",      "/home/chanseo/lab/figures/fig10b.dat" index 0 using 1:2:3 with yerrorlines lw 2 pt 5 ps 1.2 axes x1y2 title "L3 load-miss"
