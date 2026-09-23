/* cache_hog.c — 지정한 크기의 버퍼를 계속 훑어 LLC 를 점유한다.
 *
 * 목적: UDP 수신이 도는 코어와 LLC 를 공유하는 다른 코어에서 돌려, 실제로
 * 쓸 수 있는 캐시가 줄었을 때 수신 천장이 어떻게 되는지 본다. 커널의 예산은
 * 지금 LLC 전체를 기준으로 잡으므로, 이웃이 캐시를 먹는 상황에서는 과대평가가
 * 된다 - governor 가 CMT 로 그것을 보고 분수를 낮출 수 있어야 한다.
 *
 * 접근은 스트리밍이 아니라 랜덤이어야 한다. 순차 접근은 프리페처가 흡수해
 * 점유를 만들지 않는다.
 *
 * build: gcc -O2 -o cache_hog cache_hog.c
 * run  : taskset -c 3 ./cache_hog <MiB> <seconds>
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now_s(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec * 1e-9;
}

int main(int argc, char **argv)
{
	if (argc != 3) {
		fprintf(stderr, "usage: %s <MiB> <seconds>\n", argv[0]);
		return 2;
	}
	size_t mib = strtoul(argv[1], NULL, 10);
	double dur = atof(argv[2]);
	size_t sz = mib << 20;
	size_t lines = sz / 64;

	char *buf = aligned_alloc(4096, sz);
	if (!buf) { perror("alloc"); return 1; }
	memset(buf, 1, sz);

	/* 64B 라인을 의사난수 순서로 건드린다. 곱셈 해시면 분포가 충분하고
	 * 인덱스 계산이 접근 비용을 가리지 않을 만큼 싸다. */
	unsigned long long x = 0x9e3779b97f4a7c15ULL;
	volatile unsigned long long sink = 0;
	double t0 = now_s();
	unsigned long long n = 0;

	while (now_s() - t0 < dur) {
		for (int i = 0; i < 4096; i++) {
			x ^= x << 13; x ^= x >> 7; x ^= x << 17;
			sink += *(volatile char *)(buf + (x % lines) * 64);
			n++;
		}
	}
	double el = now_s() - t0;
	printf("hog: %zu MiB, %llu touches, %.1f Mtouch/s (sink=%llu)\n",
	       mib, n, n / el / 1e6, (unsigned long long)sink);
	free(buf);
	return 0;
}
