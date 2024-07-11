#!/bin/bash -ix
#
#
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
#

#source the AWS ParallelCluster profile
. /etc/parallelcluster/cfnconfig

monitoring_dir_name=aws-parallelcluster-monitoring
monitoring_home="/home/${cfn_cluster_user}/${monitoring_dir_name}"
script_bucket=$(dirname $(grep Script /opt/parallelcluster/shared/cluster-config.yaml | head -1 | awk -F's3://' '{print $2}'))

#install podman
aws s3 cp --recursive s3://${script_bucket}/s3-artifacts/podman-compose podman-compose --region $cfn_region
aws s3 cp --recursive s3://${script_bucket}/s3-artifacts/container-tools container-tools --region $cfn_region
yum --disablerepo="*" -y install container-tools/*
yum --disablerepo="*" -y install podman-compose/*

echo "$> variable monitoring_dir_name -> ${monitoring_dir_name}"
echo "$> variable monitoring_home -> ${monitoring_home}"

# Retrieve metadata token
TOKEN=`curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"`


case "${cfn_node_type}" in
	HeadNode)

		cfn_fsx_lustre_id=$(grep lustre /etc/fstab | cut -d. -f1)
		master_instance_id=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/instance-id)
		cfn_max_queue_size=$(aws cloudformation describe-stacks --stack-name $stack_name --region $cfn_region | jq -r '.Stacks[0].Parameters | map(select(.ParameterKey == "MaxSize"))[0].ParameterValue')
		s3_bucket=$(echo $cfn_postinstall | sed "s/s3:\/\///g;s/\/.*//")
		cluster_s3_bucket=$(cat /etc/chef/dna.json | grep \"cluster_s3_bucket\" | awk '{print $2}' | sed "s/\",//g;s/\"//g")
		cluster_config_s3_key=$(cat /etc/chef/dna.json | grep \"cluster_config_s3_key\" | awk '{print $2}' | sed "s/\",//g;s/\"//g")
		cluster_config_version=$(cat /etc/chef/dna.json | grep \"cluster_config_version\" | awk '{print $2}' | sed "s/\",//g;s/\"//g")
		log_group_names="$(aws cloudformation describe-stack-resource --stack-name ${stack_name} --logical-resource-id CloudWatchLogGroup --region $cfn_region --query StackResourceDetail.PhysicalResourceId --output text)"

		aws s3api get-object --bucket $cluster_s3_bucket --key $cluster_config_s3_key --region $cfn_region --version-id $cluster_config_version ${monitoring_home}/parallelcluster-setup/cluster-config.json

		aws s3 cp --recursive s3://${script_bucket}/s3-artifacts/golang/ golang --region $cfn_region
		aws s3 cp --recursive s3://${script_bucket}/s3-artifacts/python3-setuptools/ python3-setuptools --region $cfn_region
		yum --disablerepo="*" -y install golang/*
		yum --disablerepo="*" -y install python3-setuptools/*

		chown $cfn_cluster_user:$cfn_cluster_user -R /home/$cfn_cluster_user
		chmod +x ${monitoring_home}/custom-metrics/*

		cp -rp ${monitoring_home}/custom-metrics/* /usr/local/bin/
		mv ${monitoring_home}/prometheus-slurm-exporter/slurm_exporter.service /etc/systemd/system/
		
		# Download Podman images for compute nodes
		aws s3 cp s3://${script_bucket}/s3-artifacts/node-exporter.tar /opt/parallelcluster/shared/node-exporter.tar --region $cfn_region
		#aws s3 cp s3://${script_bucket}/s3-artifacts/dcgm-exporter.tar /opt/parallelcluster/shared/dcgm-exporter.tar --region $cfn_region
		
		# Download Podman images for Head nodes
		aws s3 cp s3://${script_bucket}/s3-artifacts/pushgateway.tar /opt/parallelcluster/shared/pushgateway.tar --region $cfn_region

		podman load < /opt/parallelcluster/shared/pushgateway.tar
		podman load < /opt/parallelcluster/shared/node-exporter.tar

		/usr/bin/podman-compose --env-file /etc/parallelcluster/cfnconfig -f ${monitoring_home}/docker-compose/docker-compose.head.yml -p monitoring-master up -d

		# Download and build prometheus-slurm-exporter
		##### Plese note this software package is under GPLv3 License #####
		# More info here: https://github.com/vpenso/prometheus-slurm-exporter/blob/master/LICENSE
		cd ${monitoring_home}
		cd prometheus-slurm-exporter
                sed -i 's/NodeList,AllocMem,Memory,CPUsState,StateLong/NodeList: ,AllocMem: ,Memory: ,CPUsState: ,StateLong:/' node.go
		aws s3 cp --recursive s3://${script_bucket}/s3-artifacts/go-modules-cache /root/go-modules-cache --region $cfn_region
		GOPATH=/root/go-modules-cache HOME=/root go build
		mv ${monitoring_home}/prometheus-slurm-exporter/prometheus-slurm-exporter /usr/bin/prometheus-slurm-exporter

		systemctl daemon-reload
		systemctl enable slurm_exporter
		systemctl start slurm_exporter

                # create job tagging script for cronjob
                cat <<CHECKTAGS_EOF > /opt/slurm/sbin/check_tags.sh
#!/bin/bash
source /etc/profile

update=0
tag_userid=""
tag_jobid=""

if [ ! -f /tmp/jobs/jobs_users ] || [ ! -f /tmp/jobs/jobs_ids ]; then
  exit 0
fi

active_users=\$(cat /tmp/jobs/jobs_users | sort | uniq )
active_jobs=\$(cat /tmp/jobs/jobs_ids | sort )
echo \$active_users > /tmp/jobs/tmp_jobs_users
echo \$active_jobs > /tmp/jobs/tmp_jobs_ids

if [ ! -f /tmp/jobs/tag_userid ] || [ ! -f /tmp/jobs/tag_jobid ]; then
  echo \$active_users > /tmp/jobs/tag_userid
  echo \$active_jobs > /tmp/jobs/tag_jobid
  update=1
else
  active_users=\$(cat /tmp/jobs/tmp_jobs_users)
  active_jobs=\$(cat /tmp/jobs/tmp_jobs_ids)
  tag_userid=\$(cat /tmp/jobs/tag_userid)
  tag_jobid=\$(cat /tmp/jobs/tag_jobid)
  
  if [ "\$active_users" != "\$tag_userid" ]; then
    tag_userid="\$active_users"
    echo \$tag_userid > /tmp/jobs/tag_userid
    update=1
  fi
  
  if [ "\$active_jobs" != "\$tag_jobid" ]; then
    tag_jobid="\$active_jobs"
    echo \$tag_jobid > /tmp/jobs/tag_jobid
    update=1
  fi
fi

if [ \$update -eq 1 ]; then
  # Instance ID
	TOKEN=\$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
  MyInstID=\$(curl -H "X-aws-ec2-metadata-token: \$TOKEN" -s http://169.254.169.254/latest/meta-data/instance-id)
  tag_userid=\$(cat /tmp/jobs/tag_userid)
  tag_jobid=\$(cat /tmp/jobs/tag_jobid)
  aws ec2 create-tags --resources \$MyInstID --tags Key=UserID,Value="\$tag_userid" --region=$cfn_region
  aws ec2 create-tags --resources \$MyInstID --tags Key=JobID,Value="\$tag_jobid" --region=$cfn_region
  
fi
CHECKTAGS_EOF
                chmod +x /opt/slurm/sbin/check_tags.sh
                # Create prolog and epilog to tag the instances
                cat << PROLOG_EOF > /opt/slurm/sbin/prolog.sh
#!/bin/bash
[ ! -d "/tmp/jobs" ] && mkdir -p /tmp/jobs
echo "\$SLURM_JOB_USER" >> /tmp/jobs/jobs_users
echo "\$SLURM_JOBID" >> /tmp/jobs/jobs_ids
PROLOG_EOF

                cat << EPILOG_EOF > /opt/slurm/sbin/epilog.sh
#!/bin/bash
sed -i "0,/\$SLURM_JOB_USER/d" /tmp/jobs/jobs_users
sed -i "0,/\$SLURM_JOBID/d" /tmp/jobs/jobs_ids
EPILOG_EOF

                chmod +x /opt/slurm/sbin/prolog.sh /opt/slurm/sbin/epilog.sh

                #Configure slurm to use Prolog and Epilog
                echo "PrologFlags=Alloc" >> /opt/slurm/etc/slurm.conf
                echo "Prolog=/opt/slurm/sbin/prolog.sh" >> /opt/slurm/etc/slurm.conf
                echo "Epilog=/opt/slurm/sbin/epilog.sh" >> /opt/slurm/etc/slurm.conf
                sudo systemctl restart slurmctld
	;;

	ComputeFleet)
		compute_instance_type=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/instance-type)
		gpu_instances="[pg][2-9].*\.[0-9]*[x]*large"
		echo "$> Compute Instances Type EC2 -> ${compute_instance_type}"
		echo "$> GPUS Instances EC2 -> ${gpu_instances}"
                podman load < /opt/parallelcluster/shared/node-exporter.tar
		if [[ $compute_instance_type =~ $gpu_instances ]]; then
			#aws s3 cp --recursive s3://${script_bucket}/s3-artifacts/nvidia-container-toolkit nvidia-container-toolkit --region $cfn_region
			#yum --disablerepo="*" install -y nvidia-container-toolkit/*
			#sudo nvidia-ctk runtime configure --runtime=podman
			#sudo systemctl restart podman
			#podman load < /opt/parallelcluster/shared/dcgm-exporter.tar
			/usr/bin/podman-compose -f /home/${cfn_cluster_user}/${monitoring_dir_name}/docker-compose/docker-compose.compute.gpu.yml -p monitoring-compute up -d
        else
			/usr/bin/podman-compose -f /home/${cfn_cluster_user}/${monitoring_dir_name}/docker-compose/docker-compose.compute.yml -p monitoring-compute up -d
        fi
        # install job tagging
        mkdir /tmp/jobs
        (crontab -l 2>/dev/null; echo "* * * * * /opt/slurm/sbin/check_tags.sh") | crontab -
	;;
esac

echo "done"