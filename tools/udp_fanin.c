// udp_fanin: many source flows into one destination socket, from one core.
//
// The case UDP has that TCP does not is many senders writing to a single
// receiving socket.  udp_blast cannot be used for it: it spins on the byte
// budget, so N senders need N cores, and sslab3 has 24.  Here one process
// holds N sockets on distinct source ports, all connected to the same
// destination, and sends round-robin against a single aggregate budget.
//
// Round-robin is the interesting case rather than an unfair one: perfectly
// interleaved flows are the worst case for GRO, which holds at most
// GRO_HASH_BUCKETS(8) x MAX_GRO_SKBS(8) flows before it has to flush early.
//
// usage: udp_fanin <dst_ip> <dst_port> <dgram> <segs> <seconds> <rate_gbps> <nflows>
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/udp.h>

#ifndef UDP_SEGMENT
#define UDP_SEGMENT 103
#endif

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(int argc, char **argv) {
    if (argc < 8) {
        fprintf(stderr, "usage: %s <dst_ip> <dst_port> <dgram> <segs> <seconds>"
                        " <rate_gbps> <nflows>\n", argv[0]);
        return 2;
    }
    const char *ip = argv[1];
    int port = atoi(argv[2]);
    int dgram = atoi(argv[3]);
    int segs = atoi(argv[4]);
    double dur = atof(argv[5]);
    double rate_gbps = atof(argv[6]);
    int nflows = atoi(argv[7]);
    if (nflows < 1) nflows = 1;

    struct sockaddr_in dst;
    memset(&dst, 0, sizeof(dst));
    dst.sin_family = AF_INET;
    dst.sin_port = htons(port);
    if (inet_pton(AF_INET, ip, &dst.sin_addr) != 1) { perror("inet_pton"); return 1; }

    int *fds = calloc(nflows, sizeof(int));
    for (int i = 0; i < nflows; i++) {
        int s = socket(AF_INET, SOCK_DGRAM, 0);
        if (s < 0) { perror("socket"); return 1; }
        /* Ephemeral source ports are enough to make the flows distinct: the
         * receive side hashes the whole 4-tuple, so each gets its own GRO
         * bucket and, on a multi-queue NIC, its own receive queue. */
        if (connect(s, (struct sockaddr *)&dst, sizeof(dst)) < 0) { perror("connect"); return 1; }
        int sndbuf = 8 << 20;
        setsockopt(s, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));
        if (segs > 1) {
            int gso = dgram;
            if (setsockopt(s, IPPROTO_UDP, UDP_SEGMENT, &gso, sizeof(gso)) < 0) {
                perror("UDP_SEGMENT");
                return 1;
            }
        }
        fds[i] = s;
    }

    size_t sndlen = (size_t)dgram * (segs < 1 ? 1 : segs);
    char *buf = calloc(1, sndlen);
    double bps = rate_gbps > 0.0 ? rate_gbps * 1e9 / 8.0 : 0.0;
    unsigned long long sent = 0, bytes = 0;
    double t0 = now_s(), tend = t0 + dur;
    int i = 0, reported = 0;

    while (now_s() < tend) {
        /* One budget for the aggregate, same spin-pacing as udp_blast: the
         * send is released when the wire would have drained everything sent
         * so far at the target rate. */
        if (bps > 0.0) {
            double due = t0 + (double)bytes / bps;
            while (now_s() < due)
                ;
        }
        ssize_t n = send(fds[i], buf, sndlen, 0);
        if (n > 0) { sent++; bytes += n; }
        else if (!reported && errno != ENOBUFS && errno != EAGAIN) {
            fprintf(stderr, "[fanin] send(%zu) failed: %s\n", sndlen, strerror(errno));
            reported = 1;
        }
        if (++i == nflows) i = 0;
    }
    double el = now_s() - t0;
    printf("flows=%d sent_calls=%llu bytes=%llu elapsed=%.2fs offered=%.2f Gbit/s"
           " (dgram=%d segs=%d target=%.1f)\n",
           nflows, sent, bytes, el, bytes * 8.0 / el / 1e9, dgram, segs, rate_gbps);
    return 0;
}
