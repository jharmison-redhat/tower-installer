#!/bin/bash

cd "$(dirname "$(realpath "$0")")"

function now {
    date '+%Y%m%dT%H%M%S'
}
# Error handler
function on_error {
    [ -n "$msg" ] && wrap "$msg" ||:
    echo
    now=$(now)
    mv $log error_$now.log
    chmod 644 error_$now.log
    sync
    wrap "Error on $0 line $1, logs available at error_$now.log" >&2
    [ $1 -eq 0 ] && : || exit $2
}

# Generic exit cleanup helper
function on_exit {
    rm -f $log
}

# Stage some logging
log=$(mktemp)
if echo "$*" | grep -qF -- '-v' || echo "$*" | grep -qF -- '--verbose'; then
    exec 7> >(tee -a "$log" |& sed 's/^/\n/' >&2)
    FORMATTER_PAD_RESULT=0
else
    exec 7>$log
fi
echo "Logging initialized $(now)" >&7

# Set some traps
trap 'on_error $LINENO $?' ERR
trap 'on_exit' EXIT

# Get some output helpers to keep things clean-ish
if which formatter &>/dev/null; then
    # I keep this on my system. If you want, you can install it yourself:
    #   mkdir -p ~/.local/bin
    #   curl -o ~/.local/bin/formatter https://raw.githubusercontent.com/solacelost/output-formatter/modern-only/formatter
    #   chmod +x ~/.local/bin/formatter
    #   echo "$PATH" | grep -qF "$(realpath ~/.local/bin)" || export PATH="$(realpath ~/.local/bin):$PATH"
    . $(which formatter)
else
    if echo "$*" | grep -qF -- '--formatter'; then
        mkdir -p ~/.local/bin
        export PATH=~/.local/bin:"$PATH"
        curl -o ~/.local/bin/formatter https://raw.githubusercontent.com/solacelost/output-formatter/modern-only/formatter
        chmod +x ~/.local/bin/formatter
        . ~/.local/bin/formatter
    else
        # These will work as a poor-man's approximation in just a few lines
        function error_run() {
            echo -n "$1"
            shift
            eval "$@" >&7 2>&1 && echo '  [ SUCCESS ]' || { ret=$? ; echo '  [  ERROR  ]' ; return $ret ; }
        }
        function warn_run() {
            echo -n "$1"
            shift
            eval "$@" >&7 2>&1 && echo '  [ SUCCESS ]' || { ret=$? ; echo '  [ WARNING ]' ; return $ret ; }
        }
        function wrap {
            if [ $# -gt 0 ]; then
                if [ "$1" = '-h' ]; then
                    shift
                    echo "${@}" | fold -sw 78 | gawk 'INDENT==0{print $0; INDENT=1} INDENT==1{print "  "$0}'
                else
                    echo "${@}" | fold -s
                fi
            else
                fold -s
            fi
        }
        function _spaces {
            printf '%*s' $1
        }
        function repeat_char {
            _spaces $2 | tr ' ' "${1}"
        }
        function center_border_text {
            count=$(( $(echo -n "$*" | wc -c) + 4 ))
            stars=$(repeat_char \* $count)
            if [ $count -lt 80 ]; then
                spaces=$(_spaces $(( (80 - count) / 2 )))
            else
                spaces=''
            fi
            echo "$spaces$stars"
            echo "$spaces* ${*} *"
            echo "$spaces$stars"
        }
    fi
fi

function gen_rand {
    < /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c${1:-16}
}
function wait_for {
    cmd="$1"
    timeout=${2:-300}
    step=${3:-5}

    while ! $cmd; do
        (( timeout -= step ))
        if [ $timeout -le 0 ]; then
            return 1
        fi
        sleep $step
    done
}
function pgcluster_deleted {
    [ $(oc get pod -n ansible-tower | grep -F tower-db | wc -l) -eq 0 ] && \
        return 0 || \
        return 1
}
function pgcluster_ready {
    [ $(oc get deploy tower-db -o jsonpath={.status.readyReplicas} -n ansible-tower) -gt 0 ] && \
        return 0 || \
        return 1
}
function print_usage {
    wrap usage: $(basename $0) \
        "[-h|--help] |" \
        "[-r|--remove] |" \
        "[-v|--verbose]" \
        "[-a|--ask-admin-password]" \
        "[-y|--yes]" \
        "[--formatter]"
}
function print_help {
    center_border_text Ansible Tower Installer - OpenShift Helper
    echo
    print_usage
    cat << 'EOF'

    -h|--help                   Display this page and exit.
    -r|--remove                 Removes an Ansible Tower installation that would
                                  have been deployed from this automation.
    -v|--verbose                Enable extremely verbose output.
    -a|--ask-admin-password     Ask for the admin password, instead of
                                  generating a random one.
    -y|--yes                    Don't prompt for confirmation of settings.
    --formatter                 Download the output formatter for this user,
                                  if it is not present, instead of using simpler
                                  output formatting.

NOTE: You must have the oc CLI, the gpg2 client, and curl installed and in your
    PATH. You must be logged into the cluster you intend to install Ansible
    Tower on with the oc client and its current kubeconfig.
EOF
}

REMOVE_TOWER=
ASK_ADMIN_PASSWORD=
CONFIRM_CHOICE=true

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help) print_help ; exit                            ;;
        -r|--remove) REMOVE_TOWER=true                          ;;
        -v|--verbose) true                                      ;;
        -a|--ask-admin-password) ASK_ADMIN_PASSWORD=true        ;;
        -y|--yes) unset CONFIRM_CHOICE                          ;;
        --formatter) true                                       ;;
        *) print_usage >&2 ; exit 1                             ;;
    esac; shift
