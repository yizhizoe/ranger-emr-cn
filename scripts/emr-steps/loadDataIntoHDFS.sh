#!/bin/bash
set -euo pipefail
set -x
# Define variables
aws_bucket=$1
installpath=/tmp
hdfs_data_location=$aws_bucket/inputdata
cd $installpath
aws s3 cp $hdfs_data_location/football_coach.tsv .
aws s3 cp $hdfs_data_location/football_coach_position.tsv .
sudo -u hdfs hadoop fs -mkdir -p /user/analyst1
sudo -u hdfs hadoop fs -mkdir -p /user/analyst2
sudo -u hdfs hadoop fs -put -f football_coach.tsv /user/analyst1
sudo -u hdfs hadoop fs -put -f football_coach_position.tsv /user/analyst2
sudo -u hdfs hadoop fs -chown -R analyst1:analyst1 /user/analyst1
sudo -u hdfs hadoop fs -chown -R analyst2:analyst2 /user/analyst2