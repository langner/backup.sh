#!/bin/bash
#
# This script performs an incremental, rolling backup for one local path via rsync.
#
# A snapshot of the directory is held separately for each day, making it trivial to
# recover and restore old files. Files that do not change between backups are hard
# linked to the copy from the previous snapshot, which in turn is referenced by a
# symbolic link so that the option --link-dest is easier to use.
#
# This script also deals to some extent with cleaning old backups by removing
# one old snapshot, which makes for rolling backups when run daily. However,
# this process should be monitored manually at intervals, especially when large
# amounts of data are changed.

# The script requires exactly five arguments. The first is the resolvable name of
# the machine to which we are backing up (can be localhost). The second is the root
# directory on that machines containing backups. The third argument, NKEEP, is used
# to clean an old snapshot after making the new one (from NKEEP days ago). The fourth
# argument is a flag that determines whether or not we want to keep snapshots from
# the first of each month (a value of 1 will keep them). The last argument is the
# local path which we are backing up.
REMOTE=$1
ROOT_REMOTE=$2
NKEEP=$3
KEEPFIRST=$4
DIR=$5

# Replace slashes with underscores in the local path to keep all directories on
# the remote machine on the same level.
DEST=`echo $DIR | sed 's/\//_/g'

# Make sure the script is not already running, by reserving an exclusive lock file.
LOCKFILE=/tmp/backup$DEST.lock
exec 200>$LOCKFILE
flock -n 200 || { >&2 echo "Lock file in use, script might already be running."; exit 1; }

TODAY=`date --iso-8601`
SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# We will be using the weakest encryption available and any options that decrease
# the CPU load so that we can maximize transfer. Note that this string will need
# to be contained in quotes, so that it is expanded only in the final command.
RSH="ssh -c arcfour -T -x -o Compression=no"

# Let rsync print out as much info as technically possible, although this requires
# munging the output we get in order to log it in an acceptable form.
RSYNC_OPTS="--numeric-ids --archive --verbose --stats --progress --human-readable"

# If there is a file in the same directory with the expected pattern, use it to
# define exclude patterns from the backup. This is particularly important when
# backing up an entire system (/) since we don't need to backup anything in /proc
# and other generated content.
EXCLUDE=""
EXCLUDE_FILE=$SCRIPTDIR/backup$DEST.exclude
if [ -e $EXCLUDE_FILE ]; then
    EXCLUDE="--exclude-from=$EXCLUDE_FILE"
fi

# Note how the output piped through tr to get rid of pesky carriage returns, which
# are caused by the --progress option that gives otherwise useful output. This is
# important if the output of this script is redirected to file.
LINK_DEST="$ROOT_REMOTE/$DEST/last"
REMOTE_DIR="$ROOT_REMOTE/$DEST/$TODAY"
RSYNC="rsync $RSYNC_OPTS $EXCLUDE --link-dest=$LINK_DEST $DIR/ $REMOTE:$REMOTE_DIR"
$RSYNC -e "$RSH" | tr -d '\r'

# If there were no errors, do the bookkeeping, otherwise complain.
if [ $? -eq 0 ]; then

    # Update the symbolic link used for --link-dest.
    rsh $REMOTE "cd $ROOT_REMOTE/$DEST; rm last; ln -s $TODAY last"

    # Remove snapshot from NKEEP days ago (except first of the month if KEEPFIRST).
    if [ `date --date="$NKEEP days ago" +"%d"` != "01" -o $KEEPFIRST != 1 ]; then
        TOREMOVE=`date --date="$NKEEP days ago" --iso`
        TOREMOVE="$ROOT_REMOTE/$DEST/$TOREMOVE"
        if ssh $REMOTE stat $TOREMOVE \> /dev/null 2\>\&1; then
            echo "Removing $TOREMOVE on $REMOTE..."
            rsh $REMOTE "rm -rf $TOREMOVE"
        fi
    fi

    # Since we reset SECONDS above, this should show the time spent on this directory only.
    echo "Finished in ${SECONDS}s."

else
    echo "Problem with backup of $DIR to $REMOTE:$ROOT_REMOTE for $TODAY"
    exit 1
fi
