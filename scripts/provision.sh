#!/bin/sh
#*******************************************************************************
#  Copyright 2013 - 2018 Software AG, Darmstadt, Germany and/or its licensors
#
#   SPDX-License-Identifier: Apache-2.0
#
#     Licensed under the Apache License, Version 2.0 (the "License");
#     you may not use this file except in compliance with the License.
#     You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#     Unless required by applicable law or agreed to in writing, software
#     distributed under the License is distributed on an "AS IS" BASIS,
#     WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#     See the License for the specific language governing permissions and
#     limitations under the License.                                                            
#
#*******************************************************************************
set -e

# configuring CC builder itself?
if [ $CC_HOME == $SAG_HOME ]; then 
    self_provision=1
else
    self_provision=0
fi

if ! cat $CC_HOME/profiles/CCE/configuration/config.ini | grep com.softwareag.platform.management.client.template.composite.skip.restart.runtimes=true ; then
    echo "Configuring Command Central no restart policy ..."
    echo com.softwareag.platform.management.client.template.composite.skip.restart.runtimes=true>>$CC_HOME/profiles/CCE/configuration/config.ini
fi

echo "Starting up Command Central (if not running) ..."
$CC_HOME/profiles/SPM/bin/startup.sh
$CC_HOME/profiles/CCE/bin/startup.sh

echo "Running init.sh ..."
if ! $CC_HOME/init.sh ; then
    echo "ERROR: Initialization failed."
    exit 1
fi



# just in case
export CC_CLI_HOME=$CC_HOME/CommandCentral/client
export PATH=$PATH:$CC_CLI_HOME/bin
export CC_WAIT=${CC_WAIT:-3600}

echo "Waiting for Command Central ..."
sagcc get monitoring runtimestatus local OSGI-CCE-ENGINE -e ONLINE -c 15 --wait-for-cc 300 -w 240
echo "Command Central is READY"


    	




echo "Running inventory.sh ..."
$CC_HOME/inventory.sh

# globals
NODES=${NODES:-node}
REPO_PRODUCT_NAME=${REPO_PRODUCT_NAME:-products}
REPO_FIX_NAME=${REPO_FIX_NAME:-fixes}
RELEASE_MAJOR=${RELEASE_MAJOR:-10}

if [ "$#" != "0" ]; then  
    MAIN_TEMPLATE_ALIAS=${1}
    shift
	echo "Waiting for container initilization.."
	for timer in {1..60}
	do
        if [ -f /tmp/init.status ] && grep -q OK /tmp/init.status
    	then
        	break
    	else
        	echo -n "."
        	sleep 10
    	fi
	done
	if [ "$timer" -eq 60 ]
	then
		echo
        echo "container not initialized"
    	exit 102
	fi    
fi

PARAMS=$*

propfile=~/.env.properties
rm -f $propfile

ADD_PROPERTIES=""
if [ -f env.properties ]; then
    echo "Found env.properties. Resolving envrionment variables ..."
    envsubst<env.properties>$propfile
    ADD_PROPERTIES=" -i $propfile "
else
    echo "WARNING: No env.properties found"
fi

# Extract all environment variables those having the prefix "__" 
# and appends them to the .properties after converting _ to .
env | while IFS='=' read -r name value; do
	if [[ $name == '__'* ]]; then
		# remove "__" from the environment variable name and use the remainder as the key... 
		key=${name:2}
        # after converting the keys to the regular parameter names by replacing  the bash-acceptable "_" with "."
        echo "${key//_/.}=${value}" >> $propfile
        echo "Picked up ENV variable: ${key//_/.}=${value}"
	fi
done

if [ -f $propfile ]; then
    ADD_PROPERTIES=" -i $propfile "
    echo "=================================="
    echo "Resolved template .properties file"
    echo "=================================="
    cat $propfile
    echo "=================================="
else
    echo "WARNING: No environment variables defined! Will use template defaults."
fi

if [ "$MAIN_TEMPLATE_ALIAS" = "sag-spm-boot-ssh" ] || [ "$MAIN_TEMPLATE_ALIAS" = "sag-spm-boot-local" ]; then
    echo "The template will provision the node. SKIP: bootstrapping"
elif [ -f "$SAG_HOME/profiles/SPM/bin/startup.sh" ]; then
    echo "Found managed node in '$SAG_HOME'. SKIP: bootstrapping"
    echo "Starting SPM ..."
    $SAG_HOME/profiles/SPM/bin/startup.sh

    if [ $self_provision -eq 0 ] && [ "$NODES" = "node" ]; then
        echo "Registering managed installation '$NODES' ..."
        sagcc add landscape nodes alias=$NODES url=http://localhost:8092 -e OK
	echo "Waiting for SPM ..."
        sagcc get landscape nodes $NODES -e ONLINE -w 240
    fi



    echo "EXISTING infrastructure $NODES SUCCESSFUL"
