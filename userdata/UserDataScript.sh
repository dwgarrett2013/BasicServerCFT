#!/bin/bash
set -e 

exec > >(tee -a /var/log/eb-cfn-init.log|logger -t [eb-cfn-init] -s 2>/dev/console) 2>&1

PREINIT_CMD='
{
  "api_version" : "1.0",
  "request_id": "0",
  "command_name": "CMD-PreInit"
}
'

SELF_STARTUP_CMD='
{
  "api_version" : "1.0",
  "request_id": "0",
  "command_name": "CMD-SelfStartup"
}
'
function log
{
  NANOSEC=`date +%N`
  echo -e [`date -u +"%Y-%m-%dT%H:%M:%S"`.${NANOSEC:0:3}Z] "$@"
}

# Emit starting log
log Started EB Bootstrapping Script.

# Update cfn bootstrap to get the latest version of cfn-init etc
#yum update -y system-release
RPMS=$1
TARBALLS=$2
EB_GEMS=$3
SIGNAL_URL=$4
STACK_ID=$5
REGION=$6
GUID=$7
HEALTHD_GROUP_ID=$8
HEALTHD_ENDPOINT=$9
PROXY_SERVER=${10}
HEALTHD_PROXY_LOG_LOCATION=${11}

PARAM_LIST="Received parameters:\n\
    RPMS = $RPMS\n\
    TARBALLS = $TARBALLS\n\
    EB_GEMS = $EB_GEMS\n\
    SIGNAL_URL = $SIGNAL_URL\n\
    STACK_ID = $STACK_ID\n\
    REGION = $REGION\n\
    GUID = $GUID\n\
    HEALTHD_GROUP_ID = $HEALTHD_GROUP_ID\n
    HEALTHD_ENDPOINT = $HEALTHD_ENDPOINT\n
    PROXY_SERVER = $PROXY_SERVER\n
    HEALTHD_PROXY_LOG_LOCATION = $HEALTHD_PROXY_LOG_LOCATION"
log $PARAM_LIST

# Helper functions
function error_exit
{
  cfn-signal 1 "$1"
  exit 1
}

function tailog 
{
  log "Tailing $2"
  echo -e "\n******************* $1 taillog *******************"
  if [ -f "$2" ]; then
    echo -e "$(tail -n 50 $2)"
  else
    echo -e "***$1 is not available yet.***"
  fi
  echo -e "******************* End of taillog *******************\n\n"
}

function tail_logs
{
  tailog eb-commandprocessor /var/log/eb-commandprocessor.log
  tailog eb-activity /var/log/eb-activity.log
  tailog eb-tools /var/log/eb-tools.log
  tailog eb-version-deployment /var/log/eb-version-deployment.log
  tailog cfn-init /var/log/cfn-init.log
  tailog cfn-hup /var/log/cfn-hup.log
}

function log_and_exit
{
  log $1 
  # signal success
  cfn-signal 0

  # Output startup logs into the console.
  tail_logs
  
  log Completed EB Bootstrapping Script.
  exit 0
}

function is_baked
{
	if [[ -f /etc/elasticbeanstalk/baking_manifest/$1 ]]; then
    true
	else
    false
	fi
}

function mark_installed
{
    mkdir -p /etc/elasticbeanstalk/baking_manifest/
    echo `date -u` > /etc/elasticbeanstalk/baking_manifest/$1-manifest    
}

SLEEP_TIME=10
SLEEP_TIME_MAX=86400 # One day
function sleep_delay
{
  if (( $SLEEP_TIME < $SLEEP_TIME_MAX )); then 
    log Sleeping $SLEEP_TIME ...
    sleep $SLEEP_TIME  
    SLEEP_TIME=$(($SLEEP_TIME * 2)) 
  else 
    log Sleeping $SLEEP_TIME_MAX ...
    sleep $SLEEP_TIME_MAX  
  fi
}

