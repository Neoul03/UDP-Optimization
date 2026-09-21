// set_netdev_maxsize: set netdev u32 link attributes via RTNETLINK, for kernels
// newer than the local iproute2. Used to raise BIG-TCP/UDP GSO/GRO size caps.
//   IFLA_GSO_MAX_SIZE=41  IFLA_GRO_MAX_SIZE=58
//   IFLA_GSO_IPV4_MAX_SIZE=63  IFLA_GRO_IPV4_MAX_SIZE=64
//
// usage (run as root): set_netdev_maxsize <ifname> <attr_type> <value> [<attr_type> <value>...]
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/socket.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <net/if.h>

static void add_attr_u32(struct nlmsghdr *nh, int type, unsigned int val) {
    struct rtattr *rta = (struct rtattr *)((char *)nh + NLMSG_ALIGN(nh->nlmsg_len));
    rta->rta_type = type;
    rta->rta_len = RTA_LENGTH(sizeof(val));
    memcpy(RTA_DATA(rta), &val, sizeof(val));
    nh->nlmsg_len = NLMSG_ALIGN(nh->nlmsg_len) + RTA_ALIGN(RTA_LENGTH(sizeof(val)));
}

int main(int argc, char **argv) {
    if (argc < 4 || (argc % 2) != 0) {
        fprintf(stderr, "usage: %s <ifname> <attr_type> <value> [...]\n", argv[0]);
        return 2;
    }
    unsigned int idx = if_nametoindex(argv[1]);
    if (!idx) { perror("if_nametoindex"); return 1; }

    struct {
        struct nlmsghdr nh;
        struct ifinfomsg ifi;
        char buf[1024];
    } req;
    memset(&req, 0, sizeof(req));
    req.nh.nlmsg_len = NLMSG_LENGTH(sizeof(struct ifinfomsg));
    req.nh.nlmsg_type = RTM_NEWLINK;
    req.nh.nlmsg_flags = NLM_F_REQUEST | NLM_F_ACK;
    req.nh.nlmsg_seq = 1;
    req.ifi.ifi_family = AF_UNSPEC;
    req.ifi.ifi_index = idx;

    for (int i = 2; i + 1 < argc; i += 2)
        add_attr_u32(&req.nh, atoi(argv[i]), strtoul(argv[i + 1], NULL, 10));

    int s = socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE);
    if (s < 0) { perror("socket"); return 1; }
    if (send(s, &req, req.nh.nlmsg_len, 0) < 0) { perror("send"); return 1; }

    char resp[4096];
    int n = recv(s, resp, sizeof(resp), 0);
    if (n < 0) { perror("recv"); return 1; }
    struct nlmsghdr *rh = (struct nlmsghdr *)resp;
    if (rh->nlmsg_type == NLMSG_ERROR) {
        struct nlmsgerr *e = (struct nlmsgerr *)NLMSG_DATA(rh);
        if (e->error) { fprintf(stderr, "netlink error: %s\n", strerror(-e->error)); return 1; }
    }
    printf("OK\n");
    return 0;
}