done

center_border_text Ansible Tower Installer - OpenShift Helper
echo
error_run "Validating login" 'oc whoami'
if [ "$REMOVE_TOWER" ]; then
    warn_run "Removing Ansible Tower deployment" \
        'oc delete deploy/ansible-tower --wait -n ansible-tower' ||:
    warn_run "Removing PostgreSQL database" \
        'oc delete -f pgcluster.yml' ||:
    error_run "Waiting for PostgreSQL database to be removed" \
        'wait_for pgcluster_deleted'

    crunchy_crds=$(oc get crd -l operators.coreos.com/postgresql.ansible-tower="" -o jsonpath='{.items[*] .metadata.name}')

    warn_run "Cleaning up remaining CrunchyData PostgreSQL Operator Resources" \
        'for crunchy_crd in $crunchy_crds; do oc delete $crunchy_crd --all --wait -n ansible-tower; done' ||:
    warn_run "Removing CrunchyData PostgreSQL Operator Subscription" \
        'oc delete --wait -f manifests/01-subscription.yml' ||:
    warn_run "Removing CrunchyData PostgreSQL Operator" \
        'oc delete csv -l operators.coreos.com/postgresql.ansible-tower="" -n ansible-tower' ||:
    warn_run "Removing CrunchyData PostgreSQL Operator CRD's" \
        'for crunchy_crd in $crunchy_crds; do oc delete crd $crunchy_crd --wait; done' ||:
    warn_run "Removing Ansible Tower namespace" \
        'oc delete --wait -f manifests/00-namespace.yml' ||:
    echo
    echo "Ansible Tower should be removed!"
    exit
fi

error_run "Retrieving logged in cluster URL" \
    'export OPENSHIFT_HOST=$(oc whoami --show-server)'
error_run "Retrieving logged in user name" \
    'export OPENSHIFT_USER=$(oc whoami)'
error_run "Retrieving logged in user token" \
    'export OPENSHIFT_TOKEN=$(oc whoami --show-token)'

cd downloaded

if ! gpg --list-keys |& grep -qF AC48AC71DA695CA15F2D39C4B84E339C442667A9; then
    error_run "Receiving Ansible signing key" \
        'gpg --recv-keys AC48AC71DA695CA15F2D39C4B84E339C442667A9'
fi
error_run "Downloading Ansible Tower Setup checksums" \
    'curl -sLO https://releases.ansible.com/ansible-tower/setup_openshift/ansible-tower-setup-CHECKSUM'
error_run "Validating Ansible Tower Setup checksums" \
    'gpg --verify ansible-tower-setup-CHECKSUM'
error_run "Extracting Ansible Tower latest tarball checksum" \
    "ANSIBLE_TOWER_SETUP_SUM=\$(grep 'ansible-tower-openshift-setup-latest.tar.gz$' ansible-tower-setup-CHECKSUM | cut -d' ' -f1)"
