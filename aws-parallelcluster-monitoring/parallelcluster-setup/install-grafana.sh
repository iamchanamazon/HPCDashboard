#!/bin/bash -ix

monitoring_dir_name=aws-parallelcluster-monitoring
script_bucket=multipcluster
cfn_cluster_user=ec2-user
cfn_region=`curl -s http:/169.254.169.254/latest/dynamic/instance-identity/document | grep region | awk -F'"' '{print $4}'`
monitoring_home=/home/${cfn_cluster_user}/${monitoring_dir_name}
TOKEN=`curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"`

echo -e monitoring_dir_name=aws-parallelcluster-monitoring > envfile
echo -e script_bucket=multipcluster >> envfile
echo -e cfn_cluster_user=$(whoami) >> envfile
echo -e cfn_region=`curl -s http:/169.254.169.254/latest/dynamic/instance-identity/document | grep region | awk -F'"' '{print $4}'` >> envfile
echo -e monitoring_home=/home/${cfn_cluster_user}/${monitoring_dir_name} >> envfile


/usr/local/bin/aws s3 cp --recursive s3://${script_bucket}/s3-artifacts/container-tools container-tools --region $cfn_region
/usr/local/bin/aws s3 cp --recursive s3://${script_bucket}/s3-artifacts/podman-compose podman-compose --region $cfn_region
/usr/local/bin/aws s3 cp --recursive s3://${script_bucket}/aws-parallelcluster-monitoring aws-parallelcluster-monitoring --region $cfn_region

yum --disablerepo="*" -y install container-tools/*
yum --disablerepo="*" -y install podman-compose/*

#Generate selfsigned certificate for Nginx over ssl
nginx_dir="${monitoring_home}/nginx"
nginx_ssl_dir="${nginx_dir}/ssl"
mkdir -p ${nginx_ssl_dir}
echo -e "\nDNS.1=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/local-hostname)" >> "${nginx_dir}/openssl.cnf"
openssl req -new -x509 -nodes -newkey rsa:4096 -days 3650 -keyout "${nginx_ssl_dir}/nginx.key" -out "${nginx_ssl_dir}/nginx.crt" -config "${nginx_dir}/openssl.cnf"


#give $cfn_cluster_user ownership
chown -R $cfn_cluster_user:$cfn_cluster_user "${nginx_ssl_dir}/nginx.key"
chown -R $cfn_cluster_user:$cfn_cluster_user "${nginx_ssl_dir}/nginx.crt"

# get the tar files
/usr/local/bin/aws s3 cp s3://${script_bucket}/s3-artifacts/prometheus.tar s3-artifacts/prometheus.tar --region $cfn_region
/usr/local/bin/aws s3 cp s3://${script_bucket}/s3-artifacts/grafana.tar s3-artifacts/grafana.tar --region $cfn_region
/usr/local/bin/aws s3 cp s3://${script_bucket}/s3-artifacts/nginx.tar s3-artifacts/nginx.tar --region	$cfn_region
/usr/local/bin/aws s3 cp s3://${script_bucket}/s3-artifacts/pushgateway.tar s3-artifacts/pushgateway.tar --region	$cfn_region
/usr/local/bin/aws s3 cp s3://${script_bucket}/s3-artifacts/mimir.tar s3-artifacts/mimir.tar --region $cfn_region

sudo podman load < s3-artifacts/prometheus.tar
sudo podman load < s3-artifacts/grafana.tar
sudo podman load < s3-artifacts/nginx.tar
sudo podman load < s3-artifacts/pushgateway.tar
sudo podman load < s3-artifacts/mimir.tar

# replace tokens for docker file

sed -i "s/__MONITORING_DIR__/${monitoring_dir_name}/g"  ${monitoring_home}/docker-compose/docker-compose.dashboard.yml
sed -i "s/__DASHBOARD_USER__/${cfn_cluster_user}/g"  ${monitoring_home}/docker-compose/docker-compose.dashboard.yml

# replace tokens for dashboard

sed -i "s/us-east-1/$cfn_region/g"                          ${monitoring_home}/prometheus/prometheus.yml
sed -i "s/__Application__/${stack_name}/g"          	${monitoring_home}/prometheus/prometheus.yml

/usr/bin/podman-compose --env-file envfile -f ${monitoring_home}/docker-compose/docker-compose.dashboard.yml -p monitoring-master up -d