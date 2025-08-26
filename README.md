# LVM-extension-on-LUKS-protected-disk-script
This is an interactive Bash script to automate and simplify the process of extending LVM logical volumes (/ and /home) on LUKS-encrypted disks in a Linux environment. It provides a user-friendly, menu-driven interface to handle common storage management scenarios, reducing the risk of manual error during critical disk operations.

Key Features:
Menu-Driven & Interactive: A simple terminal interface guides you through every step.

Handles Two Core Scenarios:
Adding a New Physical Disk: Automatically partitions, encrypts, and integrates a new disk into the existing LVM Volume Group.
Resizing an Existing Disk: Safely expands the partition, LUKS container, and LVM layers to utilize space added to an existing virtual or physical disk.

Flexible Space Allocation: For both scenarios, the script allows you to:
Allocate all new space to the root (/) filesystem.
Allocate all new space to the home (/home) filesystem.
Interactively distribute the new space between both / and /home by user's choice.
Fully Automated: Manages all underlying commands for:
Partitioning (parted)
LUKS encryption (cryptsetup)
LVM management (pvcreate, vgextend, pvresize, lvextend)
Filesystem resizing (xfs_growfs, resize2fs)
System-Aware: Automatically updates /etc/crypttab, GRUB, and initramfs to ensure a new encrypted volume is recognized on boot.
Safe to Use: Includes clear confirmation prompts before any destructive actions are taken and logs all output to a timestamped file for auditing and debugging.