if [ "$ASK_ADMIN_PASSWORD" ]; then
    read -sp "Enter the password to use for the Ansible Tower admin account: " ADMIN_PASSWORD
    export ADMIN_PASSWORD
    echo
fi
if [ -z "$ADMIN_PASSWORD" ]; then
    error_run "Creating new random Ansible Tower admin password" \
        'export ADMIN_PASSWORD=$(gen_rand)'
fi

if [ -f ansible-tower-openshift-setup-latest.tar.gz ]; then
    if ! warn_run "Validating existing download checksum" \
        'echo "$ANSIBLE_TOWER_SETUP_SUM  ./ansible-tower-openshift-setup-latest.tar.gz" | sha256sum -c -' ; then
            error_run "Removing old/invalid tarball" \
                'rm -f ansible-tower-openshift-setup-latest.tar.gz'
    fi
fi
if [ ! -f ansible-tower-openshift-setup-latest.tar.gz ]; then
    error_run "Downloading Ansible Tower latest tarball" \
        'curl -sLO https://releases.ansible.com/ansible-tower/setup_openshift/ansible-tower-openshift-setup-latest.tar.gz'
fi
TOWER_INSTALLER_DIR=$(tar tzf ansible-tower-openshift-setup-latest.tar.gz | cut -d/ -f1 | sort -u)
if [ ! -d "$TOWER_INSTALLER_DIR" ]; then
    error_run "Unpacking Ansible Tower latest tarball" \
        'tar xvzf ansible-tower-openshift-setup-latest.tar.gz'
fi
cd "$TOWER_INSTALLER_DIR"
TOWER_INSTALLER_VERSION=$(echo "$TOWER_INSTALLER_DIR" | rev | cut -d- -f1-2 | rev)

if [ "$CONFIRM_CHOICE" ]; then
    echo
    cat << EOF | column -t
OPENSHIFT_HOST $OPENSHIFT_HOST
OPENSHIFT_USER $OPENSHIFT_USER
ANSIBLE_ADMIN_PASSWORD **REDACTED**
ASNIBLE_TOWER_VERSION $TOWER_INSTALLER_VERSION
EOF
    unset CONFIRM_ANSWER
    while : ; do
        read -p "Do you want to continue with this installation? (y/N) " CONFIRM_ANSWER
        if [ "${CONFIRM_ANSWER^^}" = "N" -o -z "$CONFIRM_ANSWER" ]; then
            echo "Aborting installation..." >&2
            exit 0
        elif [ "${CONFIRM_ANSWER^^}" = "Y" ]; then
            break
        else
            echo "Answer not understood: $CONFIRM_ANSWER" >&2
        fi
    done
    echo
fi

error_run "Installing CrunchyData PostgreSQL Operator" \
    'oc apply -Rf ../../manifests'
error_run "Creating PostgreSQL database" \
    'wait_for "oc apply -f ../../pgcluster.yml"'
error_run "Waiting for PostgreSQL database to be ready" \
    'wait_for pgcluster_ready'
error_run "Retrieving Ansible Tower database password" \
    'export TOWER_DB_PASSWORD=$(oc get secret tower-db-tower-secret -o jsonpath={.data.password} -n ansible-tower | base64 -d)'
warn_run "Checking for existing Ansible Tower secret key" \
    'export SECRET_KEY=$(oc get secret ansible-tower-secrets -o jsonpath={.data.secret_key} -n ansible-tower| base64 -d) && [ -n "$SECRET_KEY" ]' ||:
if [ -z "$SECRET_KEY" ]; then
    error_run "Creating new random Ansible Tower secret key" \
        'export SECRET_KEY=$(gen_rand)'
fi
error_run "Writing inventory file for installer" \
    'cat ../../inventory.template | envsubst > inventory'
error_run "Installing Ansible Tower" \
    './setup_openshift.sh -- -v'

echo
wrap "This is the only time this will be output to the screen, so please ensure you have it saved." \
    "Your Ansible Tower admin user's password is: $ADMIN_PASSWORD"
echo
wrap "Installation complete! Your instance is accesible at" \
    "https://$(oc get route ansible-tower-web-svc -o jsonpath={.spec.host})"
