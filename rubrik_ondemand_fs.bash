#!/bin/sh

####################################################################
#                                                                  #
# SOURCE:                                                          #
#     rubrik_ondemand_fs                                           #
#                                                                  #
# DESCRIPTION:                                                     #
#     Script to perfom an on demand fileset backup in Rubrik       #
#                                                                  #
# PLATFORMS SUPPORTED:                                             #
#     Linux                                                        #
#                                                                  #
# Author:                                                          #
#     Chris Holmes                                                 #
#                                                                  #
# Change log:                                                      #
#     Version 0.1 - Chris Holmes - 30th Nov 2021                   #
#     Version 1.0 - Chris Holmes - 08th Dec 2021                   #
#     Version 2.0 - Chris Holmes - 08th Mar 2022                   #
#                                                                  #
####################################################################



main(){


exitcode="1"								#Exit code intially set to 1 to indicate if script fails to run
fs_id=$1									#ID of the file set to be backed up
paramcount=$#								#Number of parameters passed to the script
sla_id="$2"									#ID of the SLA assigned to the backup
site="$3"									#Location of the Rubrik cluster that is used to store the backups
path=$(dirname "$BASH_SOURCE")				#Gets the location of the running script
path=$(cd "$path" && pwd)					#Changes script location to absolute path
file=$0; file=${file##*/}					#Removes path from script name
conf_file=$path/$file.conf					#Full file path and name for the config file
tempconf_file=$path/temp.conf				#Full file path and name for the temporary config file

#
#############################################################
# Check to see if config file exists                        #
# If so, source variables. If not, ask to create one        #
#############################################################
#
if [ -f $conf_file ]; then
	source $conf_file		#Loads variables from config file
else
	echo "Couldn't find $file.conf file."
	echo "Would you like to run setup to create a new config file? [Y/N]"
	read overwrite_config
	if [[ "$overwrite_config" =~ ([Yy]|[Yy][Ee][Ss]) ]]	; then
		run_setup
		exitcode="0"
		exit $exitcode
	else
		echo "Terminating script: No config file found"
		exitcode="100"
		exit $exitcode
	fi
fi

# If we have no parameters - show usage
if [ $paramcount -eq 0 ]; then
        usage
		exitcode="10"
        exit $exitcode
fi

if [[ "$1" = "-?" || "$1" = "--?" || "$1" = "help" || "$1" = "-help" || "$1" = "HELP" || "$1" = "-HELP" ]]; then
        usage
		exitcode="10"
        exit $exitcode
fi

# If first parameter is "setup" create a new config file
if  [ $1 = setup ]; then 
	if [ -f $conf_file ]; then
		echo "Do you want to create a new config file? Warning: This will erase your current config! [Y/N]"
		read overwrite_config
		if [[ "$overwrite_config" =~ ([Yy]|[Yy][Ee][Ss]) ]]; then
			run_setup
			exitcode="0"
			exit $exitcode
		else
			usage 
			exitcode="10"
			exit $exitcode
		fi
	else
		run_setup
		exitcode="0"
		exit $exitcode
	fi
fi

# If first parameter is "list" then list site numbers and names
if  [ $1 = list ]; then
	while IFS= read -r line
	do
		if [[ $line =~ ^site([0-9]|[0-9][0-9])_name ]]; then
			sitenumber=$(echo "$line" | sed 's/.*site//' | sed 's/_name.*//')
			sitename=$(echo "$line" | sed 's/.*name=//')
			if [[ $sitenumber =~ ([0-9][0-9]) ]]; then
				echo "|$sitenumber | $sitename"
			else
				echo "| $sitenumber | $sitename"
			fi
		fi
	done < "$conf_file"
	exitcode="0"
	exit $exitcode
fi

# Housekeep logs (delete all that are 15 days or more old)  #
find ${logdir}*.log -mtime +15 -print | xargs rm 1>/dev/null 2>&1

# Check site and set siteip
if [[ "$site" =~ ^([0-9]|[0-9][0-9])$ ]]; then
	echo "Site is a number. Loading Config"
	load_site_config
else
	echo "Site is not a number. Laoding config"
	
	
	get_site_number $site
	echo "Getting site number for $3"
	if [[ $sitefound -ne 1 ]] ; then
		echo "The site name you entered has not been found in the config file"
		usage
		exitcode="99"
		exit $exitcode
	fi
fi

if [[ "$site" = "" ]]; then
	echo "You have not entered a valid site number"
	exitcode="70"
	exit $exitcode
fi

# Check to see if an optional refresh time has been specified
if [ $paramcount -eq 4 ]; then
    re='^[0-9]+$'							#Checking to ensure that the refresh time
	if ! [[ $4 =~ $re ]]; then				#is actually a number
		usage
		exitcode="9"
		exit $exitcode		
	fi
	if [ $4 -lt 1 ] || [ $4 -gt 900 ]; then
		usage
		exitcode="9"
		exit $exitcode		
	fi
	update_interval=$4
else
	update_interval=$default_interval
fi

# Populate curl_output with fileset details
curl_output=`curl -k -s -S -X GET "https://$siteip/api/v1/fileset/Fileset%3A%3A%3A$fs_id" -H "accept: application/json" -H "authorization: Basic $authtoken"`


# Get fileset and host details
host_name=`echo "$curl_output"|grep -o '"hostName": *"[^"]*'|grep -o '[^"]*$'`	
fs_name=`echo "$curl_output"|grep -o '"name": *"[^"]*'|grep -o -m1 '[^"]*$'`	


# Build a new log name and write the heading
fs_namenw="$(echo -e "${fs_name}" | tr -d '[:space:]')"							#Remove spaces from the fileset name
logname="${logdir}rbkfs.$host_name.$fs_namenw.`date "+%m%d-%H%M"`.log"			

echolog " "
echolog "`date "+%m-%d-%y %H:%M:%S"`: $file starts at `date "+%H:%M"` on `date "+%d-%h-%Y"`" 
echolog " "
echolog "################################################################################"
echolog " "
echolog "`date "+%m-%d-%y %H:%M:%S"`: The script has been started with the following parameters:"
echolog "Fileset ID: $fs_id"
echolog "SLA ID: $sla_id"
echolog "Site: $sitename"
echolog " "
echolog "`date "+%m-%d-%y %H:%M:%S"`: The site you are attempting to back up to is $sitename ($siteip)"
echolog " "
chmod 744 $logname


# Report the log name to standard output
echo " "
echo "***************************"
echo "Log will be named $logname"
echo "***************************"


# Check correct site has been selected to ensure that we don't try to back up 
# to the wrong cluster. This prevents issues with replicated backups.
echolog "`date "+%m-%d-%y %H:%M:%S"`: Checking that the correct site has been selected"
echolog " "
clust_id=`echo "$curl_output"|grep -o '"primaryClusterId": *"[^"]*'|grep -o '[^"]*$'`	
if [[ $clust_id != $site_clust_id ]]; then
	echolog "`date "+%m-%d-%y %H:%M:%S"`: ERROR: It appears that you are trying to run this backup to the wrong Rubrik instance. Please ensure that you are using the correct site number."
	echolog " "
	exitcode="5"
	exit $exitcode
else
	echolog "`date "+%m-%d-%y %H:%M:%S"`: The correct site appears to have been selected for this backup"
	echolog " "
fi

# Get SLA name
sla_name=`curl -k -s -S -X GET "https://$siteip/api/v1/sla_domain/$sla_id" -H "accept: application/json" -H "authorization: Basic $authtoken"|grep -o '"name": *"[^"]*'|grep -o '[^"]*$'`	


# Run the backup and record the ID for the job
echolog "`date "+%m-%d-%y %H:%M:%S"`: Taking backup of the fileset named \"$fs_name\" on host \"$host_name\" using SLA Domain called \"$sla_name.\""
jobid=`curl -k -s -S -X POST "https://$siteip/api/v1/fileset/Fileset%3A%3A%3A$fs_id/snapshot" -H "accept: application/json" -H "authorization: Basic $authtoken" -H "Content-Type: application/json" -d "{ \"slaId\": \"$sla_id\"}"|grep -o '"id": *"[^"]*'|grep -o '[^"]*$'`
echolog "`date "+%m-%d-%y %H:%M:%S"`: The backup command has been issued to the Rubrik Cluster at $sitename. Progress can be checked on the Rubrik GUI :" 
echolog "`date "+%m-%d-%y %H:%M:%S"`: https://$siteip/web/bin/index.html#/object_details/fileset/Fileset:::$fs_id" 
echolog " "
echolog " "
sleep 1

# Check the status of the job
status=`curl -k -s -S -X GET "https://$siteip/api/v1/fileset/request/$jobid" -H "accept: application/json" -H "authorization: Basic $authtoken"|grep -o '"status": *"[^"]*'|grep -o '[^"]*$'`
echo "The status will be checked every $update_interval seconds"
while [ "$status" != "SUCCEEDED" ] && [ "$status" != "FAILED" ]; do
        echo "`date "+%m-%d-%y %H:%M:%S"`: Backup is currently running with a status of $status. Sleeping for $update_interval seconds." 
        sleep $update_interval
		status=`curl -k -s -S -X GET "https://$siteip/api/v1/fileset/request/$jobid" -H "accept: application/json" -H "authorization: Basic $authtoken"|grep -o '"status": *"[^"]*'|grep -o '[^"]*$'`
done
echolog " "
echolog " "

if [[ "$status" == "SUCCEEDED" ]]; then
    exitcode="0"
else
	errorreport=`curl -k -s -S -X GET "https://$siteip/api/v1/fileset/request/$jobid" -H "accept: application/json" -H "authorization: Basic $authtoken"`
	errormessage=$(echo "$errorreport" | sed 's/.*message\\":\\"//' | sed 's/\\".*//')
	errorcause=$(echo "$errorreport" | sed 's/.*reason\\":\\"//' | sed 's/\\".*//')
	errorremedy=$(echo "$errorreport" | sed 's/.*remedy\\":\\"//' | sed 's/\\".*//')
	echolog "`date "+%m-%d-%y %H:%M:%S"`: The backup failed with the following error:" 
	echolog "`date "+%m-%d-%y %H:%M:%S"`: $errormessage" 
	echolog " "
	echolog "`date "+%m-%d-%y %H:%M:%S"`: The cause is as follows:" 
	echolog "`date "+%m-%d-%y %H:%M:%S"`: $errorcause" 
	echolog " "
	echolog "`date "+%m-%d-%y %H:%M:%S"`: To resolve the error:" 
	echolog "`date "+%m-%d-%y %H:%M:%S"`: $errorremedy" 
	echolog " "
    exitcode="2"
fi
echolog "`date "+%m-%d-%y %H:%M:%S"`: Backup completed with a status of $status" 
echolog " "

echolog "`date "+%m-%d-%y %H:%M:%S"`: Job completed with exit code $exitcode"
exit $exitcode
}

#
###########################################
# All functions go below here             #
###########################################
#

# Usage Function to be called if the script is not run correctly
usage() {

	echo " "
	echo "    Usage - $file [Fileset ID] [SLA ID] [Site] [Refresh Interval]"
	echo " "
	echo "    The Fileset ID and SLA ID can both be found in"
	echo "        the Rubrik GUI"
	echo "    The Site should be a number from 1-99 or the Rubrik cluster name"
	echo "	  Use $file list to list the sites"
	echo "    The Refresh Interval is optional but should be between 1 and 900 seconds"
	echo "    If no interval is specified then it will default to the value specified"
	echo "    in the config file."
        
}

# Used to write to config files
write_conf () {
	echo "$@" >> $conf_file
}
write_tempconf () {
	echo "$@" >> $tempconf_file
}

# Log output to both screen logfile
echolog () {
	echo "$@"
	echo "$@" >> "${logname}"
}

# Create config file
run_setup() {
	echo "*********************************************************************************************************"
	echo "* Before you continue you will require the following details:                                           *"
	echo "* - Username and password for an account that has permissions to run backups                            *"
	echo "* - Name, IP Address and Cluster ID of your Rubrik Cluster                                              *"
	echo "* - Name, IP Address and Cluster ID of your second Rubrik Cluster if you have one                       *"
	echo "* - The location where logs should be stored                                                            *"
	echo "* - The default refresh interval that you want between status updates when a backup is in progress      *"
	echo "*********************************************************************************************************"
	read -rsp $'Press any key to continue...\n' -n1 key
	
	truncate -s 0 $tempconf_file
	echo "How many Rubrik clusters do you have?"
	read no_of_sites
	echo ""
	
	i="1"
	while [[ i -le $no_of_sites ]]; do
		get_details $i
		confirm_site_details $i
		i="$[$i+1]"
	done
		
	get_logdir
	get_defaultinterval
	confirm_settings
	
}

# Called by run_setup to get site details
get_details() {
	site_number=$1
	echo "Collecting configuration data for site number $site_number"
	get_site_details $site_number
}

# Called by get_details to get site details (consider merging these two functions)
get_site_details() {
	curl_output=""
	while [[ "$curl_output" =~ (Incorrect username) || ! "$curl_output" ]]; do
		if [[ "$1" -eq "2" ]]; then
			echo ""
			echo "Do you want to use the same username and password for all sites? [Y/N]"
			read sameuser
			if [[ "$sameuser" =~ ([Yy]|[Yy][Ee][Ss]) ]]; then
				skipuser=1
			fi
		fi
		if [[ ! "$skipuser" = 1 ]]; then
			echo "Enter username for Rubrik cluster number $site_number:"
			read username
			echo "Enter password"
			read -s password
			temp_authtoken=`echo -n $username:$password | openssl enc -base64`
		fi
		echo ""
		echo "Enter IP address of the $1 Rubrik Cluster"
		read temp_ip
		while [[ ! "$temp_ip" =~ ^(([1-9]?[0-9]|1[0-9][0-9]|2([0-4][0-9]|5[0-5]))\.){3}([1-9]?[0-9]|1[0-9][0-9]|2([0-4][0-9]|5[0-5]))$ ]] #Checks to make sure the IP is valid
		do
			echo "Enter a valid IP"
			read temp_ip
		done
		curl_output=`curl -k -s -X GET "https://$temp_ip/api/v1/cluster/me" -H "accept: application/json" -H "authorization: Basic $temp_authtoken"`
		if [[ "$curl_output" =~ (Incorrect username) || ! "$curl_output" ]]; then
			echo "There was an issue with the details you entered. Please check your username, password and IP address and try again"
		fi
	echo ""
	done
	declare site$1_authtoken="$temp_authtoken"; siteauth=site$1_authtoken
	declare site$1_ip="$temp_ip"; siteip=site$1_ip
	write_tempconf "site$1_authtoken=${!siteauth}" 
	write_tempconf "site$1_ip=${!siteip}"
}

# Confirm details of site are correct before saving to temp config file
confirm_site_details() {
	temp_clust_id=`echo "$curl_output"|grep -o '"id": *"[^"]*'|grep -o '[^"]*$'`
	temp_clust_name=`echo "$curl_output"|grep -o '"name": *"[^"]*'|grep -o '[^"]*$'`
	declare site$1_name="$temp_clust_name"; sitename=site$1_name
	declare site$1_clustid="$temp_clust_id"; siteclustid=site$1_clustid 
	write_tempconf "site$1_name=${!sitename}" 
	write_tempconf "site$1_clustid=${!siteclustid}"
	write_tempconf ""
	echo "This IP belongs to the cluster called $temp_clust_name with the Cluster ID $temp_clust_id"
	echo "Are these details correct? [Y/N]"
	read confirmation
	if [[ "$confirmation" =~ ([Yy]|[Yy][Ee][Ss]) ]]; then
		echo "Details for this cluster have been saved"
	else 	
		get_details $1
	fi
}

# Sets the site parameters for the backup
load_site_config() {
	sitename="site${site}_name"; sitename="${!sitename}"
    siteip="site${site}_ip"; siteip="${!siteip}"
    authtoken="site${site}_authtoken"; authtoken="${!authtoken}" 
	site_clust_id="site${site}_clustid"; site_clust_id="${!site_clust_id}"
}

# Ask for log directory for setup
get_logdir() {
	echo ""
	echo "Where do you want your log files to be written to?"
	read logdir
	if [[ ! "$logdir" =~ (\/)$ ]]; then     #Check for a trailing slash
		logdir="$logdir/"   				#Adding a trailing slash
		echo "logs will be written to $logdir"
	fi
	write_tempconf "logdir=$logdir"
}

# Get the site number from config gile when a sitename is used instead
get_site_number() {
	while IFS= read -r line
	do
		if [[ $line =~ ^site([0-9]|[0-9][0-9])_name ]]; then
			sitenumber=$(echo "$line" | sed 's/.*site//' | sed 's/_name.*//')
			sitename=$(echo "$line" | sed 's/.*name=//')
			if [[ "$site" =~ "$sitename" ]]; then
				echo "Sitename found in config file. $sitename is site number $sitenumber"
				site="$sitenumber"
				sitefound="1"
				load_site_config
				return
			fi
		fi
	done < "$conf_file"
}

# Get the default refresh interval for setup
get_defaultinterval() {
	echo ""
	echo "Enter your default refresh interval in seconds"
	read default_interval
    re='^([0-9]+)$'								#Checking to ensure that the refresh time
	if ! [[ $default_interval =~ $re ]]; then 	#is actually a number
		echo "The default interval must be a number between 0 and 900"
		get_defaultinterval		
	fi
	if [[ "$default_interval" -lt 1  ||  "$default_interval" -gt 900 ]]; then
		echo "The default interval must be a number between 0 and 900"
		get_defaultinterval		
	fi
	write_tempconf "default_interval=$default_interval"
}

# Confirm settings are correct before commiting to the main config file
confirm_settings() {
	echo ""
	echo "Here is your config file:"
	echo ""
	echo "$(cat $tempconf_file)"

	echo "Are you happy with these settings? [Y/N/C]"
	echo "Y: Save settings, N: Restart setup, C: Cancel without saving"
	read confirmation
	if [[ "$confirmation" =~ ([Yy]|[Yy][Ee][Ss]) ]]; then 
		mv $tempconf_file $conf_file
	elif [[ "$confirmation" =~ ([Nn]|[Nn][Oo]) ]]; then
		echo "Restarting setup"
		echo ""
		run_setup
	elif [[ "$confirmation" =~ ([Cc]|[Cc][Aa][Nn][Cc][Ee][Ll]) ]]; then
		rm $tempconf_file
		echo "Your changes have not been saved."
		exitcode="50"
		exit $exitcode
	else
		echo "Invalid Input. Please enter Y, N or C"
		confirm_settings
	fi
}

main $@
