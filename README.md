# Deploy ECS Service

This action will trigger a redeployment of a specific AWS ECS service and wait for the service to stabilise.

This is useful when the service task has containers that reference Docker images by their name and tag. The redeployment process will refetch the container's Docker images, so the latest version of that image will be deployed.

## Usage

### Example Pipeline

```yaml
name: Deploy ECS Service
on:
  push:
    branches:
      - 'master'
jobs:
  build-and-push:
    env:
      AWS_REGION: eu-west-2
      AWS_ACCOUNT_ROLE: deploy
      AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
    name: Deploy Service
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@master
      - name: Deploy to ECS
        uses: propertylift/action.deploy-ecs-service@master
        with:
          environment_configuration: '{"master": {"awsAccountId": ${{secrets.ECS_AWS_ACCOUNT_ID}}, "clusterName": "my-ecs-cluster", "service_name": "my-ecs-service"}}'
          expected_image_digest: f0af17449a83681de22db7ce16672f16f37131bec0022371d4ace5d1854301e0
```

## Environment Variables

- `AWS_REGION`: The region in which the ECS service exists.
- `AWS_ACCOUNT_ROLE`: The name of a IAM Role that has the [required permissions](#Role-permissions) to update the ECS service.
- `AWS_ACCESS_KEY_ID`: The AWS Access Key ID of a user with permission to assume the **AWS_ACCOUNT_ROLE**.
- `AWS_SECRET_ACCESS_KEY`: The AWS Secret Access Key that pairs with the `AWS_ACCESS_KEY_ID`.

**Suggestion**: Store your AWS account details in [Secrets](https://help.github.com/en/actions/automating-your-workflow-with-github-actions/creating-and-using-encrypted-secrets)

## Required Arguments

- `environment_configuration`: JSON object containing the target AWS Account ID and ECS Cluster and Service Name for each branch. E.g. "{\"master\": {\"awsAccountId\": \"1234567890\", \"clusterName\": \"my-ecs-cluster\", \"serviceName\": \"my-ecs-service\"}}".

## Optional Arguments

- `expected_image_digest`: When a service only has one task, specifying the expected Docker image digest will cause the action to verify that the containers of the running tasks on the target service match the given Docker image digest.

## Role permissions

This action uses [AWS Security Token Service](https://docs.aws.amazon.com/STS/latest/APIReference/Welcome.html) to to assume the **AWS_ACCOUNT_ROLE**.

The following shows an example policy containing the permissions that are required for the **AWS_ACCOUNT_ROLE** to perform the AWS commands contained in the action.

```json
{
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["ecs:ListTasks", "ecs:DescribeServices", "ecs:DescribeTasks", "ecs:ListClusters", "ecs:UpdateService"],
      "Resource": "*"
    }
  ]
}
```
