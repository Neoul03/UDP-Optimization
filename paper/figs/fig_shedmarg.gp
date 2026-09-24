set terminal pdfcairo font "Helvetica,9" size 3.3in,2.0in
set output "/home/chanseo/lab/paper/figs/fig_shedmarg.pdf"
set style line 1 lc rgb '#1b4965' lw 2 pt 7 ps 0.5
set style line 2 lc rgb '#c1666b' lw 2 pt 5 ps 0.5
set grid ls 0 lc rgb '#d0d0d0'
set border 3
set xtics nomirror
set ytics nomirror
set xlabel "offered rate (Gbit/s)"
set ylabel "goodput (Gbit/s)"
set key bottom left reverse Left samplen 1.5
plot "/home/chanseo/lab/paper/figs/fig_shedmarg.dat" u 1:2 w lp ls 1 t "Ripple", \
     "" u 1:3 w lp ls 2 t "Ripple + shed", \
     "" u 1:4 w lp ls 1 dt 2 t "Ripple, mod. off", \
     "" u 1:5 w lp ls 2 dt 2 t "Ripple + shed, mod. off"
