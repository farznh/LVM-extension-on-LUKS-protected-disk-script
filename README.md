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

# How to Use This Script

Follow these simple steps to safely extend your disk space.

## 1. Prerequisites

### Run as Root
This script requires root privileges to manage disks.

### Make Executable
Before running, give the script execute permissions:

chmod +x script_name.sh

sudo ./script_name.sh

## 3. Follow the On-Screen Menu

The script will present a menu. Choose the option that matches your situation:

- **Option 1 & 2 (Adding a NEW Disk)**:  
  Use these if you have physically added a new, separate hard drive to the system.  
  You will be asked if you want to give all the new space to `/`, all to `/home`, or split it between them.

- **Option 3 & 4 (Resizing an EXISTING Disk)**:  
  Use these if you have expanded an existing virtual disk (e.g., in VMware, VirtualBox, or a cloud provider).  
  You will be asked if you want to give the new space to `/`, to `/home`, or split it between them.

## 4. Answer the Prompts

The script will ask for information, such as the disk name (e.g., `sda`, `sdb`, etc.) and how much space you want to allocate.  
Read each prompt carefully before confirming.

## 5. Reboot

After the script finishes, it will prompt you to reboot. A reboot is highly recommended to ensure the system correctly applies all changes.

> **Warning**: While this script is designed to be safe, always back up critical data before performing any disk management operations.
