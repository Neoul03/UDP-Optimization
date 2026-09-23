// udp_sink: UDP throughput receiver with selectable drain mode.
//   mode 0 = plain recvmsg (one datagram per call)
//   mode 1 = batched recvmsg (UDP_RECV_BATCH sockopt: one call drains many)
//   mode 2 = UDP_GRO (kernel keeps datagrams coalesced: one skb, one big copy)
// Counts bytes received over <seconds> and reports goodput.
//
// usage: udp_sink <bind_ip> <port> <mode 0|1> <seconds>
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

#ifndef UDP_RECV_BATCH
#define UDP_RECV_BATCH 105
#endif
#ifndef UDP_GRO
#define UDP_GRO 104
#endif

#define BUFSZ (1 << 20)   /* 1 MiB: kernel batch guard keeps ~64KiB slack */

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(int argc, char **argv) {
    if (argc != 5) {
        fprintf(stderr, "usage: %s <bind_ip> <port> <mode 0|1> <seconds>\n", argv[0]);
        return 2;
    }
    const char *ip = argv[1];
    int port = atoi(argv[2]);
    int mode = atoi(argv[3]);
    double dur = atof(argv[4]);

    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) { perror("socket"); return 1; }

    /* Asking for a buffer with SO_RCVBUF also sets SOCK_RCVBUF_LOCK, which
     * tells the kernel the application knows what it wants and disables any
     * autotuning for this socket.  Set UDP_SINK_NO_RCVBUF=1 to leave the
     * socket on rmem_default so autotuning (and the cache budget that bounds
     * it) can be exercised.
     */
    if (!getenv("UDP_SINK_NO_RCVBUF")) {
        const char *e = getenv("UDP_SINK_RCVBUF");
        int rcvbuf = e ? atoi(e) : 64 * 1024 * 1024;
        setsockopt(s, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
    }

    struct sockaddr_in a = {0};
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    a.sin_addr.s_addr = inet_addr(ip);
    if (bind(s, (struct sockaddr *)&a, sizeof(a)) < 0) { perror("bind"); return 1; }

    if (mode == 1) {
        int one = 1;
        if (setsockopt(s, IPPROTO_UDP, UDP_RECV_BATCH, &one, sizeof(one)) < 0) {
            perror("setsockopt UDP_RECV_BATCH");
            return 1;
        }
        fprintf(stderr, "[sink] batch mode (UDP_RECV_BATCH on)\n");
    } else if (mode == 2 || mode == 3 || mode == 4) {
        int one = 1;
        if (setsockopt(s, IPPROTO_UDP, UDP_GRO, &one, sizeof(one)) < 0) {
            perror("setsockopt UDP_GRO");
            return 1;
        }
        if (mode == 3)
            fprintf(stderr, "[sink] UDP_GRO + MSG_TRUNC (NO copyout: isolates copy cost)\n");
        else
            fprintf(stderr, "[sink] UDP_GRO mode (kernel coalesced, one skb/copy)\n");
    } else {
        fprintf(stderr, "[sink] plain recvmsg mode\n");
    }

    /* break out of recv if idle so we can honour the duration */
    struct timeval tv = { .tv_sec = 0, .tv_usec = 200000 };
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    char *buf = malloc(BUFSZ);
    unsigned long long bytes = 0, calls = 0, datagrams = 0;
    double t0 = 0, t1 = 0;
    int started = 0;
    /* plain mode reads up to 64KiB (one datagram); batch mode reads up to BUFSZ */
    size_t rlen = (mode == 1) ? BUFSZ : (1 << 16);
    (void)0;
    /* mode 3: MSG_TRUNC + tiny buffer => kernel returns true length but skips
     * the bulk copy_to_user (copyout). Isolates the cost of the data copy. */
    int rflags = (mode == 3) ? MSG_TRUNC : 0;
    if (mode == 3) rlen = 64;

    double deadline = now_s() + dur + 5; /* hard stop guard */
    if (mode == 4) {
        /* Amortised clock: read it once per CHECK successful recvs instead of
         * on every one.  The clock must still be read whenever recv times out,
         * or an idle socket would spin for CHECK/(1/SO_RCVTIMEO) seconds before
         * noticing the run is over.
         */
        const unsigned CHECK = 1024;
        unsigned since = 0;
        double t = now_s();
        for (;;) {
            ssize_t n = recv(s, buf, rlen, rflags);
            int tick = 0;
            if (n > 0) {
                bytes += n; calls++; datagrams++;
                if (!started) { t = now_s(); t0 = t; t1 = t; started = 1; }
                if (++since >= CHECK) { since = 0; tick = 1; }
            } else {
                if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK) { perror("recv"); break; }
                tick = 1;               /* timeout: always re-check the clock */
            }
            if (tick) {
                t = now_s();
                /* Only a successful recv advances t1.  Letting a timeout move it
                 * would fold the post-run idle into elapsed and under-report
                 * goodput by exactly the idle fraction.
                 */
                if (started && n > 0) t1 = t;
                if ((started && (t - t0) >= dur) || t > deadline) break;
            }
        }
        if (t1 <= t0) t1 = now_s();
    } else {
    for (;;) {
        ssize_t n = recv(s, buf, rlen, rflags);
        double t = now_s();
        if (n > 0) {
            if (!started) { t0 = t; started = 1; }
            t1 = t;
            bytes += n;
            calls++;
            datagrams += mode == 1 ? 0 : 1; /* batch: unknown split, count bytes only */
        }
        if (started && (t - t0) >= dur) break;
        if (t > deadline) break;
        if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK) { perror("recv"); break; }
    }
    }

    double el = (t1 > t0) ? (t1 - t0) : 1e-9;
    double gbps = bytes * 8.0 / el / 1e9;
    printf("mode=%d bytes=%llu calls=%llu elapsed=%.2fs goodput=%.2f Gbit/s avg_bytes_per_call=%.0f\n",
           mode, bytes, calls, el, gbps, calls ? (double)bytes / calls : 0);
    return 0;
}
