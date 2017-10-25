#!/bin/bash

# Create basic VPC network infrastructure with AWS Cloudformation Template
# Resource of creation: VPC, iGateway, NatGateway, ACL, subnets, VPC endpoint for S3
#
# Usage: ./vpc_infra_creation {Profile} {Region} {VPC Name} {classB address}
#
#
#  Modify by: Ming Fang
#  Date:      10/18/2017

set -euo pipefail
# set -x


if [[ $# -ne 4 ]]; then
  echo 1>&2 "  Usage: $0 {Profile} {Region} {VPC Name} {classB address}"
  echo 1>&2 "Example: $0 dev us-east-1 vpc-ue1-p 210"
  exit 1
fi

# variables
profile="${1:-dev}"
region="${2:-us-east-2}"
vpc_name="$3"
classB=${4:-210}
readonly vpc_cf="vpc-3azs-3tiers.yaml"
readonly natgateway_cf="vpc-nat-gateway.yaml"
readonly vpce_cf="vpc-endpoint-s3.yaml"
readonly cf_stack_complete="CREATE_COMPLETE"
readonly cf_stack_rollback="ROLLBACK_COMPLETE"
readonly azs=(A B C D E F)
readonly natGW_name="natGW-$( echo ${vpc_name} | sed s/vpc-//g )"
readonly vpce_name="vpce-$( echo ${vpc_name} | sed s/vpc-//g )"

echo -e "\n"
echo "------------------------------------"
echo "Running VPC creation script PID: $$ "
echo "------------------------------------"

### Functions ###
cf_status_check() {

 prf=${1}
 reg=${2}
 stk=${3}

 while [[ true ]]; do
  stack=$( aws cloudformation describe-stacks --profile ${prf} --region ${reg} --stack-name ${stk} )
  status=$( echo ${stack} | jq -r ".Stacks[].StackStatus" )

  if [[ "${status}" != "${cf_stack_complete}" && "${status}" != "${cf_stack_rollback}" ]]; then
  	echo "Waiting on ${stk} stack creation: ${status} - $(date "+TIME: %H:%M:%S")"
  	sleep 15
  elif [[ "${status}" = "${cf_stack_rollback}" ]]; then
    printf "%s has failed due to: %s \n" "${stk}" "${status}"
    exit 1
  else  
    echo  -e "${stk} is created successfully - $(date "+TIME: %H:%M:%S") \n"
    break
  fi
done
}

# 1. Check VPC CIDR block address or VPC Name is not currently in use

# 2. Create VPC basic infrastructure
aws cloudformation create-stack --profile ${profile} --region ${region} --stack-name ${vpc_name} \
                                --template-body file://${vpc_cf} --parameters \
                                ParameterKey=ClassB,ParameterValue=${classB} \
                                --enable-termination-protection

# 3. Verify VPC is complete
cf_status_check ${profile} ${region} ${vpc_name}

# 4. Create NatGateway per AZ used in VPC
stack=$( aws cloudformation describe-stacks --profile ${profile} --region ${region} --stack-name ${vpc_name} )
num_AZs=$( echo $stack | jq '.Stacks[].Outputs[] | select(.OutputKey == "AZs").OutputValue | tonumber' )

for (( i = 0; i < ${num_AZs}; i++ )); do
  az=${azs[i]} 
  aws cloudformation create-stack --profile ${profile} --region ${region} --stack-name ${natGW_name}-${az} \
                                  --template-body file://${natgateway_cf} --parameters \
                                  ParameterKey=ParentVPCStack,ParameterValue=${vpc_name} \
                         		  ParameterKey=SubnetZone,ParameterValue=${az}  \
                         		  --enable-termination-protection
done

# Verify NatGateway is complete
for (( i = 0; i < ${num_AZs}; i++ )); do
  az=${azs[i]}
  cf_status_check ${profile} ${region} ${natGW_name}-${az}
done

# 5. Create VPC endpoint service
aws cloudformation create-stack --profile ${profile} --region ${region} --stack-name ${vpce_name} \
                                --template-body file://${vpce_cf} --parameters \
                                ParameterKey=ParentVPCStack,ParameterValue=${vpc_name} \
                                --enable-termination-protection

# 6. Verify S3 is complete
cf_status_check ${profile} ${region} ${vpce_name}

