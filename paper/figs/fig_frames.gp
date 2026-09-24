set terminal pdfcairo font "Helvetica,9" size 3.3in,2.0in
set output "/home/chanseo/lab/paper/figs/fig_frames.pdf"
set style line 1 lc rgb '#1b4965' lw 2 pt 7 ps 0.5
set style line 2 lc rgb '#c1666b' lw 2 pt 5 ps 0.5
set style line 3 lc rgb '#4a7c59' lw 2 pt 9 ps 0.6
set style line 4 lc rgb '#8d8741' lw 2 pt 11 ps 0.6
set grid ls 0 lc rgb '#d0d0d0'
set border 3
set xtics nomirror
set ytics nomirror
set key top left reverse Left samplen 1.5

set xlabel "NIC moderation frame count (rx-frames)"
set ylabel "goodput (Gbit/s)"
set logscale x 2
set xrange [14:300]
set yrange [0:55]
set arrow from 128,0 to 128,55 nohead lc rgb '#999999' dt 2
set label "driver settles here" at 128,52 right offset -0.5,0 tc rgb '#555555' font ",8"
plot "/home/chanseo/lab/paper/figs/fig_frames.dat" u 1:2 w lp ls 2 t "fixed 1 MB", \
     "" u 1:3 w lp ls 4 t "fixed 8 MB", \
     "" u 1:4 w lp ls 1 t "Ripple"
