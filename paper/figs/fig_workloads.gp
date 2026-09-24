set terminal pdfcairo font "Helvetica,9" size 3.3in,1.9in
set output "/home/chanseo/lab/paper/figs/fig_workloads.pdf"
set style line 1 lc rgb '#1b4965' lw 2 pt 7 ps 0.5
set style line 2 lc rgb '#c1666b' lw 2 pt 5 ps 0.5
set style line 3 lc rgb '#4a7c59' lw 2 pt 9 ps 0.6
set style line 4 lc rgb '#8d8741' lw 2 pt 11 ps 0.6
set grid ls 0 lc rgb '#d0d0d0'
set border 3
set xtics nomirror
set ytics nomirror
set key top left reverse Left samplen 1.5

set style data histogram
set style histogram cluster gap 1
set style fill solid 0.85 border -1
set boxwidth 0.9
set ylabel "goodput (Gbit/s)"
set yrange [0:60]
set xtics scale 0
set key top center horizontal
plot "/home/chanseo/lab/paper/figs/fig_workloads.dat" u 3:xtic(2) ls 1 t "W1: one socket, 56 Gb/s", \
     "" u 4 ls 2 t "W2: eight sockets, 7 Gb/s each"
