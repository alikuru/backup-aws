#!/bin/bash

# Set script path
scriptpath="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Import settings from config file
if [[ -f $scriptpath/settings.conf ]]; then

  source $scriptpath/settings.conf

  # Export AWS CLI path
  export PATH=$HOME/.local/bin:$PATH

  # Get date for tagging backups.
  suffix=$(date +"%Y%m%d")

  # Set logging details
  logfile="backup-$(hostname)-$suffix.log"
  exitcodes="exit-codes.log"

  # Mark the date for deleting the database backup taken given number of days before today.
  rotate=$(date +"%Y%m%d" -d "-$mysql_days days")

  # If it doesn't exist, create the directory for storing database dumps as defined in settings.
  if [[ ! -d "$mysql_output" ]]; then
    mkdir -p $mysql_output
  fi

  # Skip databases set to be excluded in the settings.conf file.
  excluded_dbs=( $mysql_exclude )
  function excludeDBs()
  {
    local is_db_excluded="false"
    for xdb in "${excluded_dbs[@]}"
    do
        if [ "$1" == "${xdb}" ]; then
            is_db_excluded="true"
            break
        fi
    done

    echo "$is_db_excluded"
  }

  # Dump all databeses and create arcives.
  databases=`mysql --user=$mysql_user --password=$mysql_password -e "SHOW DATABASES;" | tr -d "| " | grep -v Database`
  echo $? >> $scriptpath/$exitcodes
  for db in $databases; do
    if [[ $(excludeDBs "$db") == "false" ]]; then
      echo -e "========================================\nDumping database: $db\n========================================" >> $scriptpath/$logfile
      mysqldump --force --opt --add-drop-table --log-error=$scriptpath/$logfile --user=$mysql_user --password=$mysql_password --databases $db > $mysql_output/$db.$suffix.sql
      echo $? >> $scriptpath/$exitcodes
      tar cfv $mysql_output/$db.$suffix.sql.tar -C $mysql_output $db.$suffix.sql
      echo $? >> $scriptpath/$exitcodes
      7z a -t7z -m0=lzma -mx=9 -mfb=64 -md=32m -ms=on $mysql_output/$db.$suffix.tar.7z $mysql_output/$db.$suffix.sql.tar >>$scriptpath/$logfile 2>&1
      echo $? >> $scriptpath/$exitcodes
      rm $mysql_output/$db.$rotate.tar.7z
    fi
  done
  rm $mysql_output/*.{sql,tar}

  # Sync all local assets with remote.
  echo -e "========================================\nSynchronizing databases\n========================================" >> $scriptpath/$logfile
  aws s3 sync $mysql_output s3://$s3_bucket_dbs $s3_sync_params >> $scriptpath/$logfile
  echo $? >> $scriptpath/$exitcodes
  echo -e "========================================\nSynchronizing virtual hosts\n========================================" >> $scriptpath/$logfile
  if [[ -z ${s3_sync_exclude+x} ]]; then
    aws s3 sync $root_vhosts s3://$s3_bucket_vhosts $s3_sync_params >> $scriptpath/$logfile
  else
    aws s3 sync $root_vhosts s3://$s3_bucket_vhosts $s3_sync_params --exclude "$s3_sync_exclude" >> $scriptpath/$logfile
  fi
  echo $? >> $scriptpath/$exitcodes

  # Check if any errors happened during creating and synchronizing backups.
  errorcount="$(grep -Ev '(^0|^$)' $scriptpath/$exitcodes|wc -l)"

  # Send the report.
  report=$(openssl enc -base64 -A -in $scriptpath/$logfile)
  if [[ $errorcount -eq 0 ]]; then
    errorstatus="without any errors"
  elif [[ $errorcount -eq 1 ]]; then
    errorstatus="with $errorcount error"
  else
    errorstatus="with $errorcount errors"
  fi

  echo "{\"Data\": \"X-SES-SOURCE-ARN: $mail_header_source_arn\nX-SES-FROM-ARN: $mail_header_from_arn\nX-SES-RETURN-PATH-ARN: $mail_header_return_arn\nFrom: $mail_from\nTo: $mail_to\nReturn-Path: $mail_return\nSubject: Backup completed $errorstatus @ $(date) for $(hostname)\nMIME-Version: 1.0\nContent-type: Multipart/Mixed; boundary="NextPart"\n\n--NextPart\nContent-Type: text/plain; charset=UTF-8\nContent-Transfer-Encoding: 7bit\n\nPlease find job report attached to this email.\n\n--NextPart\nContent-Type: text/plain; charset=UTF-8\nContent-Transfer-Encoding: base64\nContent-Disposition: attachment; filename="$logfile"\n\n$report\n\n--NextPart--\"}" > $scriptpath/mail.json

  aws ses send-raw-email --raw-message file://$scriptpath/mail.json

  # Set trap for cleanup
  function cleanup {
    rm $scriptpath/$logfile $scriptpath/$exitcodes $scriptpath/mail.json
  }
  trap cleanup EXIT

else

  echo "Missing settings.conf file, please refer to README." > error-$(hostname)-$suffix.log
  exit 0

fi
