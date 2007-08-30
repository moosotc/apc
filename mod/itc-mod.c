#ifdef CONFIG_PREEMPT
#define ITC_PREEMPT_HACK
#endif

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
#include <linux/miscdevice.h>

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
    #include <linux/smp_lock.h>
    #ifdef CONFIG_SMP
        #error Support for SMP on 2.4 series of kernels is not written yet
    #else
        #define num_present_cpus() 1
        #define num_online_cpus() 1
        /* #define cpu_online(n) 1 */
        #define cpu_present(n) 1
    #endif

    #if LINUX_VERSION_CODE < KERNEL_VERSION (2, 4, 20)
        #define iminor(inode) MINOR((inode)->i_rdev)
    #else
        #define iminor(inode) minor((inode)->i_rdev)
    #endif
#endif

#ifdef CONFIG_PREEMPT
#define itc_enter_bkl() do {                    \
  preempt_disable ();                           \
  lock_kernel ();                               \
} while (0)
#define itc_leave_bkl() do {                    \
  unlock_kernel ();                             \
  preempt_enable ();                            \
} while (0)
#else
#define itc_enter_bkl lock_kernel
#define itc_leave_bkl unlock_kernel
#ifdef ITC_PREEMPT_HACK
#error Attempt to enable ITC_PREEMPT_HACK on non preemptible kernel
#endif
#endif

MODULE_DESCRIPTION ("Idle time collector");

#ifdef CONFIG_X86
static void (*fidle_func) (void);
static long idle_func;
#if LINUX_VERSION_CODE < KERNEL_VERSION (2, 6, 0)
MODULE_PARM (idle_func, "l");
#else
module_param (idle_func, long, 0644);
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

static int in_use;
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

#if LINUX_VERSION_CODE >= KERNEL_VERSION (2, 6, 0)
/* XXX: 2.4 */
/**********************************************************************
 *
 * Dummy to make sure we are unloaded properly
 *
 **********************************************************************/
static void
dummy_wakeup (void *unused)
{
  printk (KERN_DEBUG "waking up %d\n", smp_processor_id ());
  /* needed? safe? */
  set_need_resched ();
}
#endif

/**********************************************************************
 *
 * idle
 *
 **********************************************************************/
#if LINUX_VERSION_CODE > KERNEL_VERSION (2, 6, 0)
#define QUIRK
#else
void default_idle (void);
#endif

static void
itc_monotonic (struct timeval *tv)
{
  do_gettimeofday (tv);
}

static void
itc_idle (void)
{
  struct itc *itc;
  struct timeval tv;
  unsigned long flags;

#ifdef ITC_PREEMPT_HACK
  preempt_disable ();
#endif

  /* printk ("idle in %d\n", smp_processor_id ()); */
  spin_lock_irqsave (&lock, flags);
  itc = &global_itc[smp_processor_id ()];
  itc_monotonic (&itc->sleep_started);
  itc->sleeping = 1;
  spin_unlock_irqrestore (&lock, flags);

#ifdef QUIRK
  if (orig_pm_idle)
    {
      orig_pm_idle ();
    }
#ifdef CONFIG_X86
  else
    {
      fidle_func ();
    }
#endif
#else
  if (orig_pm_idle)
    {
      orig_pm_idle ();
    }
  else
    {
#ifdef CONFIG_X86
      if (fidle_func)
        {
          fidle_func ();
        }
      else
#endif
        {
          default_idle ();
        }
    }
#endif

  spin_lock_irqsave (&lock, flags);
  itc_monotonic (&tv);
  cpeamb (&itc->cumm_sleep_time, &tv, &itc->sleep_started);
  itc->sleeping = 0;
  spin_unlock_irqrestore (&lock, flags);
  /* printk ("idle out %d\n", smp_processor_id ()); */

#ifdef ITC_PREEMPT_HACK
  preempt_enable ();
#endif
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

static struct miscdevice itc_misc_dev =
  {
    .minor = MISC_DYNAMIC_MINOR,
    .name  = "itc",
    .fops  = &itc_fops
  };

static int
itc_release (struct inode * inode, struct file * filp)
{
  itc_enter_bkl ();
  pm_idle = orig_pm_idle;
  in_use = 0;
  itc_leave_bkl ();
#if LINUX_VERSION_CODE >= KERNEL_VERSION (2, 6, 0)
  /* XXX: 2.4 */
  on_each_cpu (dummy_wakeup, NULL, 0, 1);
#endif
  return 0;
}

static int
itc_open (struct inode * inode, struct file * filp)
{
  int ret = 0;
  const struct file_operations *old_fops = filp->f_op;
  unsigned int minor = iminor (inode);

  if (itc_major)
    {
      if (minor != 0)
        {
          return -ENODEV;
        }
    }

  if (in_use)
    {
      return -EALREADY;
    }

  /* old_fops = filp->f_op; */
  filp->f_op = fops_get (&itc_fops);
  fops_put (old_fops);

  itc_enter_bkl ();
  if (pm_idle != itc_idle)
    {
      orig_pm_idle = pm_idle;
    }
  pm_idle = itc_idle;
  in_use = 1;
  itc_leave_bkl ();

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
              "attempt to read something funny %d expected %d(%d,%d)\n",
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
 * ioctl handler
 *
 **********************************************************************/
static int
itc_ioctl (struct inode * inode, struct file * filp,
           unsigned int cmd, unsigned long arg)
{
  return -EINVAL;
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

#ifdef CONFIG_X86
  fidle_func = (void (*) (void)) idle_func;
#endif

#ifdef QUIRK
  if (!pm_idle
#ifdef CONFIG_X86
      && !fidle_func
#endif
      )
    {
      printk
        (KERN_ERR
         "itc: no idle function\n"
         "itc: boot kernel with idle=halt option\n"
         "itc: or specify idle_func (modprobe itc idle_func=<address>)\n");
      return -ENODEV;
    }
#endif

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

  orig_pm_idle = pm_idle;
  printk
    (KERN_DEBUG
     "itc: driver loaded pm_idle=%p default_idle=%p"
#ifdef CONFIG_X86
     ", idle_func=%p"
#endif
     "\n",
     pm_idle
#ifdef QUIRK
     , NULL
#else
     , default_idle
#endif
#ifdef CONFIG_X86
     , fidle_func
#endif
     );
  printk (KERN_DEBUG "itc: CPUs(%d present=%d online=%d)"
#ifdef QUIRK
          " Q"
#endif
#ifdef CONFIG_APM
          " A"
#endif
#ifdef CONFIG_SMP
          " S"
#endif
#ifdef CONFIG_PREEMPT
          " P"
#endif
          "\n",
          NR_CPUS, num_present_cpus (), num_online_cpus ());
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
  printk (KERN_DEBUG "itc: unloading (resetting pm_idle to %p)\n",
          orig_pm_idle);
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
