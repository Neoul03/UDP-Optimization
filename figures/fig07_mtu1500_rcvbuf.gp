set terminal pngcairo size 1000,650 noenhanced font "Sans,11"
set output "/home/chanseo/lab/figures/fig07_mtu1500_rcvbuf.png"
set title "MTU 1500: the buffer curve is flat above 512KB (no inverted-U)" font "Sans,13"
set xlabel "sk_rcvbuf (KiB)"
set ylabel "Goodput (Gbit/s)"
set grid
set key outside right top
set label "source: mtu1500_tune_20260922_104154" at screen 0.01,0.02 font "Sans,8" tc rgb "#666666"
set bmargin 5
set logscale x 2


plot "/home/chanseo/lab/figures/fig07.dat" index 0 using 1:2:3 with yerrorlines lw 2 pt 5 ps 1.2 title "offered 28 Gbit/s", "/home/chanseo/lab/figures/fig07.dat" index 1 using 1:2:3 with yerrorlines lw 2 pt 6 ps 1.2 title "offered 32 Gbit/s"
