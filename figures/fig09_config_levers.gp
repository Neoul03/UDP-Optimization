set terminal pngcairo size 1000,650 noenhanced font "Sans,11"
set output "/home/chanseo/lab/figures/fig09_config_levers.png"
set title "Shrinking the mlx5 head copy and dropping the usercopy check, with and without shed" font "Sans,13"
set xlabel "Offered rate (Gbit/s)"
set ylabel "Goodput (Gbit/s)"
set grid
set key outside right top
set label "source: cfglever_20260922_201615" at screen 0.01,0.02 font "Sans,8" tc rgb "#666666"
set bmargin 5



plot "/home/chanseo/lab/figures/fig09.dat" index 0 using 1:2:3 with yerrorlines lw 2 pt 5 ps 1.2 title "udpopt4 (shed off)", "/home/chanseo/lab/figures/fig09.dat" index 1 using 1:2:3 with yerrorlines lw 2 pt 6 ps 1.2 title "udpopt4 (shed on)", "/home/chanseo/lab/figures/fig09.dat" index 2 using 1:2:3 with yerrorlines lw 2 pt 7 ps 1.2 title "udpopt3 (shed off)", "/home/chanseo/lab/figures/fig09.dat" index 3 using 1:2:3 with yerrorlines lw 2 pt 8 ps 1.2 title "udpopt3 (shed on)"
