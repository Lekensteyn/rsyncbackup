# rsyncbackup
Simple interface for encrypted offline backups with snapshots support.

Features:

 - Encryption through LUKS.
 - Reliability of rsync for synchronization.
 - Snapshot functionality through the use of btrfs filesystem.
 - Multiple backup sources (partitions or folders).
 - Exclude files from backups (such as `~/.cache/` and `/var/cache/`) using
   standard *Include/Exclude Pattern Rules* from rsync.

After configuration, all you have to run for making backups is:

    sudo do-backup dobackup && sudo do-backup umount

## Usage
The backup interface is very simple. Usage: `do-backup [options] command
[source..]`.

Valid options are:

 - `-c FILE`: Use config file `FILE` instead of .backup-config (in program dir).
 - `-n`: Dry-run, print the commands without executing.
 - `-v`: Verbose output, print commands as they are executed.

Commands:

 - sources       Print all possible backup sources.
 - testrsync     Dry-run rsync (without destination mount).
 - mount         Mount the storage and exit (needs root).
 - umount        Unmount storage and exit (needs root).
 - dobackup      Mount and backup.

Note: if no source is given, everything will be included.

## Quick Start Guide
This section describes how to prepare a new disk for unencrypted backups. When
the "backup configuration" is mentioned, it refers to the `.backup-config` file
in the program directory which needs to be created first. You can use
`sample.backup-config` as inspiration.

### Prepare partition
Before you can make backups, you will need an external disk (USB / eSATA / ...).
Create a btrfs partition on it:

    sudo mkfs.btrfs /dev/sdc1

Locate the partition identifier using `sudo blkid` and add it to the backup
configuration. Example blkid output:

   /dev/sdc1: UUID="da66d110-9119-43a1-bedf-ef797cc685fa" TYPE="btrfs"

The corresponding backup configuration line:

    fs_UUID=da66d110-9119-43a1-bedf-ef797cc685fa

### What to backup
The backup program backups everything in a single mount point and does not cross
devices. Look in the `mount` output or `/etc/fstab` to find locations. If you
have a single root filesystem with both `/` and `/home` on it, but want to
backup them separately, use this backup configuration:

    backup_sources['Home']='//home'
    backup_sources['Root']='//'

The double slash (`//`) marks the end of a mount point, any path after it is
treated as directory below that mountpoint.

### Excluding files
Optionally you can specify exclusion patterns for each backup source. These
patterns are stored in files named after the backup source. To enable the use of
this, specify the path to the directory in the backup configuration:

    excluderulesdir=/home/user/rsync-excl.d

If you would like to ignore `/var/cache/`, `/var/tmp/`, `~/.cache/` for each
user and `/home/user/rubbish` (for a specific user), you will create these
files:

    # /home/user/rsync-excl.d/Root
    /var/cache/
    /var/tmp/

    # /home/user/rsync-excl.d/Home
    # Note: relative to the backup source /home
    /*/.cache/
    /user/rubbish

Comments are possible by using `#`, for more possible patterns consult the
`rsync` manual page, section *Include/Exclude Pattern Rules*.

### Backing up
Now that you have configured the backup program, you are ready to perform
backups. To make a backup of everything, invoke:

    sudo do-backup dobackup

When finished, unmount the destination drive with:

    sudo do-backup umount

If you are in a hurry and want to save just your Home backup source, it is also
possible to specify that single backup source:

    sudo do-backup backup Home

If you would like to check the list of files that would be transferred without
actually copying files, use the `testrsync` command:

    sudo do-backup testrsync Root > /tmp/test-rsync.txt

## Encrypted backups
For encrypted backups, there is another layer between the partition and the
destination filesystem. If you have to start from scratch, create a backup
partition as follows:

    # Format partition, and enter a passphrase. DO NOT FORGET IT!
    sudo cryptsetup luksFormat /dev/sdb1

    # Unlock the partition after entering a passphrase.
    sudo cryptsetup luksOpen /dev/sdb1 backup

    # Finally format the plaintext layer
    mkfs.btrfs /dev/mapper/backup

As for the backup configuration, you additionally have to set the `luks_UUID`
variable. If the `sudo blkid` output looks like this:

    /dev/sdb1: UUID="a0becda8-1af5-4767-9df0-c5a21508eaff" TYPE="crypto_LUKS"
    /dev/mapper/luks-a0becda8-1af5-4767-9df0-c5a21508eaff:
        UUID="e33dd512-9d4e-4852-9fa0-bd0e7689455d" TYPE="btrfs"

then use this:

    luks_UUID=e33dd512-9d4e-4852-9fa0-bd0e7689455d
    fs_UUID=a0becda8-1af5-4767-9df0-c5a21508eaff

## Backup structure
The backup storage is mounted at `/mnt` (or whatever is specified by the
`fs_mountpoint` configuration option). The directory structure for two backup
sources Home and Root is:

    Home/                       (btrfs subvolume)
    Root/
    snapshots/Root_20150123/    (btrfs read-only snapshots)
    snapshots/Root_20150601/
    snapshots/Home_20150123/
    snapshots/Home_20150124/
    snapshots/Home_20150601/

To perform a restore, simply copy the files from the snapshots.

## Bugs
Currently only btrfs is supported because it is the only mainline filesystem
which provided snapshot functionality.

## License
Copyright (c) 2015 Peter Wu &lt;peter@lekensteyn.nl&gt;

This project is licensed under the MIT license. See the LICENSE file for more
details.
