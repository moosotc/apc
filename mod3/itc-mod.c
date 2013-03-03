#include <linux/signal.h>
#include <linux/sched.h>
#include <linux/interrupt.h>

#include <linux/fs.h>
#include <linux/version.h>
#include <linux/vmalloc.h>
#include <linux/module.h>
#include <linux/delay.h>
#include <linux/init.h>
#include <linux/slab.h>
#include <linux/smp.h>
#include <linux/mm.h>
#include <linux/pm.h>
#include <linux/miscdevice.h>
#include <linux/kernel_stat.h>
#include <linux/cpuidle.h>

#include <asm/uaccess.h>
#include <asm/idle.h>

#if defined CONFIG_6xx || defined CONFIG_PPC64
#define ACCOUNT_IRQ
#endif

MODULE_DESCRIPTION ("Idle time collector");
MODULE_LICENSE ("GPL");

#define DEVNAME "itc"

#if LINUX_VERSION_CODE < KERNEL_VERSION (3, 0, 0)
static spinlock_t lock = SPIN_LOCK_UNLOCKED;
#else
DEFINE_SPINLOCK (lock);
#endif

static unsigned int itc_major;
static atomic_t in_use;

struct itc
{
  struct timeval cumm_sleep_time;
  struct timeval sleep_started;
  int sleeping;
};

static struct itc global_itc[NR_CPUS];

/**********************************************************************
 *
 * Utility functions
 *
 **********************************************************************/
static void
cpeamb (struct timeval *c, struct timeval *a, struct timeval *b)
{
  __typeof (c->tv_sec) sec = a->tv_sec - b->tv_sec;
  __typeof (c->tv_usec) usec = a->tv_usec - b->tv_usec;

  if (usec < 0)
    {
      sec -= 1;
      usec = 1000000 + usec;
    }
  c->tv_usec += usec;
  if (c->tv_usec > 1000000)
    {
      c->tv_sec += sec + 1;
      c->tv_usec -= 1000000;
    }
  else
    {
      c->tv_sec += sec;
    }
}

static void
itc_monotonic (struct timeval *tv)
{
  do_gettimeofday (tv);
}

#ifdef ACCOUNT_IRQ
static  cputime64_t
itc_irq_time (void)
{
  struct cpu_usage_stat *cpustat = &kstat_this_cpu.cpustat;
  return cpustat->irq;
}
#endif

/**********************************************************************
 *
 * File operations
 *
 **********************************************************************/
static int
itc_open (struct inode * inode, struct file * file);

static int
itc_release (struct inode * inode, struct file * file);

static ssize_t
itc_read (struct file * file, char * buf, size_t count, loff_t * ppos);

static struct file_operations itc_fops =
  {
    .owner   = THIS_MODULE,
    .open    = itc_open,
    .release = itc_release,
    .llseek  = no_llseek,
    .read    = itc_read,
  };

static struct miscdevice itc_misc_dev =
  {
    .minor = MISC_DYNAMIC_MINOR,
    .name  = "itc",
    .fops  = &itc_fops
  };


static int idle_notification (struct notifier_block *nblk, unsigned long cmd,
                              void *y)
{
  struct itc *itc;
  struct timeval tv;

  itc = &global_itc[smp_processor_id ()];
  if (cmd == IDLE_START)
    {
      itc_monotonic (&itc->sleep_started);
      itc->sleeping = 1;
    }
  else
    {
      itc_monotonic (&tv);
      cpeamb (&itc->cumm_sleep_time, &tv, &itc->sleep_started);
      itc->sleeping = 0;
    }
  /* printk ("idle_notification %ld %p\n", cmd, y); */
  return 0;
}

static struct notifier_block nblk =
  {
    .notifier_call = idle_notification
  };

static int
itc_release (struct inode * inode, struct file * filp)
{
  idle_notifier_unregister (&nblk);
  atomic_set (&in_use, 0);
  return 0;
}

static void
dummy_wakeup (void *unused)
{
}

static int
itc_open (struct inode * inode, struct file * filp)
{
  int ret = 0;
  unsigned int minor = iminor (inode);

  if (itc_major)
    {
      if (minor != 0)
        {
          return -ENODEV;
        }
    }

  if (atomic_cmpxchg (&in_use, 0, 1))
    {
      return -EALREADY;
    }

  filp->f_op = &itc_fops;
  idle_notifier_register (&nblk);
  on_each_cpu (dummy_wakeup, NULL, 1);

  return ret;
}

static ssize_t
itc_read (struct file *file, char * buf, size_t count, loff_t * ppos)
{
  int i;
  size_t itemsize = sizeof (global_itc[0].cumm_sleep_time);
  ssize_t retval = 0;
  unsigned long flags;
  struct itc *itc = &global_itc[0];
  struct timeval tmp[NR_CPUS], *tmpp;

  tmpp = tmp;
  if (count < itemsize * num_present_cpus ())
    {
      printk (KERN_ERR
              "attempt to read something funny %zu expected %zu(%zu,%u)\n",
              count, itemsize * num_present_cpus (),
              itemsize, num_present_cpus ());
      return -EINVAL;
    }

  spin_lock_irqsave (&lock, flags);
  for (i = 0; i < NR_CPUS; ++i, ++itc)
    {
      if (cpu_present (i))
        {
          if (itc->sleeping)
            {
              struct timeval tv;

              itc_monotonic (&tv);
              cpeamb (&itc->cumm_sleep_time, &tv, &itc->sleep_started);
              itc->sleep_started.tv_sec = tv.tv_sec;
              itc->sleep_started.tv_usec = tv.tv_usec;
            }

          *tmpp++ = itc->cumm_sleep_time;
          retval += itemsize;
        }
    }
  spin_unlock_irqrestore (&lock, flags);

  if (copy_to_user (buf, tmp, retval))
    {
      printk (KERN_ERR "failed to write %zu bytes to %p\n",
              retval, buf);
      retval = -EFAULT;
    }
  return retval;
}

/**********************************************************************
 *
 * Module constructor
 *
 **********************************************************************/
static __init int
init (void)
{
  int err;

  if (itc_major)
    {
      err = register_chrdev (itc_major, DEVNAME, &itc_fops);
      if (err < 0 || ((itc_major && err) || (!itc_major && !err)))
        {
          printk (KERN_ERR "itc: register_chrdev failed itc_major=%d err=%d\n",
                  itc_major, err);
          return -ENODEV;
        }

      if (!itc_major)
        {
          itc_major = err;
        }
    }
  else
    {
      err = misc_register (&itc_misc_dev);
      if (err < 0)
        {
          printk (KERN_ERR "itc: misc_register failed err=%d\n", err);
          return err;
        }
    }

  return err;
}

/**********************************************************************
 *
 * Module destructor
 *
 **********************************************************************/
static __exit void
fini (void)
{
  if (itc_major)
    {
      unregister_chrdev (itc_major, DEVNAME);
    }
  else
    {
      misc_deregister (&itc_misc_dev);
    }
  printk (KERN_DEBUG "itc: unloaded\n");
}

module_init (init);
module_exit (fini);