function retry_execute 
{
  log Started executing $@.
  
  SLEEP_TIME=10
  while true; do 
    FN_OUTPUT=""
    set +e 
    "$@"
    RESULT=$? 
    set -e
    log Command Returned: "$FN_OUTPUT"
    if (( $RESULT != 0 )); then 
      log "Command return code $RESULT".
      tail_logs
      sleep_delay
      log Retrying... 
    else
      break
    fi 
  done

  log Completed executing $1.
}

function install_rpms 
{
  for RPM_LIB in $@
  do
    log Installing RPM: $RPM_LIB.
    FULL_NAME=${RPM_LIB##*/}
    RPM_NAME=${FULL_NAME%.*}
    INSTALLED_RPM=$(rpm -q $RPM_NAME)
    RESULT=$?
    if (( $RESULT == 0 )); then
      log $RPM_NAME has already been installed. Skip installing.
    else
      FN_OUTPUT="$FN_OUTPUT\n\n$(rpm -Uv --nodeps --force $RPM_LIB 2>&1)"
      RESULT=$?
      if [ $RESULT -ne 0 ]; then
        return $RESULT
      fi
    fi
  done
}

function install_tarballs 
{
  for TAR_BALL in $@
  do
    log Installing tarball: $TAR_BALL.
    FULL_NAME=${TAR_BALL##*/}
    if is_baked ${FULL_NAME}-manifest; then
      log $FULL_NAME has already been installed. Skip installing.
    else
      FN_OUTPUT="$FN_OUTPUT\n\n$(wget --tries=3 --retry-connrefused -nv -O /tmp/$FULL_NAME $TAR_BALL 2>&1 \
        && tar --no-same-owner --no-same-permissions -C / -xf /tmp/$FULL_NAME 2>&1 1>/dev/null \
        && rm -f /tmp/$FULL_NAME)"
      RESULT=$?
      if [ $RESULT -ne 0 ]; then
        return $RESULT
      fi
      mark_installed ${FULL_NAME}
    fi
  done
}

function install_eb_gems
{
  mkdir -p /tmp/ebgems
  source /opt/elasticbeanstalk/lib/ruby/profile.sh
  for GEM in $@
  do
    log Installing EB Gem: $GEM.
    FULL_NAME=${GEM##*/}
    GEM_FULL_NAME=${FULL_NAME%.*}
    GEM_NAME=${GEM_FULL_NAME%-*}
    GEM_VERSION=${GEM_FULL_NAME##*-}
    INSTALLED=$(gem query -i -v $GEM_VERSION -i $GEM_NAME)
    RESULT=$?
    if (( $RESULT == 0)); then
      log $GEM_FULL_NAME has already been installed. Skip installing.
    else
      FN_OUTPUT="$FN_OUTPUT\n\n$(wget --tries=3 --retry-connrefused -nv -O /tmp/ebgems/$FULL_NAME $GEM 2>&1 \
        && gem install --local -f --no-document /tmp/ebgems/$FULL_NAME 2>&1)"
      RESULT=$?
      if [ $RESULT -ne 0 ]; then
        return $RESULT
      fi
    fi
  done
  rm -rf /tmp/ebgems
}

function run_healthd
{
    id -u healthd &>/dev/null || useradd -s /sbin/nologin healthd

    # Healthd config files
    mkdir -p /etc/healthd # root owns

    # Healthd logs
    mkdir -p /var/log/healthd
    chown healthd:healthd /var/log/healthd

    # Healthd pid directory
    mkdir -p /var/run/healthd
    chown healthd:healthd /var/run/healthd

    # Healthd base plugin directory
    mkdir -p /var/elasticbeanstalk/healthd # root owns

    # for reboots
    rm -f /etc/healthd/config.yaml

    echo "group_id: $HEALTHD_GROUP_ID" >> /etc/healthd/config.yaml
    if [ -n "$HEALTHD_ENDPOINT" ]
    then
        echo "endpoint: $HEALTHD_ENDPOINT" >> /etc/healthd/config.yaml
    fi

    echo "log_to_file: true" >> /etc/healthd/config.yaml
    if [ "$PROXY_SERVER" == "httpd" ]
    then
        echo "appstat_log_path: /var/log/httpd/healthd/application.log" >> /etc/healthd/config.yaml
        echo "appstat_unit: usec" >> /etc/healthd/config.yaml
        echo "appstat_timestamp_on: arrival" >> /etc/healthd/config.yaml
    elif [ "$PROXY_SERVER" == "nginx" ]
    then
        echo "appstat_log_path: /var/log/nginx/healthd/application.log" >> /etc/healthd/config.yaml
        echo "appstat_unit: sec" >> /etc/healthd/config.yaml
        echo "appstat_timestamp_on: completion" >> /etc/healthd/config.yaml
    elif [ "$PROXY_SERVER" == "other" ]
    then
        echo "appstat_log_path: $HEALTHD_PROXY_LOG_LOCATION" >> /etc/healthd/config.yaml
        echo "appstat_unit: sec" >> /etc/healthd/config.yaml
        echo "appstat_timestamp_on: completion" >> /etc/healthd/config.yaml
    fi

cat << EOF1 > /etc/init/healthd.conf
description "Elastic Beanstalk Healthd Upstart Manager"
author "Elastic Beanstalk"

start on runlevel [2345]
stop on runlevel [!2345]

respawn
respawn limit 15 5

script
exec /bin/bash <<"EOF2"
    if [ -d /etc/healthd ]
    then
        source /opt/elasticbeanstalk/lib/ruby/profile.sh
        exec su -s /bin/bash -c "healthd" healthd
    fi
EOF2
end script
EOF1

# force restart for custom AMIs
initctl restart healthd || initctl start healthd

if ( initctl status healthd | grep stop ); then
    initctl start healthd

    # wait for healthd to gracefully start first
    for i in `seq 1 60`;
    do
        status_output=`curl -s localhost:22221/status || true`
        if [ "$status_output" == '{"status":"ok"}' ]; then
            echo $status_output;
            break;
        fi;
        echo $status_output;
        echo "Waiting for healthd to start ...";
        sleep 0.5;
    done
fi
}

function stop_healthd
{
    # remove config so it does not restart
    rm -rf /etc/healthd

    # try to stop if already running
    initctl stop healthd || true;

    # remove upstart script
    rm -rf /etc/init/healthd.conf
}

function cfn_init
{
  log Running cfn-init ConfigSet: $1.
  if [[ $2 == "first_init"  ]]; then
    local stackname=$STACK_ID
  else
    local stackname=$(/opt/elasticbeanstalk/bin/get-config meta -k stackname)
    log Using local cached stack name for reboot.
  fi
  FN_OUTPUT=$(EB_EVENT_FILE=/var/log/eb-startupevents.log EB_SYSTEM_STARTUP=true /opt/aws/bin/cfn-init -s "$stackname" \
    -r AWSEBAutoScalingGroup --region "$REGION" --configsets $1 > /var/log/eb-cfn-init-call.log 2>&1 )
}

function cfn-signal
{
  local signalurl=$(/opt/elasticbeanstalk/bin/get-config meta -k instance_signal_url)
  if [[ -z $signalurl ]]; then
    # use default signal url if not specified in metadata
    signalurl=$SIGNAL_URL
  fi
  if [[ -z $2 ]]; then
    local reason=""
  else
    local reason=" -r $2 "
  fi
  log Sending signal $1 to CFN wait condition $signalurl
  /opt/aws/bin/cfn-signal -e $1 $reason "$signalurl" || log 'Wait Condition Signal expired.'
}

function run_eb_command
{
  log Running EB Command: $1.
  FN_OUTPUT=$(CMD_DATA=$1 /opt/elasticbeanstalk/bin/command-processor -e)
}

function start_cfn_hup
{
  log Starting cfn-hup.
  FN_OUTPUT=$(start cfn-hup LANG=$LANG) 
}

function sync_clock
{
  log Synchronizing network time in background. 
  nohup sh -c "service ntpd stop; ntpdate -u 0.amazon.pool.ntp.org 1.amazon.pool.ntp.org 2.amazon.pool.ntp.org 3.amazon.pool.ntp.org; service ntpd start" &
}


function update_mirror_list
{
  for i in updates preview gpu nosrc hvm graphics; do
    local repo_file="/etc/yum.repos.d/amzn-$i.repo"
    if [ -f $repo_file ]; then
      sed -i -r 's/mirror.list$/mirror.list-$guid/' $repo_file
    fi

    local template_file="/etc/cloud/templates/amzn-$i.repo.tmpl"
    if [ -f $template_file ]; then
      sed -i -r 's/mirror.list$/mirror.list-\\$guid/' $template_file
    fi
  done
}

function lock_repo_version
{
  if is_baked lock_repo_version_${GUID}-manifest; then
    log yum repo has already been locked to $GUID.
  else
    log Locking yum repo version to GUID.
    mkdir -p /etc/yum/vars
    echo $GUID > /etc/yum/vars/guid
    chmod 644 /etc/yum/vars/guid

    update_mirror_list

    yum clean -y all || echo Warning: cannot clean local yum cache. Continue...
    mark_installed lock_repo_version_$GUID
    log Completed yum repo version locking.
  fi
}

function update_yum_packages
{
  if is_baked update_yum_packages_${GUID}-manifest; then
    log yum update has already been done.
  else
    log Updating yum packages.
    yum --exclude=aws-cfn-bootstrap update -y || echo Warning: cannot update yum packages. Continue...
    mark_installed update_yum_packages_$GUID

    # Update system-release RPM package will reset the .repo files
    # Update the mirror list again after yum update
    update_mirror_list

    log Completed updating yum packages. 
  fi
}

function create_eb_user_group
{
    groupadd -f -r awseb
    log Completed creating AWS EB users and groups.
}

#------------- Start of Execution -----------------

sync_clock

# Yum package update
lock_repo_version
update_yum_packages

# create users and groups
create_eb_user_group

## Install Packages ##
retry_execute install_rpms $RPMS
retry_execute install_tarballs $TARBALLS
retry_execute install_eb_gems $EB_GEMS

if [ -n "$HEALTHD_GROUP_ID" ]
then
    # enhanced health
    log "Starting healthd"
    run_healthd
else
    # basic health
    log "Ensuring healthd is not running"
    # could be already running if AMI baked from enhanced health environment
    stop_healthd
fi

# branch on if instance already initialized
# set EB_FIRST_RUN only on first run, otherwise empty
if [[ $(/opt/elasticbeanstalk/eb_infra/infra-provision_registrar.rb instance-init check) == "first_init" ]]; then
  log First init of instance.
  export EB_FIRST_RUN=true
  retry_execute cfn_init '_OnInstanceBoot' 'first_init'
  /opt/elasticbeanstalk/eb_infra/infra-provision_registrar.rb instance-init mark
else
  log Reboot of instance.
  retry_execute cfn_init '_OnInstanceReboot'
fi

log Check whether controlled by launch workflow...
export EB_IS_WORKFLOW_RUNNING=false
LAUNCH_S3_URL=$(/opt/elasticbeanstalk/bin/get-config meta -k launchs3url) || log 'Failed to find launch s3 url.'

if [[ "$LAUNCH_S3_URL" ]]; then
  if wget -q "$LAUNCH_S3_URL" > /dev/null; then
    log Worflow running.
    export EB_IS_WORKFLOW_RUNNING=true
  fi
fi

if [[ "$EB_IS_WORKFLOW_RUNNING" == "true" ]];
then
  log Workflow controlled instance. Running container provisioning... 
  retry_execute start_cfn_hup
  retry_execute run_eb_command "$PREINIT_CMD"
else
  log Scaled up instance. Running full self-initiated provisioning.
  # Writing startup version to prevent duplicate execution
  #  retry_execute write_metadata
  retry_execute run_eb_command "$PREINIT_CMD"
  retry_execute run_eb_command "$SELF_STARTUP_CMD"
  retry_execute start_cfn_hup
fi

log_and_exit 'Successfully bootstrapped instance.'

