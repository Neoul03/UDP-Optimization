set terminal pngcairo size 1000,650 noenhanced font "Sans,11"
set output "/home/chanseo/lab/figures/fig08_shed_window.png"
set title "Shed window vs goodput, by offered rate (leftmost point = shed off)" font "Sans,13"
set xlabel "Shed window (us)"
set ylabel "Goodput (Gbit/s)"
set grid
set key outside right top
set label "source: shedwin_20260922_183649" at screen 0.01,0.02 font "Sans,8" tc rgb "#666666"
set bmargin 5
set logscale x 2

set xtics ("off" 12, "25" 25, "50" 50, "100" 100, "200" 200, "400" 400, "800" 800, "1600" 1600)
plot "/home/chanseo/lab/figures/fig08.dat" index 0 using 1:2:3 with yerrorlines lw 2 pt 5 ps 1.2 title "offered 52 Gbit/s", "/home/chanseo/lab/figures/fig08.dat" index 1 using 1:2:3 with yerrorlines lw 2 pt 6 ps 1.2 title "offered 60 Gbit/s", "/home/chanseo/lab/figures/fig08.dat" index 2 using 1:2:3 with yerrorlines lw 2 pt 7 ps 1.2 title "offered 72 Gbit/s"
