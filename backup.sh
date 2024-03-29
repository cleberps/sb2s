#!/bin/bash

# Simple backup script
# Created by Cleber Paiva de Souza (cleber@ssys.com.br)
# Tested on RHEL, CentOS, SUSE, OpenSUSE, Ubuntu and Gentoo

# Global functions
function msgOk()
{
    if [ -t 1 ]; then
        echo -e "[ \e[00;32mOK\e[00m ]"
    else
        echo -e "[ OK ]"
    fi
}

function msgFailed()
{
    if [ -t 1 ]; then
        echo -e "[ \e[00;31mFAILED\e[00m ]"
    else
        echo -e "[ FAILED ]"
    fi
}

# Set default settings

# Disable autorun
ENABLED=false

# Variables and definitions
LOCAL_TMP_DIR="/tmp"
MOUNT_NFS_FIRST=false
BACKUP_DIR="/etc /root /var/spool/cron"
BACKUP_EXCLUDE=""

# Backup MySQL
MYSQL_BACKUP=false
MYSQL_USER="root"
MYSQL_PASSWORD="root"
MYSQL_DATABASE_LIST="all"

# Backup PostgreSQL
PGSQL_BACKUP=false
PGSQL_USER="postgres"
PGSQL_DATABASE_LIST="all"

# Backup LDAP
LDAP_BACKUP=false
LDAP_USER="cn=Manager,dc=domain"
LDAP_PASSWORD="XXXXXXX"

# Remote location
BACKUP_PROTOCOL="nfs"
SERVER_USER="root"
SERVER_HOSTNAME="nfs"
SERVER_DEST_BASE_DIR="/home/backup"
LOCAL_BACKUP_DIR="/backup"
SSH_SERVER_PORT=22
SSH_REMOVE_FILE_AFTER_TRANSFER=true

# Services to restart before backup
SERVICES_RESTART=""

# Check if script should continue
if [ ! ${ENABLED} ]; then
    echo "Script not enabled."
    exit 0
fi

# Load configuration file
BACKUP_CONF="$(dirname $0)/backup.conf"
[ ! -z $1 ] && BACKUP_CONF="$1"

if [ ! -f ${BACKUP_CONF} ]; then
    echo "Configuration file missing."
    exit 0
fi

echo -n "Using configuration file ${BACKUP_CONF}... "
. ${BACKUP_CONF}
[ $? -eq 0 ] && msgOk || msgFailed

# Update BACKUP_DIR for only valid directories
t=""
for dir in ${BACKUP_DIR}; do
    [ -e $dir ] && t="${t} ${dir}"
done
BACKUP_DIR=$t

# Restart services before backup
for service in $SERVICES_RESTART; do
    CHECK_SYSTEMCTL=$(pidof systemd >/dev/null 2>&1)
    if [ $? -eq 0 ]; then
        $(which systemctl) restart ${service} >/dev/null 2>&1
    else
        CHECK_SERVICE=$(which service)
        if [ $? -eq 0 ]; then
            ${CMD} ${service} restart >/dev/null 2>&1
        else
            /etc/init.d/${service} restart >/dev/null 2>&1
        fi
    fi
done

