/* membw.c — 단일 코어 memcpy 대역폭 측정.
 *
 * 목적: UDP 수신 천장(48.5 G @ MTU9000)이 비용 모델에서 추정한
 *       per-byte 한계(~55 Gbps = 6.9 GB/s)와 맞는지 직접 확인한다.
 *
 * 버퍼 크기를 바꿔가며 재서 L3-resident / DRAM-resident 를 구분한다.
 * copy_to_user 는 src(=DMA된 skb, DDIO면 L3) -> dst(user buf) 이므로
 * 두 값 사이가 실제 상한이다.
 *
 * build: gcc -O2 -o membw membw.c
 * run  : taskset -c 1 ./membw
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static void bench(size_t sz)
{
	char *src = aligned_alloc(4096, sz);
	char *dst = aligned_alloc(4096, sz);
	if (!src || !dst) { perror("alloc"); exit(1); }
	memset(src, 0xa5, sz);
	memset(dst, 0x00, sz);

	/* 목표 총 전송량 4 GB → 크기에 관계없이 비슷한 측정 시간 */
	size_t iters = (4UL << 30) / sz;
	if (iters < 4) iters = 4;

	for (size_t i = 0; i < 4; i++)          /* warm */
		memcpy(dst, src, sz);

	double t0 = now();
	for (size_t i = 0; i < iters; i++)
		memcpy(dst, src, sz);
	double t = now() - t0;

	double bytes = (double)sz * iters;
	printf("  buf=%-7zu KiB  iters=%-8zu  %6.2f GB/s  = %6.1f Gbps\n",
	       sz >> 10, iters, bytes / t / 1e9, bytes * 8 / t / 1e9);
	free(src); free(dst);
}

int main(void)
{
	size_t sizes[] = { 32UL<<10, 256UL<<10, 1UL<<20, 4UL<<20, 16UL<<20,
			   64UL<<20, 256UL<<20 };
	printf("single-core memcpy bandwidth (src+dst 합이 L3=36MiB 를 넘으면 DRAM-bound)\n");
	for (unsigned i = 0; i < sizeof(sizes)/sizeof(sizes[0]); i++)
		bench(sizes[i]);
	return 0;
}
