#!/bin/bash

if [[ $EUID -ne 0 ]]
then
    echo "This script must be run as root" 1>&2
    exit 1
fi

set -x
#Base locations for chroot and mounting sentinel
MOUNTED=false
DEL_UPPERDIR=true
LOWER_DIR=/
BASE_DIR=/tmp
UNIQUE_END="$$_$(date +"%H%M%S")"

read -r -d '' HELPSTRING<<EOF
Usage: $(basename $0) [-h] [-p] [-b <BASE DIR>] [-k] <script path> --- Build and execute a script inside a pseudo-sandbox.
       -k, --mount-only	        Only mount overlayfs -- do not execute script.
       -b, --base-dir		Change the base directory for building chroot sandbox.
       -p, --preserve-wd	Preserve working directory (for changes to sandbox).
       -h, --help		Display help information.
EOF

#Do basic cleanup
function cleanup_mount {
    if [ $MOUNTED ]
    then
        umount -l $CHROOT_DIR
    fi
}

function cleanup_dir {
    rm -rf $WORK_DIR
    rm -rf $CHROOT_DIR
    if [ $DEL_UPPERDIR ]
    then
	rm -rf $UPPER_DIR
    fi
}

function generate_cleanup_scripts {
    function baklog {
	echo "$1" 1>$2
    }
    
    #Save just in-case we explode
    BAK_LOG="/tmp/test_env-$UNIQUE_END.log"
    touch $BAK_LOG
    chmod +x $BAK_LOG
    baklog "Upper directory: $UPPER_DIR" $BAK_LOG
    baklog "Work directory: $WORK_DIR" $BAK_LOG
    baklog "Mount/Chroot directory: $CHROOT_DIR" $BAK_LOG

    BAK_CLEAN="/tmp/test_env-cleanup_$UNIQUE_END.sh"
    touch $BAK_CLEAN
    chmod +x $BAK_CLEAN
    baklog "!#/bin/bash" $BAK_CLEAN
    baklog "rm -rf $UPPER_DIR" $BAK_CLEAN
    baklog "rm -rf $WORK_DIR" $BAK_CLEAN
    baklog "sudo umount -l $CHROOT_DIR" $BAK_CLEAN
}

function cleanup_clean {
    if [ -a $BAK_LOG ] && [ -a $BAK_CLEAN ]
    then
	rm -f $BAK_LOG $BAK_CLEAN
    fi    
}

function cleanup {
    if [ ! $MOUNT_ONLY ]
    then
	cleanup_mount
	cleanup_dir
	cleanup_clean
    fi
}

if [[ $# -lt 1 ]]
then
    echo "$HELPSTRING"
    exit 1
fi

#Process parameters
while [[ $# -gt 1 ]]
do
    key="$1"
    case $key in
	-k|--mount-only)
	    MOUNT_ONLY=true
	    ;;
	-b|--base-dir)
	    BASE_DIR=$2
	    shift
	    ;;
	-p|--preserve-upper)
	    DEL_UPPERDIR=false
	    ;;
	-h|--help)
	    echo "$HELPSTRING"
	    ;;
	-s|--source)
	    BSOURCE=$2
	    shift
	    ;;
	*)
	    echo "Unknown option $key." 1>&2;
	    echo "$HELPSTRING"
	    exit 1
	    ;;
    esac
    shift
done

#Validate executable
SCRIPT_E=$1

if [ ! -x $SCRIPT_E ]
then
    echo "$SCRIPT_E does not exist and/or is not executable." 1>&2
    exit 1
fi

#Extract and extend base directories
#Insure ending slash is removed from BASE_DIR in the event it is passed by command line
BASE_DIR=$(echo $BASE_DIR | sed -n -e 's/\/$//' -e 'p')
UPPER_DIR="$BASE_DIR/tmproot-$UNIQUE_END"
WORK_DIR="$BASE_DIR/tmpwork-$UNIQUE_END"
CHROOT_DIR="$BASE_DIR/tmpchroot-$UNIQUE_END"

#Make LOWER_DIR exists and directories to be created don't.
if [ -d UPPER_DIR ] || [ -d WORK_DIR ]						  
then
    echo "$UPPER_DIR and/or $WORK_DIR already exist!" 1>&2
    exit 1
fi

TEST_HOME=/home/test-$UNIQUE_END
#Create directories for mounting
mkdir -p $UPPER_DIR $WORK_DIR $CHROOT_DIR/$TEST_HOME

generate_cleanup_scripts
#Cleanup trap
trap cleanup EXIT

if [ $? -ne 0 ]
then
    echo "Failed to mkdir $UPPER_DIR and $WORK_DIR." 1>&2
    echo "Verify that you have permission to create directories in $BASE_DIR." 1>&2
    exit 1
fi


#Mount overlay directory
OVERLAY_OPTS=lowerdir\=$LOWER_DIR,upperdir\=$UPPER_DIR,workdir\=$WORK_DIR
mount -t overlay overlay -o $OVERLAY_OPTS $CHROOT_DIR

if [ $? -ne 0 ]
then
    echo "Failed to mount. Make sure specified paths are valid!" 1>&2
    exit 1
else
    MOUNTED=true
fi

#Build environment
if [ ! -z ${BSOURCE+x} ]
then
    cp $BSOURCE $CHROOT_DIR/
else
    touch $CHROOT_DIR/$TEST_HOME/.env_prof
    read -r -d '' ENVDIR<<EOF
export HOME=$TEST_HOME
export PS1="CHROOT| "
EOF
    echo "$ENVDIR" >> $CHROOT_DIR/$TEST_HOME/.env_prof
fi

cp $SCRIPT_E $CHROOT_DIR/$TEST_HOME

#Execute passed in script
if [ ! $MOUNT_ONLY ]
then
    echo "The application log is at $($UNIQUE_END)env.log"
    chroot $CHROOT_DIR /bin/bash -x <<EOF &>/tmp/$($UNIQUE_END)env.log
source $TEST_HOME/.env_prof
$(basename $SCRIPT_E)
EOF
else
    echo "Mount created at $CHROOT_DIR [Work: $WORK_DIR]."
fi

if [ $? -ne 0 ]
then
    echo "Chroot execution failed with $?." 1>&2
fi

exit $?
