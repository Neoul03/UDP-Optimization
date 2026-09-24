set terminal pdfcairo font "Helvetica,9" size 3.3in,2.0in
set output "/home/chanseo/lab/paper/figs/fig_workingset.pdf"
set style line 1 lc rgb '#1b4965' lw 2 pt 7 ps 0.5
set style line 2 lc rgb '#c1666b' lw 2 pt 5 ps 0.5
set style line 3 lc rgb '#4a7c59' lw 2 pt 9 ps 0.6
set style line 4 lc rgb '#8d8741' lw 2 pt 11 ps 0.6
set grid ls 0 lc rgb '#d0d0d0'
set border 3
set xtics nomirror
set ytics nomirror
set key top left reverse Left samplen 1.5

set xlabel "working set: ring pages + {/Symbol S} sk_rcvbuf (MiB)"
set ylabel "goodput (Gbit/s)"
set logscale x 2
set key bottom left
plot "/home/chanseo/lab/paper/figs/fig_workingset.dat" u 1:2 w lp ls 1 t "L3 = 18 MiB", \
     "" u 1:4 w lp ls 2 t "L3 = 9 MiB (CAT)", \
     "" u 1:6 w lp ls 4 t "L3 = 4.5 MiB (CAT)"