# Global parameters (do not change)
: ${MYSQL_BACKUP:=false}
: ${MYSQL_DATABASE_LIST:="all"}
: ${PGSQL_BACKUP:=false}
: ${PGSQL_DATABASE_LIST:="all"}
: ${LDAP_BACKUP:=false}
: ${NAME_PREFIX:=""}
: ${SSH_SERVER_PORT:=22}
DATE_NOW=$(date +%Y%m%d)
HOSTNAME=$(hostname -s)
[ ${#NAME_PREFIX} -gt 0 ] && NAME_PREFIX="${NAME_PREFIX}-"
TEMP_FILE="${LOCAL_TMP_DIR}/${HOSTNAME}-backup-${NAME_PREFIX}${DATE_NOW}.tar.gz"

# Check directories
if [ ! -d ${LOCAL_TMP_DIR} ]; then
    echo "Directory ${LOCAL_TMP_DIR} does not exists."
    exit 1
fi

# NFS mount function
function mountNFS()
{
    $(which mount) -t nfs $SERVER_HOSTNAME:$SERVER_DEST_BASE_DIR $LOCAL_BACKUP_DIR
    if [ $? -eq 0 ]; then
        # Check if directory to host files exist
        if [ ! -d ${LOCAL_BACKUP_DIR}/${HOSTNAME} ]; then
            echo -n "NFS => Creating directory to host backup files... "
            mkdir ${LOCAL_BACKUP_DIR}/${HOSTNAME}
            [ $? -eq 0 ] && msgOk || msgFailed
        fi
    else
        echo "Error mouting NFS directory."
	exit 1
    fi
}

# Copy files to NFS share
function copyToNFS()
{
    # Copy backup file to NFS share
    echo -n "NFS => Copying file to NFS server... "
    $(which cp) ${TEMP_FILE} $LOCAL_BACKUP_DIR/${HOSTNAME}/ > /dev/null 2>&1
    [ $? -eq 0 ] && msgOk || msgFailed
}

# Check if NFS mounting point should be mounted first
if [ ${BACKUP_PROTOCOL} = "nfs" -a ${MOUNT_NFS_FIRST} ]; then
    mountNFS
fi

# Backup rotines
# Generating package list
PACKAGE_LIST="${HOSTNAME}-packages-${DATE_NOW}.txt"
PACKAGE_LIST_DUMP="${LOCAL_TMP_DIR}/${PACKAGE_LIST}"
if [ -f "/etc/gentoo-release" ]; then
    Q=$(which qlist)
    echo -n "Creating list of packages... "
    [ -x $Q ] && $Q -IU >${PACKAGE_LIST_DUMP}
    if [ $? -eq 0 ]; then
        BACKUP_DIR="${BACKUP_DIR} ${PACKAGE_LIST_DUMP}"
        msgOk
    else
        msgFailed
    fi
elif [ -f "/etc/redhat-release" ] || 
    [ -f "/etc/centos-release" ] ||
    [ -f "/etc/SuSE-release" ] ; then
    Q=$(which rpm)
    echo -n "Creating list of packages... "
    [ -x $Q ] && $Q -qa --qf "%{NAME} | %{VERSION}\n" | sort >${PACKAGE_LIST_DUMP}
    if [ $? -eq 0 ]; then
        BACKUP_DIR="${BACKUP_DIR} ${PACKAGE_LIST_DUMP}"
        msgOk
    else
        msgFailed
    fi
elif [ -f "/etc/debian_version" ]; then
    Q=$(which dpkg)
    echo -n "Creating list of packages... "
    [ -x $Q ] && $Q -l >${PACKAGE_LIST_DUMP}
    if [ $? -eq 0 ]; then
        BACKUP_DIR="${BACKUP_DIR} ${PACKAGE_LIST_DUMP}"
        msgOk
    else
        msgFailed
    fi
else
    echo "Linux distribution not supported."
    exit 1
fi

# Backup pip info
PIP_LIST="${HOSTNAME}-pip-${DATE_NOW}.txt"
PIP_LIST_DUMP="${LOCAL_TMP_DIR}/${PIP_LIST}"
PIP_CMD=$(which pip)
if [ $? -eq 0 ]; then
    echo -n "Creating list of pip packages... "
    [ -x ${PIP_CMD} ] && ${PIP_CMD} list --format=columns >${PIP_LIST_DUMP} 2>&1
    if [ $? -eq 0 ]; then
        BACKUP_DIR="${BACKUP_DIR} ${PIP_LIST_DUMP}"
        msgOk
    else
        msgFailed
    fi
fi

# Backup docker info
DOCKER_LIST="${HOSTNAME}-docker-${DATE_NOW}.txt"
DOCKER_LIST_DUMP="${LOCAL_TMP_DIR}/${DOCKER_LIST}"
DOCKER_CMD=$(which docker)
if [ $? -eq 0 ]; then
    echo -n "Getting info about docker... "
    if [ -x ${DOCKER_CMD} ]; then
        ${DOCKER_CMD} info   >${DOCKER_LIST_DUMP}  2>&1
        ${DOCKER_CMD} images >>${DOCKER_LIST_DUMP} 2>&1
        ${DOCKER_CMD} ps     >>${DOCKER_LIST_DUMP} 2>&1
    fi
    if [ $? -eq 0 ]; then
        BACKUP_DIR="${BACKUP_DIR} ${DOCKER_LIST_DUMP}"
        msgOk
    else
        msgFailed
    fi
fi

# Backup MySQL databases
if ${MYSQL_BACKUP}; then
    COUNT=$(pgrep "(mysql|mariadbd)" | wc -l)
    if [ ${COUNT} -eq 0 ]; then
        echo "No MySQL server running to issue backup commands."
        exit 1
    fi

    echo -n "Backuping MySQL database... "
    MYSQL_DUMP_FILE="${LOCAL_TMP_DIR}/${HOSTNAME}-mysqldump-${DATE_NOW}.sql.gz"
    BACKUP_DIR="${BACKUP_DIR} ${MYSQL_DUMP_FILE}"
    if [ ${MYSQL_DATABASE_LIST} = "all" ]; then
        $(which mysqldump) -A -c -e --add-drop-table -u ${MYSQL_USER} \
          -p"${MYSQL_PASSWORD}" | $(which gzip) -9 >${MYSQL_DUMP_FILE}
    else
        $(which mysqldump) -c -e --add-drop-table --databases ${MYSQL_DATABASE_LIST} \
          -u ${MYSQL_USER} -p"${MYSQL_PASSWORD}" | $(which gzip) -9 >${MYSQL_DUMP_FILE}
    fi
    [ $? -eq 0 ] && msgOk || msgFailed
fi

# Backup PostgreSQL databases
if ${PGSQL_BACKUP}; then
    COUNT=$(pgrep postgres | wc -l)
    if [ ${COUNT} -eq 0 ]; then
        echo "No PostgreSQL server running to issue backup commands."
        exit 1
    fi

    echo -n "Backuping PostgreSQL database... "
    PGSQL_DUMP_FILE="${LOCAL_TMP_DIR}/${HOSTNAME}-pgdump-${DATE_NOW}.sql.gz"
    BACKUP_DIR="${BACKUP_DIR} ${PGSQL_DUMP_FILE}"
    if [ ${PGSQL_DATABASE_LIST} = "all" ]; then
        su - ${PGSQL_USER} -c "$(which pg_dumpall)" | $(which gzip) -9 >${PGSQL_DUMP_FILE}
    else
        PGSQL_DUMP_FILE="${LOCAL_TMP_DIR}/${HOSTNAME}-pgdump-${DATE_NOW}.sql"
        echo "" >${PGSQL_DUMP_FILE}
        for database in $(echo ${PGSQL_DATABASE_LIST}); do
            su - ${PGSQL_USER} -c "$(which pg_dump) ${database}" >>${PGSQL_DUMP_FILE}
        done
        $(which gzip) -9 ${PGSQL_DUMP_FILE}
    fi
    [ $? -eq 0 ] && msgOk || msgFailed
fi

# Backup LDAP
if ${LDAP_BACKUP}; then
    COUNT=$(pgrep slapd | wc -l)
    if [ ${COUNT} -eq 0 ]; then
        echo "No LDAP server running to issue backup commands."
        exit 1
    fi

    echo -n "Backuping LDAP database... "
    LDAP_DUMP_FILE="${LOCAL_TMP_DIR}/${HOSTNAME}-ldap-${DATE_NOW}.ldif"
    BACKUP_DIR="${BACKUP_DIR} ${LDAP_DUMP_FILE}"
    $(which slapcat) >${LDAP_DUMP_FILE} 2>/dev/null
    [ $? -eq 0 ] && msgOk || msgFailed
fi

# Append exclude dir to tar command
DIRS_FOR_EXCLUSION=""
if [ ${#BACKUP_EXCLUDE} -gt 0 ]; then
    for dir in ${BACKUP_EXCLUDE}; do
        DIRS_FOR_EXCLUSION="${DIRS_FOR_EXCLUSION} --exclude=${dir}"
    done
fi

# Create backup file
echo -n "Creating tar.gz file... "
tar -czpf ${TEMP_FILE} ${DIRS_FOR_EXCLUSION} ${BACKUP_DIR} 2>/dev/null
[ $? -eq 0 ] && msgOk || msgFailed

# Transfer file
case ${BACKUP_PROTOCOL} in
    "ssh")
        echo -n "SSH => Moving file to backup server... "
        scp -o StrictHostKeyChecking=no \
            -P ${SSH_SERVER_PORT} \
            ${TEMP_FILE} \
            ${SERVER_USER}@${SERVER_HOSTNAME}:${SERVER_DEST_BASE_DIR}/${HOSTNAME} \
            >/dev/null 2>&1
        [ $? -eq 0 ] && msgOk || msgFailed
        [ ${SSH_REMOVE_FILE_AFTER_TRANSFER} ] && rm -f ${TEMP_FILE}
        ;;
    "nfs")
    	[ ! ${MOUNT_NFS_FIRST} ] && mountNFS
	copyToNFS
        ;;
    "local")
        # Check if directory to host files exist
        if [ ! -d ${LOCAL_BACKUP_DIR}/${HOSTNAME} ]; then
            echo -n "LOCAL => Creating directory to host backup files... "
            mkdir ${LOCAL_BACKUP_DIR}/${HOSTNAME}
            [ $? -eq 0 ] && msgOk || msgFailed
        fi

        echo -n "LOCAL => Moving file to local directory... "
        mv ${TEMP_FILE} ${LOCAL_BACKUP_DIR}/${HOSTNAME}
        [ $? -eq 0 ] && msgOk || msgFailed
        ;;
    *)
        echo "Protocol not supported."
        exit 1
esac

# Cleaning the house
echo -n "Cleaning temp files... "
{
[ -f ${TEMP_FILE} ] && rm -f ${TEMP_FILE}
[ -f ${PACKAGE_LIST_DUMP} ] && rm -f ${PACKAGE_LIST_DUMP}
[ -f ${PIP_LIST_DUMP} ] && rm -f ${PIP_LIST_DUMP}
[ -f ${DOCKER_LIST_DUMP} ] && rm -f ${DOCKER_LIST_DUMP}
if [ ${MYSQL_BACKUP} ]; then
    [ -f ${MYSQL_DUMP_FILE} ] && rm -f ${MYSQL_DUMP_FILE}
fi
if [ ${LDAP_BACKUP} ]; then
    [ -f ${LDAP_DUMP_FILE} ] && rm -f ${LDAP_DUMP_FILE}
fi
}
[ $? -eq 0 ] && msgOk || msgFailed

# For NFS umounting should occur after cleaning temp files
[ ${BACKUP_PROTOCOL} = "nfs" ] && umount $LOCAL_BACKUP_DIR
