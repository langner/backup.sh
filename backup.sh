#!/bin/bash
#
# This script backups up any number of local directories to a remote server via rsync.
#
# A snapshot of each directory and for each day is held separetly. Files that do not
# change are hard linked to files in a previous snapshot, which in turn is pointed
# to by a symbolic link passed to the option --link-dest. This script also deals
# to some extent with removing old backups, but it suggested that this be monitored
# manually at intervals, especially when large amount of data are changed.

LOCAL="mymachine"
REMOTE="backup@othermachine"

# These locations normally will not change with time, but may need to be adjusted.
# The first is the directory to backup to on the remote machine, and the second
# is the location on the local machine (assuming it is mounted somehow).
ROOT_REMOTE="/mnt/backups/$LOCAL"
LOG_DIR="/root/local/logs/backups"

# When adding a target directory to this list, the corresponding directory
# will need to be created on the remote in ROOT_REMOTE as defined above.
DIRLIST="/ /data /home /var"

# The number of days back to keep archives. Note that we will not remove all older
# archives at once, rather the script will attempt to remove the snapshot from
# exactly NKEEP days ago each time it runs. This incremental behavior allows some
# manual tweaking, and requires a bit of supervision. The second flag determines
# whether the first day of each month is never removed.
NKEEP=14
KEEPFIRST=1

# We will be using the weakest encryption available and any options that decrease
# the CPU load so that we can maximize transfer. Note that this string will need
# to be contained in quotes, so it is expanded only in the final command.
RSH="ssh -c arcfour -T -x -o Compression=no"

# Let rsync print out as much info as technically possible, although this requires
# munging the output we get in order to log it in an acceptable form.
RSYNC_OPTS="--numeric-ids --archive --verbose --stats --progress --human-readable"

# Make sure the script is not running, by reserving an exclusive lock file.
LOCKFILE=/var/run/backup.lock
exec 200>$LOCKFILE
flock -n 200 || { echo "Lock file in use, script might already be running."; exit 1; }

FAIL_STATUS=0
TODAY=`date --iso-8601`
SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
for DIR in $DIRLIST; do

    # Reset the bash timer.
    SECONDS=0

    # Replace slashes with underscores to keep all directories on the same level.
    DEST=`echo $DIR | sed 's/\//_/g'`

    # If there is a file in the same directory with the expected pattern,
    # use it to exclude patterns from the backup.
    EXCLUDE=""
    EXCLUDE_FILE=$SCRIPTDIR/backup$DEST.exclude
    if [ -e $EXCLUDE_FILE ]; then
        EXCLUDE="--exclude-from=$EXCLUDE_FILE"
    fi

    LINK_DEST="$ROOT_REMOTE/$DEST/last"
    REMOTE_DIR="$ROOT_REMOTE/$DEST/$TODAY"
    RSYNC="rsync $RSYNC_OPTS $EXCLUDE --link-dest=$LINK_DEST $DIR/ $REMOTE:$REMOTE_DIR"
    LOG="$LOG_DIR/${DEST}-$TODAY.log"

    # Me need to get rid of pesky carriage returns, which are caused by the --progress
    # option that gives otherise useful output. From this command, we want stdout and
    # stderr to go to the log, but only stderr echoed back out.
    $RSYNC -e "$RSH" | tr -d '\r' > $LOG 2> >(tee $LOG >&2)

    # If there were no errors, do the bookkeeping, otherwise complain.
    if [ $? -eq 0 ]; then

        # Update the symbolic link used for --link-dest.
        rsh $REMOTE "cd $ROOT_REMOTE/$DEST; rm last; ln -s $TODAY last"

        # Remove snapshot from NKEEP days ago.
        if [ `date --date="$NKEEP days ago" +"%d"` != "01" -o $KEEPFIRST != 1 ]; then
            TOREMOVE=`date --date="$NKEEP days ago" --iso`
            TOREMOVE="$ROOT_REMOTE/$DEST/$TOREMOVE"
            if ssh $REMOTE stat $TOREMOVE \> /dev/null 2\>\&1; then
                echo "Removing $TOREMOVE on $REMOTE..." >> $LOG
                rsh $REMOTE "rm -rf $TOREMOVE"
            fi
        fi

        # Since we reset SECONDS above, this should show the time spent on this directory only.
        echo "Finished in ${SECONDS}s." >> $LOG

    else
        echo "Problem with backup for $DEST"
        FAIL_STATUS=1
    fi

done

# This script is normally run as a cron job, so any echoes to stdout/stderr should be
# a last resort since they will be sent by email to root.
if [ $FAIL_STATUS -eq 0 ]; then
        exit 0
else
        echo "Backup for $LOCAL failed $TODAY"
        exit 1
fi
