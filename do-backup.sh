#!/bin/bash
set -e -u

### Utilities (dependent on config)
RUN() {
    ! $run_echo || echo "$@"
    ! $run_exec || "$@"
}

# Check whether all required dependencies are installed
sanity_check() {
    local prog missing=() rc=0
    for prog in btrfs cryptsetup rsync; do
        if ! $prog --version &>/dev/null; then
            missing+=($prog)
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "Missing programs: ${missing[*]}"
        rc=1
    fi
    if [[ "$fs_type" != btrfs ]]; then
        echo "Only btrfs is supported at the moment!"
        rc=1
    fi
    if [ -n "$excluderulesdir" -a ! -d "$excluderulesdir" ]; then
        echo "excluderulesdir $excluderulesdir is not an existing directory"
        rc=1
    fi
    return $rc
}

# Sets the backup sources filter. If no sources filter is set, every source will
# be backed up.
set_sources_filter() {
    local src
    [ $# -gt 0 ] || set -- "${!backup_sources[@]}"

    for src; do
        # Catch dangerous names such as "..", "sub/dir" or "foo*"
        if ! [[ "$src" =~ ^[a-zA-Z0-9-]+$ ]]; then
            echo "Configuration error: invalid source name $src"
            return 1
        fi
        if [ -z "${backup_sources[$src]:-}" ]; then
            echo "Unknown source: $src"
            return 1
        fi
    done
    use_sources=("$@")
    return 0
}

# Generates paths (with no trailing slash).
# @type: requested directory type
# @item: item for which a path should be returned
# Returns failure if no path could be generated.
get_path() {
    local type=$1 item=$2 path=
    case $type in
    current-dest)
        [ -n "$item" ] || return 1
        path=$fs_mountpoint/$item
        ;;
    snapshot-dest)
        [ -n "$item" ] || return 1
        path=$fs_mountpoint/snapshots/${item}_${snapshot_suffix}
        ;;
    esac

    [ -n "$path" ] || return 1
    path=${path//\/\//\/} # Normalized path
    echo "$path"
    return 0
}

