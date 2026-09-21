// af_xdp_sink: AF_XDP zero-copy UDP receiver. NIC DMAs frames straight into a
// userspace umem; we read packet descriptors (addr,len) WITHOUT copying the
// payload to a separate buffer -> isolates "no copyout" vs socket recvmsg.
//
// usage: af_xdp_sink <ifname> <queue> <seconds> [zc 0|1]
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <poll.h>
#include <time.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <net/if.h>
#include <linux/if_link.h>
#include <linux/if_xdp.h>
#include <bpf/xsk.h>
#include <bpf/libbpf.h>

#define FRAME_SIZE 16384            /* holds a 9000B jumbo frame */
#define NUM_FRAMES 4096
#define FILL_SZ    2048
#define RX_SZ      2048
#define BATCH      256

static double now_s(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec + t.tv_nsec/1e9; }

int main(int argc, char **argv){
    if (argc < 4){ fprintf(stderr,"usage: %s <ifname> <queue> <seconds> [zc 0|1]\n",argv[0]); return 2; }
    const char *ifname = argv[1];
    int queue = atoi(argv[2]);
    double dur = atof(argv[3]);
    int zc = (argc>4)? atoi(argv[4]) : 1;

    struct rlimit r = { RLIM_INFINITY, RLIM_INFINITY };
    setrlimit(RLIMIT_MEMLOCK, &r);

    void *buf = NULL;
    size_t umem_sz = (size_t)NUM_FRAMES * FRAME_SIZE;
    if (posix_memalign(&buf, getpagesize(), umem_sz)){ perror("memalign"); return 1; }

    struct xsk_umem *umem;
    struct xsk_ring_prod fq; struct xsk_ring_cons cq;
    struct xsk_umem_config ucfg = {
        .fill_size = FILL_SZ, .comp_size = RX_SZ,
        .frame_size = FRAME_SIZE, .frame_headroom = 0,
        .flags = XDP_UMEM_UNALIGNED_CHUNK_FLAG,
    };
    if (xsk_umem__create(&umem, buf, umem_sz, &fq, &cq, &ucfg)){ perror("umem__create"); return 1; }

    struct xsk_socket *xsk;
    struct xsk_ring_cons rx; struct xsk_ring_prod tx;
    struct xsk_socket_config scfg = {
        .rx_size = RX_SZ, .tx_size = RX_SZ,
        .libbpf_flags = 0,
        .xdp_flags = XDP_FLAGS_DRV_MODE,
        .bind_flags = (zc ? XDP_ZEROCOPY : XDP_COPY) | XDP_USE_NEED_WAKEUP,
    };
    int err = xsk_socket__create(&xsk, ifname, queue, umem, &rx, &tx, &scfg);
    if (err){ fprintf(stderr,"socket__create(%s q%d zc=%d) failed: %s\n",ifname,queue,zc,strerror(-err)); return 1; }
    fprintf(stderr,"[afxdp] %s queue %d, %s\n", ifname, queue, zc?"ZEROCOPY":"COPY");

    /* prime the fill ring with all frames */
    __u32 idx;
    int n = xsk_ring_prod__reserve(&fq, FILL_SZ, &idx);
    for (int i=0;i<n;i++) *xsk_ring_prod__fill_addr(&fq, idx+i) = (__u64)i * FRAME_SIZE;
    xsk_ring_prod__submit(&fq, n);

    int fd = xsk_socket__fd(xsk);
    struct pollfd pfd = { .fd = fd, .events = POLLIN };
    unsigned long long bytes=0, pkts=0;
    double t0=0,t1=0; int started=0;
    double deadline = now_s() + dur + 5;

    for(;;){
        if (xsk_ring_prod__needs_wakeup(&fq)) recvfrom(fd, NULL,0, MSG_DONTWAIT, NULL,NULL);
        int p = poll(&pfd, 1, 200);
        (void)p;
        __u32 ridx;
        unsigned rcvd = xsk_ring_cons__peek(&rx, BATCH, &ridx);
        if (rcvd){
            double t = now_s(); if(!started){t0=t;started=1;} t1=t;
            /* reserve fill slots to recycle the frames we are about to consume */
            __u32 fidx; int rs = xsk_ring_prod__reserve(&fq, rcvd, &fidx);
            for (unsigned i=0;i<rcvd;i++){
                const struct xdp_desc *d = xsk_ring_cons__rx_desc(&rx, ridx+i);
                bytes += d->len; pkts++;
                /* NO copy of d payload (buf + d->addr) — that is the point */
                if (i < (unsigned)rs) *xsk_ring_prod__fill_addr(&fq, fidx+i) = d->addr & ~(FRAME_SIZE-1);
            }
            xsk_ring_prod__submit(&fq, rs);
            xsk_ring_cons__release(&rx, rcvd);
        }
        double t = now_s();
        if (started && (t - t0) >= dur) break;
        if (t > deadline) break;
    }
    double el = (t1>t0)?(t1-t0):1e-9;
    printf("afxdp zc=%d bytes=%llu pkts=%llu elapsed=%.2fs goodput=%.2f Gbit/s\n",
           zc, bytes, pkts, el, bytes*8.0/el/1e9);
    xsk_socket__delete(xsk);
    xsk_umem__delete(umem);
    return 0;
}
