#define _GNU_SOURCE
#include <err.h>
#include <time.h>
#include <stdio.h>
#include <fcntl.h>
#include <alloca.h>
#include <unistd.h>
#include <stdlib.h>
#include <sys/time.h>
#include <sys/sysinfo.h>

static double now (void)
{
    struct timeval tv;

    if (gettimeofday (&tv, NULL))
        err (1, "gettimeofday");
    return tv.tv_sec + tv.tv_usec * 1e-6;
}

static void idlenow (int fd, int nprocs, double *p)
{
    struct timeval tv;
    size_t n = nprocs * sizeof (tv);
    ssize_t m;
    struct timeval *buf;
    int i;

    buf = alloca (n);
    if (!buf) errx (1, "alloca failed");

    m = read (fd, buf, n);
    if (n - m) err (1, "read [n=%zu, m=%zi]", n, m);

    for (i = 0; i < nprocs; ++i)
        p[i] = buf[i].tv_sec + buf[i].tv_usec * 1e-6;
}

int main (int argc, char **argv)
{
    int fd;
    int nprocs;
    double *idle;
    double *curr, *prev;

    (void) argc;
    (void) argv;

    nprocs = get_nprocs ();
    if (nprocs <= 0) errx (1, "get_nprocs returned %d", nprocs);

    idle = malloc (2 * nprocs * sizeof (idle[0]));
    if (!idle) errx (1, "malloc %zu failed", 2 * nprocs * sizeof (idle[0]));

    fd = open ("/dev/itc", O_RDONLY);
    if (fd < 0) err (1, "open /dev/itc");

    idlenow (fd, nprocs, idle);

    curr = &idle[nprocs];
    prev = idle;
    setbuf (stdout, NULL);

    for (;;) {
        int i;
        double s, e, d, *t, a = 0.0, ai = 0.0;

        idlenow (fd, nprocs, prev);
        s = now ();
        sleep (1);
        idlenow (fd, nprocs, curr);
        e = now ();
        d = e - s;

        for (i = 0; i < nprocs; ++i) {
            double di = curr[i] - prev[i];

            /* printf ("\rcpu%d - %.2f", i, 100.0 * (1.0 - di / d)); */
            /* printf ("cpu%d - %6.2f\n", i, 100.0 * (1.0 - di / d)); */
            a += d;
            ai += di;
            printf ("%6.2f", 100.0 * (1.0 - di / d));
            if (i < nprocs) fputc (' ', stdout);
        }
        if (i > 0) {
            printf ("%6.2f\n", 100.0 * (1.0 - ai / a));
        }
        else {
            fputc ('\n', stdout);
        }

        t = curr;
        curr = prev;
        prev = t;
    }
}
