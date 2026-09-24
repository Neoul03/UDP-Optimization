set terminal pdfcairo font "Helvetica,9" size 3.3in,2.0in
set output "/home/chanseo/lab/paper/figs/fig_moderation.pdf"
set style line 1 lc rgb '#1b4965' lw 2 pt 7 ps 0.5
set style line 2 lc rgb '#c1666b' lw 2 pt 5 ps 0.5
set style line 3 lc rgb '#4a7c59' lw 2 pt 9 ps 0.6
set style line 4 lc rgb '#8d8741' lw 2 pt 11 ps 0.6
set grid ls 0 lc rgb '#d0d0d0'
set border 3
set xtics nomirror
set ytics nomirror
set key top left reverse Left samplen 1.5

set xlabel "offered rate (Gbit/s)"
set ylabel "goodput (Gbit/s)"
set y2label "core busy (pct)"
set y2tics nomirror
set ytics nomirror
set yrange [25:55]
set y2range [40:105]
set key bottom left
plot "/home/chanseo/lab/paper/figs/fig_moderation.dat" u 1:2 w lp ls 1 t "goodput, moderation off", \
     "" u 1:4 w lp ls 2 t "goodput, moderation on", \
     "" u 1:3 axes x1y2 w l ls 1 dt 2 t "busy, off", \
     "" u 1:5 axes x1y2 w l ls 2 dt 2 t "busy, on"
