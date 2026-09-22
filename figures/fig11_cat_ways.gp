set terminal pngcairo size 1000,650 noenhanced font "Sans,11"
set output "/home/chanseo/lab/figures/fig11_cat_ways.png"
set title "Shrinking the LLC with Intel CAT moves the cliff down with it (offered 44 Gbit/s)" font "Sans,13"
set xlabel "Working set = ring descriptor pages + sk_rcvbuf (MiB)"
set ylabel "Goodput (Gbit/s)"
set grid
set key outside right top
set label "source: cat_{12,6,3}way_*" at screen 0.01,0.02 font "Sans,8" tc rgb "#666666"
set bmargin 5
set logscale x 2

set xtics (2,4,8,16)
plot "/home/chanseo/lab/figures/fig11.dat" index 0 using 1:2:3 with yerrorlines lw 2 pt 5 ps 1.2 title "L3 = 18 MiB (12 ways)", "/home/chanseo/lab/figures/fig11.dat" index 1 using 1:2:3 with yerrorlines lw 2 pt 6 ps 1.2 title "L3 = 9 MiB (6 ways)", "/home/chanseo/lab/figures/fig11.dat" index 2 using 1:2:3 with yerrorlines lw 2 pt 7 ps 1.2 title "L3 = 4.5 MiB (3 ways)"
