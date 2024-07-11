# pcluster-monitoring-dashboard



## Summary

AWS Parallel Cluster creates and manages dynamic HPC clusters by using the open source job scheduler SLURM. While it enables CloudWatch for system metrics and logs, it lacks a monitoring dashboard for the workload. The Parallel Cluster monitoring dashboard (https://github.com/aws-samples/aws-parallelcluster-monitoring) provides job scheduler insights as well as detailed monitoring metrics in the OS level. With these metrics, cluster users and administrators can better understand the HPC workload and performance.

However, the solution is not updated for the latest version of Parallel Cluster and open source packages used in solution. This pattern brings the following enhancements to the solution:

Support of Parallel Cluster v3

Refresh of the open source software in the solution, including Prometheus, Grafana, Prometheus SLURM exporter, NVIDIA dcgm-exporter for GPU monitoring, etc.

Number of used CPU cores and GPUs by SLURM jobs

Job monitoring dashboard

GPU node monitoring dashboard enhancements for node with 4 or 8 GPUs

The solution has been implemented and verified in a customer HPC environment.

All scripts in this pattern are for Ubuntu 20. Amazon Linux or CentOS will need some small changes in these scripts. It might also require some small modifications for other versions of Ubuntu.

Product versions: RHEL8, ParallelCluster 3.x

## Components
This project is build with the following components:

* **Grafana** is an [open-source](https://github.com/grafana/grafana) platform for monitoring and observability. Grafana allows you to query, visualize, alert on and understand your metrics as well as create, explore, and share dashboards fostering a data driven culture. 
* **Prometheus** [open-source](https://github.com/prometheus/prometheus/) project for systems and service monitoring from the [Cloud Native Computing Foundation](https://cncf.io/). It collects metrics from configured targets at given intervals, evaluates rule expressions, displays the results, and can trigger alerts if some condition is observed to be true.  
* The **Prometheus Pushgateway** is on [open-source](https://github.com/prometheus/pushgateway/) tool that allows ephemeral and batch jobs to expose their metrics to Prometheus.
* **[Nginx](http://nginx.org/)** is an HTTP and reverse proxy server, a mail proxy server, and a generic TCP/UDP proxy server.
* **[Prometheus-Slurm-Exporter](https://github.com/vpenso/prometheus-slurm-exporter/)** is a Prometheus collector and exporter for metrics extracted from the [Slurm](https://slurm.schedmd.com/overview.html) resource scheduling system.
* **[Node_exporter](https://github.com/prometheus/node_exporter)** is a Prometheus exporter for hardware and OS metrics exposed by \*NIX kernels, written in Go with pluggable metric collectors.

Note: *while almost all components are under the Apache2 license, only **[Prometheus-Slurm-Exporter is licensed under GPLv3](https://github.com/vpenso/prometheus-slurm-exporter/blob/master/LICENSE)**, you need to be aware of it and accept the license terms before proceeding and installing this component.*


Link for the deployment steps: [https://docs.aws.amazon.com/prescriptive-guidance/latest/patterns/set-up-a-grafana-monitoring-dashboard-for-aws-parallelcluster.html](https://docs.aws.amazon.com/prescriptive-guidance/latest/patterns/set-up-a-grafana-monitoring-dashboard-for-aws-parallelcluster.html)

______________________________________________________________________________

1. Configure an additional security group for the head node.

    Create a security group for the head node. This security group will allow inbound traffic from the monitoring dashboards/Prometheus instance to the head node. For instructions, see Create a security group in the Amazon VPC documentation.

    Add an inbound rule to the security group. For instructions, see Add rules to a security group in the Amazon VPC documentation. Use the following parameters for the Inbound rule:

        Type – HTTPS
        Protocol – TCP
        Port range – ALL (Or if you want to make more secure on ports: 8080, 9100, 9400)
        Source – ACCOUNDID / SECURITGROUPID **Note** This accountId and SecurityGroupId should belong to the Prometheus account
        Description – Allow traffic to flow from HPC headnodes to Prometheus

2. Configure an additional security group for the Compute node.
    Create a security group for the head node. This security group will allow inbound traffic from the monitoring dashboards/Prometheus instance to the head node. For instructions, see Create a security group in the Amazon VPC documentation.

    Add an inbound rule to the security group. For instructions, see Add rules to a security group in the Amazon VPC documentation. Use the following parameters for the Inbound rule:

        Type – HTTPS
        Protocol – TCP
        Port range – ALL (Or if you want to make more secure on ports: 8080, 9100, 9400)
        Source – ACCOUNDID / SECURITGROUPID **Note** This accountId and SecurityGroupId should belong to the Prometheus account
        Description – Allow traffic to flow from HPC headnodes to Prometheus

3. (Optional on Partitions that allow billing) Create an identity-based policy for the HEAD-NODE. This policy allows the node to retrieve metric data from Amazon Cloudwatch. 
```json
  {
      "Version": "2012-10-17",
      "Statement": [
          {
              "Effect": "Allow",
              "Action": "cloudwatch:GetMetricData",
              "Resource": "*"
          },
          {
              "Effect": "Allow",
              "Action": "pricing:GetProducts",
              "Resource": "*"
          },
          {
              "Effect": "Allow",
              "Action": "pricing:DescribeServices",
              "Resource": "*"
          },
          {
              "Effect": "Allow",
              "Action": "pricing:GetAttributeValues",
              "Resource": "*"
          },
          {
              "Effect": "Allow",
              "Action": "fsx:DescribeFileSystems",
              "Resource": "*"
          }
      ]
  }
```

4. Create an identity-based policy for the COMPUTE-NODES. This policy allows the node to create the tags that contain the job ID running:
```json
    {
      "Version": "2012-10-17",
      "Statement": [
          {
              "Effect": "Allow",
              "Action": "ec2:CreateTags",
              "Resource": "arn:aws:ec2:<REGION>:<ACCOUNT_ID>:instance/*"
          }
      ]
    }
```

5. Create the following endpoints for non-internet connected VPCs if needed for the HPC clusters:
  ```yaml
   - Interface:
     - com.amazonaws.us-gov-west-1.fsx
     - com.amazonaws.us-gov-west-1.sts
     - com.amazonaws.us-gov-west-1.ec2
     - com.amazonaws.us-gov-west-1.logs
     - com.amazonaws.us-gov-west-1.cloudformation
  
   - Gateway:
     - com.amazonaws.us-gov-west-1.dynamodb
     - com.amazonaws.us-gov-west-1.s3
  ```
   1. Attach the route table for the private subnet to the dynamodb gateway endpoint.
   
6. Update Grafana admin password on file aws-parallelcluster-monitoring/docker-compose/docker-compose.head.yml
  Navigate to "grafana" section:
    Change "password" to desired password
    ```yaml
    ex: 'GF_SECURITY_ADMIN_PASSWORD=password'
    ```

7.  If there exists a VPC Peering connection, do the following to allow traffic to flow between the Prometheus instance and the ParallelCluster EC2s:
    1.  Create an IAM Role/Policy in the Grafana/Prometheus Account that allows the Prometheus instance to assume roles.
        1.  You can launch the Cloudformation template `prometheus-source.yaml` to accomplish this.
    2.  Create an IAM role/Policy in the HPC account that allows Prometheus role to read EC2 instances.
        1.  You can launch the Cloudformation template  `prometheus-target.yaml` to accomplish this, edit {ACCOUNTID} and {ROLE-NAME}, AccountId is the Prometheus accountID, and ROLE-NAME is the role created in the above step.
    3.  Attach the role in step 7.1 to the Prometheus instance.

8. Modify the provided cluster template file.
  Create the AWS ParallelCluster cluster. Use the provided cluster.yaml
  AWS CloudFormation template file as a starting point to create the cluster. 
  
  Replace the following values in the provided template:
    ```yaml
    <REGION> – The AWS Region where the cluster is hosted.

    <HEADNODE_SUBNET> – The public subnet of the VPC.

    <ADDITIONAL_HEAD_NODE_SG> – The name of the security group that you created for the head node.

    <KEY_NAME> – Enter the name of an existing Amazon EC2 key pair. Resources that have this key pair have Secure Shell (SSH) access to the head node.

    <ALLOWED_IPS> -–Enter the CIDR-formatted IP address range that is allowed to make SSH connections to the head node.

    <ADDITIONAL_HEAD_NODE_POLICY> – Enter the name of the IAM policy that you created for the head node.

    <BUCKET_NAME> – Enter the name of the S3 bucket you created.

    <COMPUTE_SUBNET> – Enter the name of the private subnet in the VPC.

    <ADDITIONAL_COMPUTE_NODE_SG> – The name of the security group that you created for the head node.

    <ADDITIONAL_COMPUTE_NODE_POLICY> – Enter the name of the IAM policy that you created for the compute node.
    ```

9. Update the Prometheus config to scrape for EC2 instances in the HPC account. 
   1.  Template to add on additional scrape targets is found in `aws-parallelcluster-monitoring/prometheus/prometheus.yml`
   2.  Edit {ROLE_ARN_OF_TARGET_ACCOUNT} with the arn created in HPC account for the cross account access in step 7.2
    
10.  After successful deployment, open browser on workspace client. Navigate to the Grafana page to look at dashboard