#!/bin/bash

# Installer for Sysdig Agent on IBM Cloud Kubernetes Service (IKS)

set -e

function install_curl_deb {
	export DEBIAN_FRONTEND=noninteractive

	if ! hash curl > /dev/null 2>&1; then
		echo "* Installing curl"
        $CMD_PREF apt-get update
		$CMD_PREF apt-get -qq -y install curl < /dev/null
	fi
}

function install_curl_rpm {
	if ! hash curl > /dev/null 2>&1; then
		echo "* Installing curl"
		$CMD_PREF yum -q -y install curl
	fi
}

function download_yamls {
	echo "* Downloading Sysdig cluster role yaml"
	curl -s -o /tmp/sysdig-agent-clusterrole.yaml https://raw.githubusercontent.com/anhegde2/sysdig/master/agent_deploy/kubernetes/sysdig-agent-clusterrole.yaml
	echo "* Downloading Sysdig config map yaml"
	curl -s -o /tmp/sysdig-agent-configmap.yaml https://raw.githubusercontent.com/anhegde2/sysdig/master/agent_deploy/kubernetes/sysdig-agent-configmap.yaml
	curl -s -o /tmp/sysdig-agent-daemonset-v2.yaml https://raw.githubusercontent.com/anhegde2/sysdig/master/agent_deploy/kubernetes/sysdig-agent-daemonset-v2.yaml
}

function unsupported {
	echo "Unsupported operating system. Try using the the manual installation instructions"
	exit 1	
}

function help {
	echo "Usage: $(basename ${0}) -a | --access_key <value> [-t | --tags <value>] [-c | --collector <value>] \ "
	echo "                [-cp | --collector_port <value>] [-s | --secure <value>] [-cc | --check_certificate] \ "
	echo "                [-ns | --namespace <value>] [-ac | --additional_conf <value>] [-h | --help]"
	echo ""
	echo " -a  : secret access key, as shown in Sysdig Monitor"
	echo " -t  : list of tags for this host (ie. \"role:webserver,location:europe\", \"role:webserver\" or \"webserver\")"
	echo " -c  : collector IP for Sysdig Monitor"
	echo " -cp : collector port [default 6443]"
	echo " -s  : use a secure SSL/TLS connection to send metrics to the collector (default: true)"
	echo " -cc : disable strong SSL certificate check (default: true)"
	echo " -ac : if provided, the additional configuration will be appended to agent configuration file"
	echo " -ns : If provided, will be the namespace used to deploy the agent. Defaults to ibm-observe"
	echo " -h  : print this usage and exit"
	echo
	exit 1
}

function is_valid_value {
	if [[ ${1} == -* ]] || [[ ${1} == --* ]] || [[ -z ${1} ]]; then
		return 1
	else
		return 0
	fi
}

function create_namespace {
    fail=0
    echo "* Creating namespace: $NAMESPACE"
    out=$(kubectl create namespace $NAMESPACE 2>&1) || { fail=1 && echo "kubectl create namespace failed!"; }
    if [ $fail -eq 1 ]; then
        if [[ "$out" =~ "AlreadyExists" ]]; then
            echo "$out. Continuing..."
        else
            echo "$out"
            exit 1
        fi
    fi
}


function create_sysdig_serviceaccount {
    fail=0
    echo "* Creating sysdig-agent serviceaccount in namespace: $NAMESPACE"
    out=$(kubectl create serviceaccount sysdig-agent --namespace=$NAMESPACE 2>&1) || { fail=1 && echo "kubectl create serviceaccount failed!"; }
    if [ $fail -eq 1 ]; then
        if [[ "$out" =~ "AlreadyExists" ]]; then
            echo "$out. Continuing..."
        else
            echo "$out"
            exit 1
        fi
    fi
}

