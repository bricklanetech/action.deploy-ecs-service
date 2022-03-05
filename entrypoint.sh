#!/bin/bash -l

## Standard ENV variables provided
# ---
# GITHUB_ACTION=The name of the action
# GITHUB_ACTOR=The name of the person or app that initiated the workflow
# GITHUB_EVENT_PATH=The path of the file with the complete webhook event payload.
# GITHUB_EVENT_NAME=The name of the event that triggered the workflow
# GITHUB_REPOSITORY=The owner/repository name
# GITHUB_BASE_REF=The branch of the base repository (eg the destination branch name for a PR)
# GITHUB_HEAD_REF=The branch of the head repository (eg the source branch name for a PR)
# GITHUB_REF=The branch or tag ref that triggered the workflow
# GITHUB_SHA=The commit SHA that triggered the workflow
# GITHUB_WORKFLOW=The name of the workflow that triggerdd the action
# GITHUB_WORKSPACE=The GitHub workspace directory path. The workspace directory contains a subdirectory with a copy of your repository if your workflow uses the actions/checkout action. If you don't use the actions/checkout action, the directory will be empty

# for logging and returning data back to the workflow,
# see https://help.github.com/en/articles/development-tools-for-github-actions#logging-commands
# echo ::set-output name={name}::{value}
# -- DONT FORGET TO SET OUTPUTS IN action.yml IF RETURNING OUTPUTS

# exit with a non-zero status to flag an error/failure

# Convenience function to output an error message and exit with non-zero error code
die() {
	local _ret=$2
	test -n "$_ret" || _ret=1
	printf "$1\n" >&2
	exit ${_ret}
}

# Ensures required environment variables are supplied by workflow
check_env_vars() {
  local requiredVariables=(
    "AWS_ACCESS_KEY_ID"
    "AWS_SECRET_ACCESS_KEY"
    "AWS_ACCOUNT_ROLE"
    "AWS_REGION"
  )

  for variable_name in "${requiredVariables[@]}"
  do
    if [[ -z "${!variable_name}" ]]; then
      echo "Required environment variable: ${variable_name} is not defined" >&2
      return 3;
    fi
  done
}

# Assume a role in AWS using AWS STS
assume_role() {
  echo "Assuming role: ${AWS_ACCOUNT_ROLE}, in account: ${aws_account_id}"

  local credentials
  credentials=$(aws sts assume-role --role-arn "arn:aws:iam::${aws_account_id}:role/${AWS_ACCOUNT_ROLE}" --role-session-name ecs-force-refresh --output json)
  assume_role_result=$?

  if [ ${assume_role_result} -ne 0 ]; then
    echo "Failed to assume role ${AWS_ACCOUNT_ROLE} in account: ${AWS_ACCOUNT_ID}" >&2
    return ${assume_role_result}
  fi

  export AWS_ACCESS_KEY_ID
  export AWS_SECRET_ACCESS_KEY
  export AWS_SESSION_TOKEN
  export AWS_DEFAULT_REGION=${AWS_REGION}

  AWS_ACCESS_KEY_ID=$(jq -r .Credentials.AccessKeyId <<< ${credentials})
  AWS_SECRET_ACCESS_KEY=$(jq -r .Credentials.SecretAccessKey <<< ${credentials})
  AWS_SESSION_TOKEN=$(jq -r .Credentials.SessionToken <<< ${credentials})

  echo "Successfully assumed role"
}

# Force a new deployment of the service, which will pick up the new images with the relevant tag
deploy_service_task() {
  echo "Forcing deployment of the ${service_name} service in the ${cluster_name} cluster"

  local service_metadata
  service_metadata=$(aws ecs update-service --cluster ${cluster_name} --service ${service_name} --force-new-deployment)
  local exitCode=$?

  if [ ${exitCode} -ne 0 ]; then
    echo "Failed to force new deployment of the ${service_name} service in the ${cluster_name} cluster" >&2
    return ${exitCode}
  fi
}

# Wait for the service to become stable
wait_for_service_to_stabilise() {
  echo "Waiting for the service to stabilise"

  aws ecs wait services-stable --cluster ${cluster_name} --services ${service_name}
  local exit_code=$?

  if [ ${exit_code} -ne 0 ]; then
    echo "Failed to wait for the stabilisation of the ${service_name} service in the ${cluster_name} cluster" >&2
    return ${exit_code}
  fi
  echo "Service has stabilised"
}

# Compare running task image digests with the expected image digest
check_task_container_digest() {
  echo "Checking container image digests"

  echo "Expected image digest: ${expected_image_digest}"
  echo "Retrieving task ARNs"
  local running_tasks=$(aws ecs list-tasks --cluster ${cluster_name} --service-name ${service_name} --desired-status RUNNING | jq .taskArns)

  if [ ${#running_tasks[@]} -eq 0 ]; then
    echo "No running tasks found" >&2
    return 3
  fi

  for task_arn in $(echo "${running_tasks}" | jq -r '.[]'); do
    echo "Retrieving image digest for task: ${task_arn}"
    local task_image_digest=$(aws ecs describe-tasks --tasks ${task_arn} --cluster ${cluster_name} | jq -r .tasks[0].containers[0].imageDigest)

    if [ "${task_image_digest}" == "${expected_image_digest}" ]; then
      echo "The image digest for task: ${task_arn} matches the expected image digest"
      return 0
    else
      echo "The image digest for task: ${task_arn} does not match the expected image digest: ${task_image_digest}" >&2
      return 3
    fi
  done
}

echo "Deploy ECS service"

# Get branch name
# e.g. return "master" from "refs/heads/master"
branch_name=${GITHUB_REF##*/}

aws_account_id=$(cat ${INPUT_ENVIRONMENT_CONFIGURATION} | jq -r ".$branch_name.awsAccountId | select(. != null)")
if [ -z $aws_account_id ]; then
    aws_account_id=$(cat ${INPUT_ENVIRONMENT_CONFIGURATION} | jq -r ".default.awsAccountId | select(. != null)") 
fi
cluster_name=$(cat ${INPUT_ENVIRONMENT_CONFIGURATION} | jq -r ".$branch_name.clusterName | select(. != null)")
if [ -z $cluster_name ]; then
    cluster_name=$(cat ${INPUT_ENVIRONMENT_CONFIGURATION} | jq -r ".default.clusterName | select(. != null)") 
fi
service_name=$(cat ${INPUT_ENVIRONMENT_CONFIGURATION} | jq -r ".$branch_name.serviceName | select(. != null)")
if [ -z $service_name ]; then
    service_name=$(cat ${INPUT_ENVIRONMENT_CONFIGURATION} | jq -r ".default.serviceName | select(. != null)") 
fi

service_name="$branch_name-$service_name"

expected_image_digest=${INPUT_EXPECTED_IMAGE_DIGEST}

if [ -z ${aws_account_id} ]; then die "Target AWS Account ID not set"; fi
if [ -z ${cluster_name} ]; then die "Target ECS Cluster Name not set"; fi
if [ -z ${service_name} ]; then die "Target ECS Service Name not set"; fi

echo "Target cluster: ${cluster_name}"
echo "Target service: ${service_name}"

check_env_vars || exit $?

assume_role || exit $?

if [ ${expected_image_digest} ]; then
  check_task_container_digest && exit 0
fi

deploy_service_task || exit $?

wait_for_service_to_stabilise || exit $?

if [ -z ${expected_image_digest} ]; then
  echo "Expected Docker image digest is not set. Skipping the verification of the running Docker image digest."
  exit 0;
else
  check_task_container_digest || exit $?
fi