else
    echo "NO managed node in '$SAG_HOME' found"

    if [ -z $CC_INSTALLER ]; then
        echo "SKIP: No bootstrapper. Cannot bootstrap '$SAG_HOME'!"
    else
        sagcc_installer="${CC_INSTALLER}.sh"

        if [ -f $CC_HOME/profiles/CCE/data/installers/$sagcc_installer ]; then
            echo "Found '$sagcc_installer'. SKIP: downloading installer."
        else
            echo "Downloading '$sagcc_installer' from '${CC_INSTALLER_URL}' ..."
            mkdir -p $CC_HOME/profiles/CCE/data/installers
            curl -k -L -u Administrator:manage -o $CC_HOME/profiles/CCE/data/installers/$sagcc_installer "${CC_INSTALLER_URL}/${sagcc_installer}"
            chmod +x $CC_HOME/profiles/CCE/data/installers/$sagcc_installer
        fi
        echo "Bootstrapping '$SAG_HOME' using '$sagcc_installer' ..."
        sh $CC_HOME/profiles/CCE/data/installers/$sagcc_installer -D SPM -d $SAG_HOME -H localhost -p manage -s 8092 -S 8093

        echo "Deleting '$sagcc_installer' ..."
        rm -f $CC_HOME/profiles/CCE/data/installers/$sagcc_installer
        
	if [ "$NODES" = "node" ]
	then
		echo "Registering managed installation '$NODES' ..."
		sagcc add landscape nodes alias=$NODES url=http://localhost:8092 -e OK

		echo "Waiting for SPM ..."
		sagcc get landscape nodes $NODES -e ONLINE

		echo "NEW infrastructure $NODES SUCCESSFUL"
	fi
    fi
fi
NODES_LIST=`echo $NODES | tr -d "[]" | tr "," " "`
if [ -n "$NODES_LIST" ] 
then
	echo "Registering additional nodes: $NODES_LIST"
	for NODE_INDEX in  $NODES_LIST
	do
		if [ "$NODE_INDEX" != "node" ] && [ "$NODE_INDEX" != "node-sshd" ] && [ "$NODE_INDEX" != "node-local" ]
		then
			sagcc add landscape nodes alias=$NODE_INDEX url=https://$NODE_INDEX:8093 
		fi
	done
	while sagcc get landscape nodes |grep  -v "^node.*OFFLINE"| grep OFFLINE
	do 
		echo waiting for nodes $NODES_LIST to become available
		sleep 5
	done 
fi



if [ -z $MAIN_TEMPLATE_ALIAS ] ; then 
    if [ -f template.yaml ]; then
        echo "Found template.yaml ..."
        templatefile=template.yaml
        MAIN_TEMPLATE_ALIAS=`awk '/^alias:/{print $NF}' $templatefile`
        echo "Importing template ... $MAIN_TEMPLATE_ALIAS"
        cat $templatefile
        sagcc exec templates composite import -i $templatefile overwrite=true
    else
        echo "ERROR: No template.yaml found nor template alias is provided!"
        exit 1
    fi
fi

# mandatory parameters
ADD_PROPERTIES="${ADD_PROPERTIES} node=$NODES nodes=$NODES repo.product=$REPO_PRODUCT_NAME repo.fix=$REPO_FIX_NAME release.major=$RELEASE_MAJOR os.platform=lnxamd64 $PARAMS "

echo "=================================="
echo "Applying '$MAIN_TEMPLATE_ALIAS' with $ADD_PROPERTIES"
echo "$CC_WAIT seconds timeout"
echo "=================================="

tail -f $CC_HOME/profiles/CCE/logs/default.log $SAG_HOME/profiles/SPM/logs/default.log $SAG_HOME/profiles/SPM/logs/wrapper.log &
tailpid=$!

if sagcc exec templates composite apply $MAIN_TEMPLATE_ALIAS $ADD_PROPERTIES --sync-job -c 10 -e DONE --wait-for-cc 300 --retry 1; then
    echo ""
    echo "PROVISION '$MAIN_TEMPLATE_ALIAS' SUCCESSFUL"
    echo ""
    kill $tailpid>/dev/null
    sleep 3

    echo "Capturing metadata ..."
    NODES_LIST=`echo $NODES | tr -d "[]" | tr "," " "`
    for NODE_INDEX in  $NODES_LIST
    do
	    echo "metadata for node $NODE_INDEX"
	    sagcc list inventory products nodeAlias=$NODE_INDEX properties=product.displayName,product.version.string -o $SAG_HOME/products.txt -f tsv
	    sagcc list inventory products nodeAlias=$NODE_INDEX properties=product.displayName,product.version.string -o $SAG_HOME/products.xml -f xml

	    sagcc list inventory fixes nodeAlias=$NODE_INDEX properties=fix.displayName,fix.version -o $SAG_HOME/fixes.txt -f tsv
	    sagcc list inventory fixes nodeAlias=$NODE_INDEX properties=fix.displayName,fix.version -o $SAG_HOME/fixes.xml -f xml
    done

    echo "Cleaning up ..."
    rm -rf $SAG_HOME/common/conf/nodeId.txt

    # configuring target $SAG_HOME
    if [ $self_provision -eq 0 ]; then
        echo "Adding managed node support ..."
        cp -v $CC_HOME/register.sh $SAG_HOME/
        cp -v $CC_HOME/entrypoint.sh $SAG_HOME/
        mkdir -p $SAG_HOME/CommandCentral/
        cp -vR $CC_HOME/CommandCentral/client/ $SAG_HOME/CommandCentral/
    fi

    echo "Disk usage stats "
    du -h -d 2 $SAG_HOME

else 
    kill $tailpid>/dev/null
    
    echo "LS:"
    ls -lR $SAG_HOME/SAGUpdateManager/UpdateManager/logs
    cat $SAG_HOME/SAGUpdateManager/UpdateManager/logs/info/info*.log
    echo ""
    echo "ERROR: PROVISION '$MAIN_TEMPLATE_ALIAS' FAILED !"
    echo ""
    exit 100
fi