function install_k8s_agent {
    echo "* Creating sysdig-agent clusterrole and binding"
    kubectl apply -f /tmp/sysdig-agent-clusterrole.yaml
    fail=0
    outbinding=$(kubectl create clusterrolebinding sysdig-agent --clusterrole=sysdig-agent --serviceaccount=$NAMESPACE:sysdig-agent --namespace=$NAMESPACE 2>&1) || { fail=1 && echo "kubectl create clusterrolebinding failed!"; }
    if [ $fail -eq 1 ]; then
        if [[ "$outbinding" =~ "AlreadyExists" ]]; then
            echo "$outbinding. Continuing..."
        else
            echo "$outbinding"
            exit 1
        fi
    fi

    echo "* Creating sysdig-agent secret using the ACCESS_KEY provided"
    fail=0
    outsecret=$(kubectl create secret generic sysdig-agent --from-literal=access-key=$ACCESS_KEY --namespace=$NAMESPACE 2>&1) || { fail=1 && echo "kubectl create secret failed!"; }
    if [ $fail -eq 1 ]; then
        if [[ "$outsecret" =~ "AlreadyExists" ]]; then
            echo "$outsecret. Re-creating secret..."
            kubectl delete secrets sysdig-agent --namespace=$NAMESPACE 2>&1
            kubectl create secret generic sysdig-agent --from-literal=access-key=$ACCESS_KEY --namespace=$NAMESPACE 2>&1
        else
            echo "$outsecret"
            exit 1
        fi
    fi

    CONFIG_FILE=/tmp/sysdig-agent-configmap.yaml

    echo "* Retreiving the IKS Cluster ID and Cluster Name"
    IKS_CLUSTER_ID=$(kubectl get cm -n kube-system cluster-info -o yaml | grep ' "cluster_id": ' | cut -d'"' -f4)
    CLUSTER_NAME=$(kubectl config current-context)

    if [ ! -z "$CLUSTER_NAME" ]; then
        echo "* Setting cluster name as $CLUSTER_NAME"
        echo -e "    k8s_cluster_name: $CLUSTER_NAME" >> $CONFIG_FILE
    fi

    if [ ! -z "$IKS_CLUSTER_ID" ]; then
        echo "* Setting ibm.containers-kubernetes.cluster.id $IKS_CLUSTER_ID"
        if [ -z "$TAGS" ]; then
            TAGS="ibm.containers-kubernetes.cluster.id:$IKS_CLUSTER_ID"
        else
            TAGS="$TAGS,ibm.containers-kubernetes.cluster.id:$IKS_CLUSTER_ID"
        fi
    fi

    echo "* Updating agent configmap and applying to cluster"
    if [ ! -z "$TAGS" ]; then
        echo "* Setting tags"
        echo "    tags: $TAGS" >> $CONFIG_FILE
    fi

    if [ ! -z "$COLLECTOR" ]; then
        echo "* Setting collector endpoint"
        echo "    collector: $COLLECTOR" >> $CONFIG_FILE
    fi

    if [ ! -z "$COLLECTOR_PORT" ]; then
        echo "* Setting collector port"
        echo "    collector_port: $COLLECTOR_PORT" >> $CONFIG_FILE
    else
        echo "    collector_port: 6443" >> $CONFIG_FILE
    fi

    if [ ! -z "$SECURE" ]; then
        echo "* Setting connection security"
        echo "    ssl: $SECURE" >> $CONFIG_FILE
    else
        echo "    ssl: true" >> $CONFIG_FILE
    fi

    if [ ! -z "$CHECK_CERT" ]; then
        echo "* Setting SSL certificate check level"
        echo "    ssl_verify_certificate: $CHECK_CERT" >> $CONFIG_FILE
    else
        echo "    ssl_verify_certificate: true" >> $CONFIG_FILE
    fi

    if [ ! -z "$ADDITIONAL_CONF" ]; then
        echo "* Adding additional configuration to dragent.yaml"
        echo -e "    $ADDITIONAL_CONF" >> $CONFIG_FILE
    fi

    sed -i -e "s|# serviceAccount: sysdig-agent|serviceAccount: sysdig-agent|" /tmp/sysdig-agent-daemonset-v2.yaml

    echo -e "    new_k8s: true" >> $CONFIG_FILE
    kubectl apply -f $CONFIG_FILE --namespace=$NAMESPACE

    echo "* Deploying the sysdig agent"
    kubectl apply -f /tmp/sysdig-agent-daemonset-v2.yaml --namespace=$NAMESPACE
}

