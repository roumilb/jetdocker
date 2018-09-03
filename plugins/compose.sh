#!/usr/bin/env bash

COMMANDS['compose']='Compose::Execute' # Function name
COMMANDS_USAGE[2]="  compose                  Run a docker-compose command (alias for docker-compose run --rm)"

optHelp=false

namespace compose
${DEBUG} && Log::AddOutput compose DEBUG

Compose::Execute()
{
    Log "Compose::Execute"

    # Analyse des arguments de la ligne de commande grâce à l'utilitaire getopts
    local OPTIND opt
    while getopts ":h-:" opt ; do
       case $opt in
           h ) optHelp=true;;
           - ) case $OPTARG in
                  help ) Compose::Usage
                         exit 0;;
                  * ) echo "illegal option --$OPTARG"
                      Compose::Usage
                      exit 1;;
               esac;;
           ? ) echo "illegal option -$opt"
               Compose::Usage
               exit 1;;
      esac
    done
    shift $((OPTIND - 1))

    Log "optHelp = ${optHelp}"

    ${optHelp} && {
      Compose::Usage
      exit
    }

    Compose::InitDockerCompose

    docker-compose ${dockerComposeFile} "$@"

}

Compose::Usage()
{
  echo ""
  echo "$(UI.Color.Blue)Usage:$(UI.Color.Default)  jetdocker compose [OPTIONS] [COMMAND]"
  echo ""
  echo "$(UI.Color.Yellow)Options:$(UI.Color.Default)"
  echo "  -h, --help               Print help information and quit"
  echo ""
  echo "Run any docker-compose command via 'jetdocker compose': in the docker-compose documentation above, replace 'docker-compose' by 'jetdocker compose'"
  echo ""
  docker-compose --help
}


Compose::InitDockerCompose()
{
    Log "Jetdocker::InitDockerCompose"

    if [ "$dockerComposeInitialised" = true ]; then
        Log "docker-compose already initialised"
        return;
    fi

    Compose::CheckOpenPorts

    if [ "$optDelete" = true ]; then
        # Delete data volumes
        Compose::DeleteDataVolumes
        optDelete=false # avoid double delete option
    fi

    # Initialise data containers
    Compose::InitDataVolumes

    # MacOSX : add specific compose config file
    if [ "$OSTYPE" != 'linux-gnu' ]; then
        if [ -f "docker-compose-osx.yml" ]; then
            Log "Docker4Mac use docker-compose-osx.yml configuration file"
            dockerComposeFile="-f docker-compose.yml -f docker-compose-osx.yml"
        fi
    fi

    # Pull images from docker-compose config every day
    if [ "$(Jetdocker::CheckLastExecutionOlderThanOneDay  "-${COMPOSE_PROJECT_NAME}")" == "true" ]; then
        Log "Force optBuild to true because it's the first run of day"
        optBuild=true
        Log "docker-compose ${dockerComposeVerboseOption} pull --ignore-pull-failures"
        docker-compose ${dockerComposeVerboseOption} pull --ignore-pull-failures
    fi
    dockerComposeInitialised=true

}

#
# Change default ports if already used
#
Compose::CheckOpenPorts()
{
    Log "Compose::CheckOpenPorts"
    export DOCKER_PORT_HTTP=$(Compose::RaisePort $DOCKER_PORT_HTTP)
    export DOCKER_PORT_HTTPS=$(Compose::RaisePort $DOCKER_PORT_HTTPS)
    export DOCKER_PORT_MYSQL=$(Compose::RaisePort $DOCKER_PORT_MYSQL)
    export DOCKER_PORT_POSTGRES=$(Compose::RaisePort $DOCKER_PORT_POSTGRES)
    export DOCKER_PORT_MAILHOG=$(Compose::RaisePort $DOCKER_PORT_MAILHOG)

    Log "${0} : DOCKER_PORT_HTTP = ${DOCKER_PORT_HTTP}"
    Log "${0} : DOCKER_PORT_HTTPS = ${DOCKER_PORT_HTTPS}"
    Log "${0} : DOCKER_PORT_MYSQL = ${DOCKER_PORT_MYSQL}"
    Log "${0} : DOCKER_PORT_POSTGRES = ${DOCKER_PORT_POSTGRES}"
    Log "${0} : DOCKER_PORT_MAILHOG = ${DOCKER_PORT_MAILHOG}"

}

#
# Function called to set the port to the next free port
#
function Compose::RaisePort {

    port=${1}
    try {
        nc -z -w 1 localhost "$port"
        Compose::RaisePort $((port+1))
    } catch {
        echo $port
    }

}