# Checks whether the given source is available (mounted if a mount point is
# mandatory).
# @src: source as enabled by set_sources_filter and available as key in
#       backup_sources.
source_is_available() {
    local src=$1 srcdir
    srcdir=${backup_sources[$src]}/

    # No mount point needed, assume available
    [[ "$srcdir" == *//* ]] || return 0

    # Require everything before "//" to exist. The trailing "/" is needed to
    # avoid testing an empty string (it should check "/" instead).
    mountpoint -q "${srcdir%%//*}/"
}

### Utilities (independent of config)
# Echoes the DM name (dm-X) matching the block device.
# @blockdev: path such as /dev/sdb1 or /dev/disk/by-uuid/...
# Returns failure if LUKS device is not mounted.
blockdev_to_dm() {
    local blockdev=$1 name
    if [ -L "$1" ]; then
        blockdev=$(readlink "$blockdev" | awk -F/ '{print $NF}')
    fi
    for name in "/sys/class/block/$blockdev/holders/"*; do
        name=${name##*/}
        # Match device-mapper entries
        if [[ "$name" == dm-* ]]; then
            echo "$name"
            return 0
        fi
    done
    return 1
}

# Checks if the backup filesystem is already mounted.
# Returns 0 (success) if mounted, 2 if the block device is not mounted, 1
# (failure) if the block device is mounted elsewhere or if the mount point got
# occupied by something else.
fs_is_mounted() {
    local fs_devno devno

    # Filesystem major/minor is empty if nothing is mounted.
    if ! fs_devno=$(mountpoint -qd "$fs_mountpoint"); then
        return 2 # Not mounted
    fi

    # BTRFS can consist of multiple devices, so the major/minor cannot be
    # trivially compared.
    if [[ $fs_type == btrfs ]]; then
        if [ -e "/sys/fs/btrfs/$fs_UUID" ]; then
            # Mountpoint is occupied and btrfs filesystem is loaded. Assume (it
            # is not checked) that the filesystem is mounted at $fs_mountpoint.
            return 0
        else
            # Something else got mounted!
            return 2
        fi
    fi

    # Find the devno for the mountpoint. If there is one, check for the device.
    if ! devno=$(mountpoint -qx "$fs_blockdev"); then
        # Device is unavailable, maybe it is not unlocked yet?
        return 2 # Assume unmounted
    fi
    if [[ $fs_devno != $devno ]]; then
        echo "Something else got mounted on $fs_mountpoint!"
        return 1
    fi
    # OK, device is already mounted.
    return 0
}

### Commands
# Unlocks the LUKS blockdev
do_unlock() {
    local discard_option=
    # Assume that no LUKS container is needed
    [ -n "$luks_UUID" ] || return 0

    if [ ! -e "$luks_blockdev" ]; then
        echo "$luks_blockdev: Cannot find LUKS container."
        return 1
    fi

    # Skip if already unlocked
    ! blockdev_to_dm "$luks_blockdev" >/dev/null || return 0

    if $enableTRIM; then
        discard_option=---allow-discards
    fi

    RUN cryptsetup luksOpen -T 12 $discard_option \
        "$luks_blockdev" "luks-$luks_UUID"
    # Alternative: prompts for root, interface is not guaranteed to be stable.
    #RUN udisksctl unlock --block-device "$luks_blockdev"
}

do_mount() {
    local mount_options dm_name rc=0
    if ! do_unlock; then
        echo "Failed to unlock LUKS container."
        return 1
    fi

    fs_is_mounted || rc=$?
    if [ $rc -eq 0 ]; then
        return 0 # Already mounted, nothing to do
    elif [ $rc -ne 2 ]; then
        # Failed to determine whether device is mounted or not.
        return 1
    fi

    mount_options=noatime
    if $enableTRIM; then
        mount_options+=,discard
    fi

    if [ ! -e "$fs_blockdev" ]; then
        dm_name=$(blockdev_to_dm "$luks_blockdev")
        echo "$fs_blockdev: cannot find blockdev for mounting filesystem."
        echo
        echo "If unformatted, try:    mkfs.btrfs /dev/$dm_name"
        echo "'-d single -m dup' is default for HDD ('-m single' for SSD),"
        echo "Use dup or raid1 if you have plenty of space and favors data"
        echo "resilience over performance."
        return 1
    fi

    RUN mount -t "$fs_type" -o "$mount_options" "$fs_blockdev" "$fs_mountpoint"
    # Alternative: prompts for root, interface is not guaranteed to be stable.
    #udisksctl mount --block-device "$fs_blockdev"
}

do_umount() {
    local rc=0
    fs_is_mounted || rc=$?
    if [ $rc -eq 2 ]; then
        # Device is not mounted, success!
        return 0
    elif [ $rc -ne 0 ]; then
        return 1
    fi

    RUN umount "$fs_mountpoint"
    # Alternative: prompts for root, interface is not guaranteed to be stable.
    #RUN udisksctl unmount --block-device "$fs_blockdev"
}

do_lock() {
    local dm_name luks_name
    if ! do_umount; then
        echo "Failed to unmount $fs_mountpoint"
        return 1
    fi

    # If no DM device is found, assume it is already locked.
    dm_name=$(blockdev_to_dm "$luks_blockdev") || return 0

    if ! luks_name=$(cat "/sys/block/$dm_name/dm/name"); then
        # Perhaps it got unlocked in meantime?
        echo "Cannot find LUKS device name for $dm_name"
        return 1
    fi

    RUN cryptsetup luksClose "$luks_name"
    # Alternative: prompts for root, interface is not guaranteed to be stable.
    #RUN udisksctl lock --block-device "$luks_blockdev"
}

# Runs rsync with additional options, intended for btrfs subvolumes where
# snapshotting is done.
# @rsync_opts: additional rsync options ("-n" for dry run).
# @src: source name (used for exclude rules).
# @srcdir: source directory.
# @destdir: destination directory.
_rsync() {
    local local_rsync_options=($1) src=$2 srcdir=$3 destdir=$4
    if [[ $fs_type != btrfs ]]; then
        # TODO extend for ext4
        echo "Only btrfs is currently supported"
        return 1
    fi

    # No need to keep fsck lost+found directories.
    local_rsync_options+=(--exclude=/lost+found)
    # Apply filter rules if any.
    if [ -n "$excluderulesdir" -a -e "$excluderulesdir/$src" ]; then
        local_rsync_options+=(--exclude-from="$excluderulesdir/$src")
    fi

    RUN rsync "${rsync_options[@]}" "${local_rsync_options[@]}" \
        "$srcdir" "$destdir"
}

# Ensures that the "CURRENT" backup directory is OK for snapshotting.
# @source: source subvolume.
_btrfs_presync() {
    local source=${1%/}
    # If there is no such entry, we can safely create it.
    if [ ! -e "$source" ]; then
        RUN btrfs subvolume create "$source"
        return
    fi

    if [ ! -d "$source" ]; then
        echo "$source: not a directory!"
        return 1
    fi

    # There is already an entry. Assume that this is a btrfs partition and check
    # whether the inode number equals 256 (first inode number of a btrfs
    # subvolume tree).
    if [[ "$(stat -c%i "$source")" != 256 ]]; then
        echo "$source: not a btrfs subvolume. Convert it with:"
        echo "mv $source ${source}.old &&"
        echo "btrfs subvolume create ${source} &&"
        echo "cp --reflink ${source}.old/* ${source}/ &&"
        echo "rm -rf ${source}"
        echo "# with coreutils after 8.23, you can replace cp+rm by:"
        echo "mv ${source}.old/* ${source}/"
        return 1
    fi
    return 0
}

# Creates a read-only snapshot for the given subvolume.
# @source: source subvolume.
# @dest: destination subvolume. Missing parents will be created first.
_btrfs_snapshot() {
    local source=$1 dest=$2 destsuffix= i=0
    # Create parent snapshot directories if missing
    RUN mkdir -p "$(dirname "$dest")"

    # Ensure that snapshot name is unique
    while [ -d "$dest$destsuffix" ]; do
        destsuffix=".$((++i))"
    done

    RUN btrfs subvolume snapshot -r "$source" "$dest$destsuffix"
}

# Syncs sources to target. Assumes that target is mounted.
# @rsync_opts: extra rsync options (empty or "-n")
do_sync() {
    local rsync_dry_run=$1 src srcdir destdir snapshotdestdir

    # For each source, sync stuff and create a snapshot.
    for src in "${use_sources[@]}"; do
        # Normalize /foo//bar -> /foo/bar/
        srcdir=${backup_sources[$src]}
        srcdir=${srcdir%%/}/
        srcdir=${srcdir//\/\//\/}
        # Directories on the remote storage
        destdir=$(get_path current-dest "$src")
        snapshotdestdir=$(get_path snapshot-dest "$src")

        if ! source_is_available "$src"; then
            echo "Source $src ($srcdir) is not mounted, skipping"
            continue
        fi

        [ -n "$rsync_dry_run" ] ||
        _btrfs_presync "$destdir"
        _rsync "$rsync_dry_run" "$src" "$srcdir" "$destdir/"
        [ -n "$rsync_dry_run" ] ||
        _btrfs_snapshot "$destdir" "$snapshotdestdir"
    done
}

### Main
print_usage() {
    cat <<USAGE
Usage: $0 [options] command [source..]

Valid options are:
  -c FILE       Use config file FILE instead of .backup-config (in program dir).
  -n            Dry-run, print the commands without executing.
  -v            Verbose output, print commands as they are executed.
  -h            Print this help.

Commands:
  sources       Print all possible backup sources.
  testrsync     Dry-run rsync (without destination mount).
  mount         Mount the storage and exit (needs root).
  umount        Unmount storage and exit (needs root).
  dobackup      Mount and backup.

Note: if no source is given, everything will be included.

USAGE
}

# Loads configuration from file
init_config() {
    local cfgfile=$1

    # UUID of LUKS partition that needs to be unlocked (empty if there are none)
    declare -ga luks_UUID
    # UUID of the actual filesystem to store backups
    declare -ga fs_UUID
    # Filesystem type (btrfs, ext4, etc.)
    fs_type=btrfs
    # Location to mount the backup filesystem on (TODO: auto-detect?)
    fs_mountpoint=/mnt

    # Associative array of backup sources. Example:
    #   backup_sources["Root"]="//"
    #   backup_sources["Home"]="//home"
    # Everything below the given directory will be synced. If the value contain
    # "//", then the part before that must be a mount point. This is useful if your
    # filesystems are not always mounted.
    declare -gA backup_sources

    ### advanced options
    # Enables the --enable-discards option for cryptsetup and the discard option
    # for mount. WARNING: may leak information for encrypted partitions.
    enableTRIM=false

    # Directory to find files containing rsync exclusion filters.
    excluderulesdir=

    . "$(readlink -f "$1")"
}

# Resolve the list of devices in "luks_UUID" and "fs_UUID" to a single target.
# Sets 'luks_blockdev' and 'fs_blockdev' on success.
resolve_backup_device() {
    local i luks_UUIDx fs_UUIDx valid_index=

    for i in "${!fs_UUID[@]}"; do
        luks_UUIDx="${luks_UUID[i]-}"
        fs_UUIDx="${fs_UUID[i]}"

        [ -e "/dev/disk/by-uuid/$fs_UUIDx" ] ||
        [ -n "$luks_UUIDx" -a -e "/dev/disk/by-uuid/$luks_UUIDx" ] || continue

        if [ -n "$valid_index" ]; then
            echo "Multiple backup disks are found, but only one can be used."
            echo "Disconnect some disks or disable them in your configuration."
            return 1
        fi
        valid_index=$i
    done

    if [ -z "$valid_index" ]; then
        echo "Cannot find backup disk, is it connected?"
        return 1
    fi

    luks_UUID="${luks_UUID[valid_index]-}"
    fs_UUID="${fs_UUID[valid_index]}"

    luks_blockdev=/dev/disk/by-uuid/$luks_UUID
    fs_blockdev=/dev/disk/by-uuid/$fs_UUID
}

# Initialize vars for commands
init_vars() {
    # commands
    # init vars for commands
    luks_blockdev=
    fs_blockdev=
    use_sources=()
    snapshot_suffix=$(date +%Y%m%d)
    ## rsync options
    # -a --archive
    # -v --verbose
    # -i --itemize-changes
    # -A --acls
    # -X --xattrs
    # -x --one-file-system
    # -H --hard-links       # Preserve hard links
    # -n --dry-run
    # --numeric-ids
    # -y --fuzzy # more efficient for basing changes on local directory
    rsync_options=(-aviAXxH --numeric-ids)
    # btrfs optimizations (--no-whole-file enables delta-transfer algo)
    rsync_options+=(--delete-before --inplace --no-whole-file)
    # They are excluded for a reason right?
    rsync_options+=(--delete-excluded)
}

_error_handler() {
    local rc=$? file=$1 lineno=$2 originline=$3
    echo " *** Command exited at line $originline with $rc"
    printf ' %s:%d ' "$file" $lineno
    sed -n ${lineno}p <"$file"
    return $rc
}

set_traps() {
    set -E
    trap '_error_handler "${BASH_SOURCE[0]}" ${BASH_LINENO[0]} $LINENO' ERR
}

main() {
    local cmd= cfgfile name
    cfgfile=$(dirname "$(readlink -f "$0")")/.backup-config
    # Configure the RUN function (default hide command line, but exec it)
    run_echo=false
    run_exec=true

    # Options and command parsing
    while [ $# -gt 0 ]; do
        case $1 in
        -n)
            shift
            run_echo=true
            run_exec=false
            ;;
        -v)
            shift
            run_echo=true
            ;;
        -c)
            shift
            cfgfile=$1; shift
            ;;
        -h)
            print_usage
            exit
            ;;
        -*)
            break
            ;; # Unrecognized option
        *)
            cmd=$1; shift
            break
            ;;
        esac
    done

    # Initialize state
    umask 022
    init_config "$cfgfile"
    init_vars
    set_traps

    case $cmd in
    sources)
        # Sanity-check sources configuration
        set_sources_filter
        # Print all sources as is
        {
            echo "#Name Location"
            for name in "${!backup_sources[@]}"; do
                printf "%s %s\n" "$name" "${backup_sources[$name]}"
            done
        } | column -t
        return 0
        ;;
    testrsync)
        sanity_check
        resolve_backup_device
        set_sources_filter "$@"
        do_mount
        do_sync -n
        ;;
    mount)
        sanity_check
        resolve_backup_device
        do_mount
        ;;
    umount)
        sanity_check
        resolve_backup_device
        do_umount && do_lock
        ;;
    dobackup)
        sanity_check
        resolve_backup_device
        set_sources_filter "$@"
        do_mount
        do_sync ''
        ;;
    *)
        echo "Unknown command"
        print_usage
        sanity_check || :
        resolve_backup_device || :
        set_sources_filter || :
        return 1
        ;;
    esac
}

main "$@"
