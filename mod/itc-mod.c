#include <linux/signal.h>
#include <linux/sched.h>
#include <linux/interrupt.h>

#include <linux/version.h>
#include <linux/vmalloc.h>
#include <linux/module.h>
#include <linux/delay.h>
#include <linux/init.h>
#include <linux/slab.h>
#include <linux/smp.h>
#include <linux/mm.h>
#include <linux/pm.h>

#include <asm/system.h>
#include <asm/uaccess.h>

#ifdef CONFIG_6xx
#include <asm/machdep.h>
#define pm_idle ppc_md.power_save
#endif

#if !(defined CONFIG_X86 || defined CONFIG_6xx)
#error Support for this architecture is not written yet
#endif

#if LINUX_VERSION_CODE < KERNEL_VERSION (2, 6, 0)
    #include <linux/wrapper.h>
    #ifdef CONFIG_SMP
        #define NB_CPUS weight (phys_cpu_present_map)
    #else
        #define NB_CPUS 1
    #endif

    #if LINUX_VERSION_CODE < KERNEL_VERSION (2, 4, 20)
        #define iminor(inode) MINOR((inode)->i_rdev)
    #else
        #define iminor(inode) minor((inode)->i_rdev)
    #endif
#else
    #define NB_CPUS num_present_cpus ()
#endif


MODULE_DESCRIPTION ("Idle time collector");

static void (*idle_func) (void);

#ifdef CONFIG_X86
/* there are many ways to prevent gcc from complaining about module_param
   and function pointer vs long, but let's not */
#if LINUX_VERSION_CODE < KERNEL_VERSION (2, 6, 0)
MODULE_PARM (idle_func, "l");
#else
module_param (idle_func, long, 0777);
#endif
MODULE_PARM_DESC (idle_func, "address of default idle function");
#endif

#define DEVNAME "itc"
static spinlock_t lock = SPIN_LOCK_UNLOCKED;

static void (*orig_pm_idle) (void);
static unsigned int itc_major;

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

/**********************************************************************
 *
 * File operations
 *
 **********************************************************************/
static int
itc_open (struct inode * inode, struct file * file);

static int
itc_release (struct inode * inode, struct file * file);

static int
itc_ioctl (struct inode * inode, struct file * file,
           unsigned int cmd, unsigned long arg);

static ssize_t
itc_read (struct file * file, char * buf, size_t count, loff_t * ppos);

static struct file_operations itc_fops =
  {
    .owner   = THIS_MODULE,
    .open    = itc_open,
    .release = itc_release,
    .ioctl   = itc_ioctl,
    .llseek  = no_llseek,
    .read    = itc_read,
  };


static int
itc_release (struct inode * inode, struct file * filp)
{
  return 0;
}

static int
itc_open (struct inode * inode, struct file * filp)
{
  int ret = 0;
  const struct file_operations *old_fops = filp->f_op;
  unsigned int minor = iminor (inode);

  if (minor != 0)
    return -ENODEV;

  /* old_fops = filp->f_op; */
  filp->f_op = fops_get (&itc_fops);
  fops_put (old_fops);
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

  /* printk ("itemsize=%d cpus=%d count=%d\n", itemsize, NR_CPUS, count); */
  if (count < itemsize * NB_CPUS)
    {
      printk (KERN_ERR
              "attempt to read something funny %d expected %d(%d,%d)\n",
              count, itemsize * NB_CPUS, itemsize, NB_CPUS);
      return -EINVAL;
    }

  spin_lock_irqsave (&lock, flags);
  for (i = 0; i < NB_CPUS; ++i, ++itc)
    {
      if (itc->sleeping)
        {
          struct timeval tv;

          do_gettimeofday (&tv);
          cpeamb (&itc->cumm_sleep_time, &tv, &itc->sleep_started);
          itc->sleep_started.tv_sec = tv.tv_sec;
          itc->sleep_started.tv_usec = tv.tv_usec;
        }

      if (copy_to_user (buf, &itc->cumm_sleep_time, itemsize))
        {
          printk (KERN_ERR "failed to write %zu bytes to %p\n", itemsize, buf);
          retval = -EFAULT;
          break;
        }
      retval += itemsize;
      buf += itemsize;
    }

  spin_unlock_irqrestore (&lock, flags);
  return retval;
}

/**********************************************************************
 *
 * ioctl handler
 *
 **********************************************************************/
static int
itc_ioctl (struct inode * inode, struct file * filp,
           unsigned int cmd, unsigned long arg)
{
  return 0;
}

/**********************************************************************
 *
 * idle
 *
 **********************************************************************/
#if LINUX_VERSION_CODE > KERNEL_VERSION (2, 6, 0)
#ifndef CONFIG_APM
#define QUIRK
#endif
#else
void default_idle (void);
#endif

static void
itc_idle (void)
{
  struct itc *itc;
  struct timeval tv;
  unsigned long flags;

  /* printk ("idle in\n"); */
  spin_lock_irqsave (&lock, flags);
  itc = &global_itc[smp_processor_id ()];
  do_gettimeofday (&itc->sleep_started);
  spin_unlock_irqrestore (&lock, flags);

#ifdef QUIRK
  if (orig_pm_idle)
    {
      orig_pm_idle ();
    }
  else
    {
      idle_func ();
    }
#else
  if (orig_pm_idle)
    {
      orig_pm_idle ();
    }
  else
    {
      if (idle_func)
        {
          idle_func ();
        }
      else
        {
          default_idle ();
        }
    }
#endif

  spin_lock_irqsave (&lock, flags);
  do_gettimeofday (&tv);
  cpeamb (&itc->cumm_sleep_time, &tv, &itc->sleep_started);
  itc->sleeping = 0;
  spin_unlock_irqrestore (&lock, flags);
  /* printk ("idle out\n"); */
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

#ifdef QUIRK
  if (!pm_idle && !idle_func)
    {
      printk
        (KERN_ERR
         "itc: no idle function\n"
         "itc: boot kernel with idle=halt option\n"
         "itc: or specify idle_func (modprobe itc idle_func=<address>)\n");
      return -ENODEV;
    }
#endif

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

  printk
    (KERN_DEBUG
     "itc: driver loaded pm_idle=%p default_idle=%p, idle_func=%p\n",
     pm_idle,
#ifdef QUIRK
     NULL,
#else
     default_idle,
#endif
     idle_func
     );

  orig_pm_idle = pm_idle;
  pm_idle = itc_idle;
  return 0;
}

/**********************************************************************
 *
 * Module destructor
 *
 **********************************************************************/
static __exit void
fini (void)
{
  printk (KERN_DEBUG "itc: unloading\n");

  unregister_chrdev (itc_major, DEVNAME);
  printk (KERN_DEBUG "itc: unloaded\n");

  pm_idle = orig_pm_idle;
}

module_init (init);
module_exit (fini);
