set terminal pngcairo size 1000,650 noenhanced font "Sans,11"
set output "/home/chanseo/lab/figures/fig06_cache_sharing.png"
set title "The buffer penalty scales with the cache the producer and consumer share (blast)" font "Sans,13"
set xlabel "sk_rcvbuf (KiB)"
set ylabel "Goodput (Gbit/s)"
set grid
set key outside right top
set label "source: l2hyp_20260922_110420" at screen 0.01,0.02 font "Sans,8" tc rgb "#666666"
set bmargin 5
set logscale x 2


plot "/home/chanseo/lab/figures/fig06.dat" index 0 using 1:2:3 with yerrorlines lw 2 pt 5 ps 1.2 title "same core (shares L2 + L3)", "/home/chanseo/lab/figures/fig06.dat" index 1 using 1:2:3 with yerrorlines lw 2 pt 6 ps 1.2 title "same socket (shares L3 only)", "/home/chanseo/lab/figures/fig06.dat" index 2 using 1:2:3 with yerrorlines lw 2 pt 7 ps 1.2 title "cross socket (shares nothing)"
