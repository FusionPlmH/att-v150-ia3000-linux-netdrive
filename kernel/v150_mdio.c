// SPDX-License-Identifier: GPL-2.0
/*
 * v150_mdio - borrow the MDIO bus that ixgbe registers, so we can talk to
 * the Marvell 88E6190X switch (SMI address 0x10) on the Silicom V150.
 *
 * Why this way: mdiobus_read()/mdiobus_write() reuse the driver's own
 * locking and hardware timing, so we never poke IXGBE_MSCA/MSRWD directly.
 *
 * Interface: /proc/v150_mdio
 *   echo "r <smi> <reg>"       > /proc/v150_mdio
 *   echo "w <smi> <reg> <val>" > /proc/v150_mdio
 *   cat /proc/v150_mdio          (shows the last result)
 */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/netdevice.h>
#include <linux/phy.h>
#include <linux/proc_fs.h>
#include <linux/uaccess.h>
#include <linux/string.h>

#define MDIO_PREFIX "ixgbe-mdio"

static char *netdev = "enp5s0f0";
module_param(netdev, charp, 0444);
MODULE_PARM_DESC(netdev, "netdev whose child MDIO bus should be used");

static struct mii_bus *v150_bus;
static char v150_result[160] = "no operation yet\n";

static int v150_match_mdio(struct device *dev, const void *data)
{
	return strncmp(dev_name(dev), MDIO_PREFIX, strlen(MDIO_PREFIX)) == 0;
}

static int v150_dump_child(struct device *dev, void *data)
{
	pr_info("v150_mdio:   child: %s\n", dev_name(dev));
	return 0;
}

static int v150_find_bus(void)
{
	struct net_device *nd;
	struct device *child;

	if (v150_bus)
		return 0;

	nd = dev_get_by_name(&init_net, netdev);
	if (!nd) {
		pr_err("v150_mdio: netdev '%s' not found\n", netdev);
		return -ENODEV;
	}

	child = device_find_child(&nd->dev, NULL, v150_match_mdio);
	if (!child) {
		pr_err("v150_mdio: no child matching '%s*' under %s\n",
		       MDIO_PREFIX, netdev);
		device_for_each_child(&nd->dev, NULL, v150_dump_child);
		dev_put(nd);
		return -ENODEV;
	}

	dev_put(nd);
	v150_bus = to_mii_bus(child);
	pr_info("v150_mdio: attached to mdio bus '%s'\n", v150_bus->id);
	return 0;
}

static ssize_t v150_proc_write(struct file *file, const char __user *ubuf,
			       size_t count, loff_t *ppos)
{
	char kbuf[64];
	char op = 0;
	unsigned int smi = 0, reg = 0, val = 0;
	int n, rc;

	if (count >= sizeof(kbuf))
		return -EINVAL;
	if (copy_from_user(kbuf, ubuf, count))
		return -EFAULT;
	kbuf[count] = '\0';

	if (v150_find_bus())
		return -ENODEV;

	n = sscanf(kbuf, " %c %u %u %u", &op, &smi, &reg, &val);

	if (op == 'r' && n >= 3) {
		rc = mdiobus_read(v150_bus, smi, reg);
		if (rc < 0)
			snprintf(v150_result, sizeof(v150_result),
				 "ERR read smi=%u reg=0x%02x rc=%d\n", smi, reg, rc);
		else
			snprintf(v150_result, sizeof(v150_result),
				 "r smi=%u reg=0x%02x val=0x%04x (%u)\n",
				 smi, reg, rc, rc);
	} else if (op == 'w' && n >= 4) {
		rc = mdiobus_write(v150_bus, smi, reg, val);
		if (rc < 0)
			snprintf(v150_result, sizeof(v150_result),
				 "ERR write smi=%u reg=0x%02x rc=%d\n", smi, reg, rc);
		else
			snprintf(v150_result, sizeof(v150_result),
				 "w smi=%u reg=0x%02x val=0x%04x ok\n", smi, reg, val);
	} else {
		snprintf(v150_result, sizeof(v150_result),
			 "usage: \"r <smi> <reg>\" or \"w <smi> <reg> <val>\"\n");
	}

	return count;
}

static ssize_t v150_proc_read(struct file *file, char __user *ubuf,
			      size_t count, loff_t *ppos)
{
	return simple_read_from_buffer(ubuf, count, ppos,
				       v150_result, strlen(v150_result));
}

static const struct proc_ops v150_proc_ops = {
	.proc_read  = v150_proc_read,
	.proc_write = v150_proc_write,
};

static struct proc_dir_entry *v150_entry;

static int __init v150_init(void)
{
	int rc = v150_find_bus();

	if (rc)
		return rc;

	v150_entry = proc_create("v150_mdio", 0600, NULL, &v150_proc_ops);
	if (!v150_entry) {
		pr_err("v150_mdio: proc_create failed\n");
		return -ENOMEM;
	}
	pr_info("v150_mdio: ready, use /proc/v150_mdio\n");
	return 0;
}

static void __exit v150_exit(void)
{
	if (v150_entry)
		proc_remove(v150_entry);
	pr_info("v150_mdio: unloaded\n");
}

module_init(v150_init);
module_exit(v150_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Borrow ixgbe MDIO bus to reach the V150 Marvell 88E6190X switch");
MODULE_AUTHOR("V150 adaptation");
