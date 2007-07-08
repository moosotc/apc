/* gcc -o hog hog.c */
#define _GNU_SOURCE
#include <err.h>
#include <time.h>
#include <stdio.h>
#include <sched.h>
#include <limits.h>
#include <stdlib.h>
#include <signal.h>
#include <sys/time.h>

#define HIST 10

static sig_atomic_t stop;

static void sighandler (int signr)
{
    (void) signr;
    stop = 1;
}

static unsigned long hog (unsigned long niters)
{
    stop = 0;
    while (!stop && --niters)
        ;
    return niters;
}

int main (void)
{
    unsigned int i;
    struct itimerval it;
    sigset_t set;
    unsigned long v[HIST];
    double tmp = 0.0;
    unsigned long n;

    it.it_interval.tv_sec = 0;
    it.it_interval.tv_usec = 1;
    it.it_value.tv_sec = 0;
    it.it_value.tv_usec = 1;

    if (signal (SIGALRM, &sighandler)) {
        err (EXIT_FAILURE, "failed to set signal handler");
    }

    if (setitimer (ITIMER_REAL, &it, NULL)) {
        err (EXIT_FAILURE, "failed to set interval timer");
    }

    for (i = 0; i < HIST; ++i) {
        v[i] = ULONG_MAX - hog (ULONG_MAX);
    }

    for (i = 0; i < HIST; ++i) {
        printf ("%d = %ld\n", i, v[i]);
        tmp += v[i];
    }
    tmp /= HIST;
    n = tmp - (tmp / 3);

    if (sigemptyset (&set)) {
        err (EXIT_FAILURE, "failed to empty sigset");
    }

    if (sigaddset (&set, SIGALRM)) {
        err (EXIT_FAILURE, "failed to add to sigset");
    }

    for (;;) {
        int signr;

        hog (n);
        if (sigwait (&set, &signr)) {
            err (EXIT_FAILURE, "failed to wait for a signal");
        }
    }

    return 0;
}