if [[ ${#} -eq 0 ]]; then
	echo "ERROR: Sysdig Access Key & Collector are mandatory, use -h | --help for $(basename ${0}) Usage"
	exit 1
fi

# Setting the default value for NAMESPACE to be ibm-observe
# Will be over-ridden if the -ns|--namespace flag is provided
NAMESPACE="ibm-observe"

while [[ ${#} > 0 ]]
do
key="${1}"

case ${key} in
    -a|--access_key)
        if is_valid_value "${2}"; then
            ACCESS_KEY="${2}"
        else
            echo "ERROR: no value provided for access_key option, use -h | --help for $(basename ${0}) Usage"
            exit 1
        fi
        shift
        ;;
    -t|--tags)
        if is_valid_value "${2}"; then
            TAGS="${2}"
        else
            echo "ERROR: no value provided for tags option, use -h | --help for $(basename ${0}) Usage"
            exit 1
        fi
        shift
        ;;
    -c|--collector)
        if is_valid_value "${2}"; then
            COLLECTOR="${2}"
        else
            echo "ERROR: no value provided for collector endpoint option, use -h | --help for $(basename ${0}) Usage"
            exit 1
        fi
        shift
        ;;
    -cp|--collector_port)
        if is_valid_value "${2}"; then
            COLLECTOR_PORT="${2}"
        else
            echo "ERROR: no value provided for collector port option, use -h | --help for $(basename ${0}) Usage"
            exit 1
        fi
        shift
        ;;
    -s|--secure)
        if is_valid_value "${2}"; then
            SECURE="${2}"
        else
            echo "ERROR: no value provided for connection security option, use -h | --help for $(basename ${0}) Usage"
            exit 1
        fi
        shift
        ;;
    -cc|--check_certificate)
        if is_valid_value "${2}"; then
            CHECK_CERT="${2}"
        else
            echo "ERROR: no value provided for SSL check certificate option, use -h | --help for $(basename ${0}) Usage"
            exit 1
        fi
        shift
        ;;
    -ns|--namespace)
        if is_valid_value "${2}"; then
            NAMESPACE="${2}"
        else
            echo "ERROR: no value provided for namespace, use -h | --help for $(basename ${0}) Usage"
            exit 1
        fi
        shift
        ;;
    -ac|--additional_conf)
        if is_valid_value "${2}"; then
            ADDITIONAL_CONF="${2}"
        else
            echo "ERROR: no value provided for additional conf option, use -h | --help for $(basename ${0}) Usage"
            exit 1
        fi
        shift
        ;;
    -h|--help)
        help
        exit 1
        ;;
    *)
        echo "ERROR: Invalid option: ${1}, use -h | --help for $(basename ${0}) Usage"
        exit 1
        ;;
esac
shift
done

CMD_PREF=""
if [ $(id -u) != 0 ]; then
    if command -v sudo  > /dev/null 2>&1; then 
        CMD_PREF="sudo "
    else 
        echo "Please install sudo and re-run the script"
        exit 1
    fi
fi

if [ -z $ACCESS_KEY  ]; then
    echo "ERROR: Sysdig Access Key argument is mandatory, use -h | --help for $(basename ${0}) Usage"
	exit 1
fi


if [ -z $COLLECTOR ]; then
    echo "ERROR: Sysdig Collector argument is mandatory, use -h | --help for $(basename ${0}) Usage"
	exit 1
fi

echo "* Detecting operating system"

ARCH=$(uname -m)
PLATFORM=$(uname)
if [[ ! $ARCH = *86 ]] && [ ! $ARCH = "x86_64" ] && [ ! $ARCH = "s390x" ]; then
	unsupported
fi

if [ -f /etc/debian_version ]; then
	if [ -f /etc/lsb-release ]; then
		. /etc/lsb-release
		DISTRO=$DISTRIB_ID
		VERSION=${DISTRIB_RELEASE%%.*}
	else
		DISTRO="Debian"
		VERSION=$(cat /etc/debian_version | cut -d'.' -f1)
	fi

	case "$DISTRO" in

		"Ubuntu")
			if [ $VERSION -ge 10 ]; then
				install_curl_deb
			else
				unsupported
			fi
			;;

		"LinuxMint")
			if [ $VERSION -ge 9 ]; then
				install_curl_deb
			else
				unsupported
			fi
			;;

		"Debian")
			if [ $VERSION -ge 6 ]; then
				install_curl_deb
			elif [[ $VERSION == *sid* ]]; then
				install_curl_deb
			else
				unsupported
			fi
			;;

		*)
			unsupported
			;;

	esac

elif [ -f /etc/system-release-cpe ]; then
	DISTRO=$(cat /etc/system-release-cpe | cut -d':' -f3)

	VERSION=$(cat /etc/system-release-cpe | cut -d':' -f5 | cut -d'.' -f1 | sed 's/[^0-9]*//g')

	case "$DISTRO" in

		"oracle" | "centos" | "redhat")
			if [ $VERSION -ge 6 ]; then
				install_curl_rpm
			else
				unsupported
			fi
			;;

		"fedoraproject")
			if [ $VERSION -ge 13 ]; then
				install_curl_rpm
			else
				unsupported
			fi
			;;

		*)
			unsupported
			;;
	esac

elif [[ $uname -eq "Darwin" ]]; then
    install_curl_deb
else
	unsupported
fi

download_yamls
create_namespace
create_sysdig_serviceaccount
install_k8s_agent