#
# delete data volumes
# TO OVERRIDE in env.sh in other case than one simple database
#
Compose::DeleteDataVolumes()
{
    Log "Compose::DeleteDataVolumes"
    delete-data-volumes # To avoid BC Break, we keep old function name
}
delete-data-volumes()
{
    echo "$(UI.Color.Red)Do you really want to delete your data volumes? (y/n)$(UI.Color.Default)"
    read -r yes
    if [ "$yes" = 'y' ]; then

        # remove db container in case he's only stopped
        try {
            docker rm -f "${COMPOSE_PROJECT_NAME}-db" > /dev/null 2>&1
        } catch {
            Log "No container ${COMPOSE_PROJECT_NAME}-db to delete"
        }
        # remove dbdata volume
        try {
            docker volume rm "${COMPOSE_PROJECT_NAME}-dbdata" > /dev/null 2>&1
            sleep 1 # some time the docker inspect next command don't relalize the volume has been deleted ! wait a moment is better
            echo "$(UI.Color.Green)${COMPOSE_PROJECT_NAME}-dbdata volume DELETED ! $(UI.Color.Default)"
        } catch {
            Log "No ${COMPOSE_PROJECT_NAME}-dbdata volume to delete"
        }
        Compose::DeleteExtraDataVolumes

    fi
}

#
# delete extra data containers
# TO OVERRIDE in env.sh in specific cases
# For exemple if you have an Elasticseach data container
#
Compose::DeleteExtraDataVolumes()
{
    Log "Compose::DeleteExtraDataVolumes"
    delete-extra-data-volumes # To avoid BC Break, we keep old function name
}
delete-extra-data-volumes() {
    Log "No extra data volume configured, implement Compose::DeleteExtraDataVolumes if needed";
}

#
# init data containers
# TO OVERRIDE in env.sh in other case than one simple Mysql database
#
Compose::InitDataVolumes()
{
    Log "Compose::InitDataVolumes"
    init-data-containers # To avoid BC Break, we keep old function name
}
init-data-containers()
{
    # Database data volume :
    try {
        docker volume inspect "${COMPOSE_PROJECT_NAME}-dbdata" > /dev/null 2>&1
    } catch {
        docker volume create --name "${COMPOSE_PROJECT_NAME}-dbdata" > /dev/null 2>&1
        DatabaseBackup::Fetch

        # run init-extra-data-containers before compose up because it can need volumes created in init-extra-data-containers
        Compose::InitExtraDataVolumes

        # shellcheck disable=SC2086
        docker-compose ${dockerComposeVerboseOption} up -d db
        echo "Restoring Database ......... "
        echo ""
        startTime=$(date +%s)
        # Wait for database connection is ready, see https://github.com/betalo-sweden/await
        echo "Waiting ${DB_RESTORE_TIMEOUT} for mysql://${MYSQL_USER}:${MYSQL_PASSWORD}@localhost:${DOCKER_PORT_MYSQL}/$MYSQL_DATABASE is ready ...... "
        echo ""
        echo "$(UI.Color.Green)follow database restoration logs in an other terminal running this command : "
        echo "$(UI.Color.Blue)  docker logs -f ${COMPOSE_PROJECT_NAME}-db"
        echo "$(UI.Color.Yellow)(if you see errors in logs and the restoration is blocked, cancel it here with CTRL+C)$(UI.Color.Default)"
        echo ""
        echo "$(UI.Color.Green)  Please wait ${DB_RESTORE_TIMEOUT} ... "
        echo ""
        # shellcheck disable=SC2086
        await -q -t ${DB_RESTORE_TIMEOUT} mysql://${MYSQL_USER}:${MYSQL_PASSWORD}@localhost:${DOCKER_PORT_MYSQL}/$MYSQL_DATABASE > /dev/null 2>&1
        awaitReturn=$?
        endTime=$(date +%s)
        if [ $awaitReturn -eq 0 ]; then
            echo "$(UI.Color.Green) DATABASE RESTORED in $(expr "$endTime" - "$startTime") s !! $(UI.Color.Default)"
            try {
                hasSearchReplace=$(docker-compose config | grep search-replace-db 2> /dev/null | wc -l)
                if [ "$hasSearchReplace" -gt 0 ]; then
                    search-replace-db
                fi
            } catch {
                Log "No search-replace-db configured in docker-compose.yml"
            }
        else
            echo "$(UI.Color.Red) DATABASE RESTORATION FAILED "
            echo " Restoring since $(expr "$endTime" - "$startTime") s."
            echo " Check log with this command : docker logs ${COMPOSE_PROJECT_NAME}-db "
            echo " The database dump might be to big for beeing restaured in less than the ${DB_RESTORE_TIMEOUT} await timeout "
            echo " You can increase this timeout in env.sh DB_RESTORE_TIMEOUT parameter "
            echo " then re-run with jetdocker --delete-data up "
            exit 1;
        fi

    }
}

Compose::InitExtraDataVolumes()
{
    Log "Compose::InitDataVolumes"
    init-extra-data-containers # To avoid BC Break, we keep old function name
}
init-extra-data-containers()
{
    Log "No extra data container to create"
}