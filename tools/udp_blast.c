// udp_blast: high-rate single-flow UDP sender using GSO (UDP_SEGMENT), so the
// wire carries many fixed-size datagrams that the receiver's GRO can re-merge
// (frag_list) — exercising the batched RX enqueue + batched recvmsg drain.
//
// usage: udp_blast <dst_ip> <port> <dgram_size> <segs_per_send> <seconds>
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/udp.h>
#include <arpa/inet.h>

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(int argc, char **argv) {
    if (argc != 6 && argc != 7) {
        fprintf(stderr, "usage: %s <dst_ip> <port> <dgram_size> <segs_per_send> <seconds> [rate_gbps]\n"
                        "  rate_gbps: 0 or omitted = unlimited (blast).\n"
                        "  Pacing is per-send and proportional to bytes, so unlike a timer-tick\n"
                        "  pacer it introduces no quantisation jitter when the target rate is not\n"
                        "  an integer multiple of the datagram size.\n", argv[0]);
        return 2;
    }
    const char *ip = argv[1];
    int port = atoi(argv[2]);
    int dgram = atoi(argv[3]);
    int segs = atoi(argv[4]);
    double dur = atof(argv[5]);
    double rate_gbps = (argc == 7) ? atof(argv[6]) : 0.0;
    double bps = rate_gbps * 1e9 / 8.0;   /* target bytes per second */

    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) { perror("socket"); return 1; }

    int sndbuf = 16 * 1024 * 1024;
    setsockopt(s, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));

    struct sockaddr_in a = {0};
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    a.sin_addr.s_addr = inet_addr(ip);
    if (connect(s, (struct sockaddr *)&a, sizeof(a)) < 0) { perror("connect"); return 1; }

#ifdef UDP_SEGMENT
    if (segs > 1) {
        int gso = dgram;
        if (setsockopt(s, IPPROTO_UDP, UDP_SEGMENT, &gso, sizeof(gso)) < 0) {
            perror("setsockopt UDP_SEGMENT (no GSO, falling back)");
            segs = 1;
        }
    }
#else
    segs = 1;
#endif

    size_t sndlen = (size_t)dgram * (segs < 1 ? 1 : segs);
    char *buf = calloc(1, sndlen);
    unsigned long long sent = 0, bytes = 0;
    double t0 = now_s(), tend = t0 + dur;

    int reported = 0;
    while (now_s() < tend) {
        /* Pace on the byte budget rather than on a timer tick: the send is
         * released exactly when the wire would have drained everything sent
         * so far at the target rate.  A dedicated core is assumed, so the
         * wait is a spin - sleeping at these intervals is far too coarse.
         */
        if (bps > 0.0) {
            double due = t0 + (double)bytes / bps;
            while (now_s() < due)
                ;
        }
        ssize_t n = send(s, buf, sndlen, 0);
        if (n > 0) { sent++; bytes += n; }
        else if (!reported && errno != ENOBUFS && errno != EAGAIN) {
            fprintf(stderr, "[blast] send(%zu) failed: %s\n", sndlen, strerror(errno));
            reported = 1;
        }
    }
    double el = now_s() - t0;
    printf("sent_calls=%llu bytes=%llu elapsed=%.2fs offered=%.2f Gbit/s (dgram=%d segs=%d target=%.1f)\n",
           sent, bytes, el, bytes * 8.0 / el / 1e9, dgram, segs, rate_gbps);
    return 0;
}
