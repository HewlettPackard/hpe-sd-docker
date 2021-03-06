#!/bin/bash -e

cat <<EOF
    HPE
   _____                 _              ____  _                __
  / ___/___  ______   __(_)_______     / __ \(_)_______  _____/ /_____  _____
  \__ \/ _ \/ ___/ | / / / ___/ _ \   / / / / / ___/ _ \/ ___/ __/ __ \/ ___/
 ___/ /  __/ /   | |/ / / /__/  __/  / /_/ / / /  /  __/ /__/ /_/ /_/ / /
/____/\___/_/    |___/_/\___/\___/  /_____/_/_/   \___/\___/\__/\____/_/

EOF

################################################################################
# Functions
################################################################################

function finish {
    echo "Container was asked to stop"

    echo "Stopping UOC..."
    su uoc -c '/opt/uoc2/bin/uoc2 stop'

    echo "Stopping CouchDB..."
    /etc/init.d/couchdb stop

    echo "Stopping Service Activator..."
    /etc/init.d/activator stop

    echo "Stopping Kafka..."
    /etc/init.d/kafka stop

    echo "Stopping Zookeeper..."
    /etc/init.d/zookeeper stop

    echo "Stopping SNMP adapter..."
    /opt/sd-asr/adapter/bin/sd-asr-SNMPGenericAdapter_1.sh stop

    echo "Stopping PostgreSQL..."
    /docker/stop_pgsql.sh
}

function runScripts {

    kind="$1"
    scriptDir="$2"

    echo "Running $kind scripts..."
    if [ -d "$scriptDir" ] && [ -n "$(ls -A "$scriptDir")" ]
    then
        for f in $scriptDir/*
        do
            n=$(basename "$f")
            case "$f" in
                *.sh)
                    echo "Running '$n'..."
                    . "$f"
                    ;;
                *.sql)
                    echo "Ignoring '$n' (running SQL scripts is not supported)"
                    echo "WARNING: Running SQL scripts is not supported"
                    ;;
                *)
                    echo "Ignoring '$n' (unknown file extension)"
            esac
            echo
        done
    else
        echo "No $kind scripts found."
    fi
}

function wait_couch {
    printf "Waiting for CouchDB to be ready..."
    until curl -sIfo /dev/null 127.0.0.1:5984
    do
        printf '.'
        sleep 1
    done
    echo
}

################################################################################
# Main
################################################################################

SCRIPTS_DIR=/docker/scripts
SETUP_DONE_MARK=/docker/.setup.done

[[ -f $SETUP_DONE_MARK ]] || runScripts setup $SCRIPTS_DIR/setup
touch $SETUP_DONE_MARK

runScripts startup $SCRIPTS_DIR/startup

echo "Starting Service Director..."
echo

/docker/start_pgsql.sh

echo "Starting CouchDB..."

/etc/init.d/couchdb start

echo "Starting event collection framework..."

/etc/init.d/zookeeper start
sleep 5
/etc/init.d/kafka start

echo "Starting Service Activator..."

. /opt/OV/ServiceActivator/bin/setenv

# Update CLUSTERNODELIST

node_ip=$(hostname -i)
psql -U sa <<EOF
TRUNCATE TABLE MODULES;
UPDATE CLUSTERNODELIST SET HOSTNAME='$HOSTNAME', IPADDRESS='$node_ip';
EOF

# Cleanup standalone.xml history to prevent issues with prepared containers

rm -fr "$JBOSS_HOME/standalone/configuration/standalone_xml_history"

# Cleanup log dirs from intermediate containers created during prepared build

find /var/opt/OV/ServiceActivator/log \
    -mindepth 1 -type d -not -name "$HOSTNAME" -print0 | xargs -0 rm -fr

/etc/init.d/activator start

ASR_CONFIGURED_MARK=/docker/.asr_configured

if [ ! -f $ASR_CONFIGURED_MARK ]
then
    (cd /docker/ansible && ansible-playbook asr_config.yml -c local -i localhost,)
    touch $ASR_CONFIGURED_MARK
fi

wait_couch

echo "Starting UOC..."
su uoc -c 'touch /opt/uoc2/logs/uoc_startup.log'
su uoc -c '/opt/uoc2/bin/uoc2 start'

echo "Starting SNMP adapter..."
/opt/sd-asr/adapter/bin/sd-asr-SNMPGenericAdapter_1.sh start

trap finish EXIT

echo
echo "Service Director is now ready. Displaying Service Activator log..."
echo

tail -f "$JBOSS_HOME/standalone/log/server.log"
