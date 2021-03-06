#!/bin/bash

# Script to deploy a Bob Emploi release, both server and client.
#
# The canonical place for our releases are the Docker Images in Docker Hub.
# They are generated by CircleCI in an untainted way.
#
# The server gets released by creating a new deployment on Amazon Web Service's
# (AWS) ECS (EC2 Container Service), and waiting for new containers to be
# spawned and old containers to be stopped.
#
# The client gets released by deploying static files on OVH storage.
#
# TODO(pascal): Decide and document the deployment cycle, for now this is a
# tool that can be used manually.

set -e

readonly TAG="$1"
if [ -z "${TAG}" ]; then
  echo -e "ERROR: \033[31mChoose a git tag to deploy.\033[0m"
  exit 1
fi

if [ -z "${OS_PASSWORD}" ]; then
  echo -e "ERROR: \033[31mSet up OpenStack credentials first.\033[0m"
  exit 1
fi

readonly DOCKER_SERVER_REPO="bob-emploi-frontend-server"
readonly DOCKER_CLIENT_REPO="bob-emploi-frontend"
readonly DOCKER_TAG="tag-${TAG}"
readonly DOCKER_SERVER_IMAGE="bayesimpact/${DOCKER_SERVER_REPO}:${DOCKER_TAG}"
readonly DOCKER_CLIENT_IMAGE="bayesimpact/${DOCKER_CLIENT_REPO}:${DOCKER_TAG}"
readonly ECS_FAMILY="frontend-flask"
readonly ECS_SERVICE="flask-lb"
# Our OpenStack container, see
# https://www.ovh.com/manager/cloud/index.html#/iaas/pci/project/7b9ade05d5f84f719adc2cbc76c07eec/storage
readonly OPEN_STACK_CONTAINER="PE Static Assets"


# Deploying the server.


echo -e "\033[32mChecking that the server Docker image exists…\033[0m"
docker run --rm harisekhon/pytools dockerhub_show_tags.py "bayesimpact/${DOCKER_SERVER_REPO}" -q | \
  grep "^${DOCKER_TAG}\$" > /dev/null || {
  echo -e "ERROR: \033[31mThe tag \"${DOCKER_TAG}\" does not exist in Docker Registry.\033[0m"
  exit 2
}

echo -e "\033[32mCreating a new task definition…\033[0m"
readonly CONTAINERS_DEFINITION=$(
  aws ecs describe-task-definition --task-definition "${ECS_FAMILY}" | \
    python3 -c "import sys, json; containers = json.load(sys.stdin)['taskDefinition']['containerDefinitions']; containers[0]['memoryReservation'] = 300; containers[0]['image'] = '${DOCKER_SERVER_IMAGE}'; print(json.dumps(containers))")

aws ecs register-task-definition --family="${ECS_FAMILY}" --container-definitions "${CONTAINERS_DEFINITION}" > /dev/null

echo -e "\033[32mRolling out the new task definition…\033[0m"
aws ecs update-service --service="${ECS_SERVICE}" --task-definition="${ECS_FAMILY}" > /dev/null

function count_deployments()
{
  aws ecs describe-services --services "${ECS_SERVICE}" | \
    python3 -c "import sys, json; deployments = json.load(sys.stdin)['services'][0]['deployments']; print(len(deployments))"
}

while [ "$(count_deployments)" != "1" ]; do
  printf .
  sleep 10
done

echo -e "\033[32mServer Deployed!\033[0m"


# Deploying the client.


# To get the files, this script downloads the Docker Images from Docker
# Registry, then extract the html folder from the Docker Image (note that to do
# that we need to create a temporary container using that image). The html
# folder is extracted as a TAR archive that we unpack in a local dir.
#
# Once we have the file we can upload them to OVH Storage using the OpenStack
# tool swift.

echo -e "\033[32mDownloading the client Docker Image…\033[0m"
docker pull "${DOCKER_CLIENT_IMAGE}"

echo -e "\033[32mExtracting the archive from the Docker Image…\033[0m"
readonly TMP_TAR_FILE=$(mktemp --suffix=.tar)
readonly TMP_DOCKER_CONTAINER=$(docker create "${DOCKER_CLIENT_IMAGE}")
docker cp "${TMP_DOCKER_CONTAINER}":/usr/share/bob-emploi/html - > "${TMP_TAR_FILE}"
docker rm ${TMP_DOCKER_CONTAINER}

echo -e "\033[32mExtracting files from the archive…\033[0m"
readonly TMP_DIR=$(mktemp -d)
tar -xf "${TMP_TAR_FILE}" -C "${TMP_DIR}" --strip-components 1
rm -r "${TMP_TAR_FILE}"

echo -e "\033[32mUploading files to the OpenStack container…\033[0m"
pushd "${TMP_DIR}"
swift upload "${OPEN_STACK_CONTAINER}" --skip-identical *
popd

rm -r "${TMP_DIR}"

echo -e "\033[32mLogging the deployment on GitHub…\033[0m"
readonly RELEASE_NOTES=$(mktemp)
if hub release show "${TAG}" 2> /dev/null > "${RELEASE_NOTES}"; then
  echo "Redeployed on $(date -R -u)" >> "${RELEASE_NOTES}"
  hub release edit --file="${RELEASE_NOTES}" "${TAG}"
else
  echo -e "${TAG}\\n" > "${RELEASE_NOTES}"
  echo "First deployed on $(date -R -u)" >> "${RELEASE_NOTES}"
  hub release create --file="${RELEASE_NOTES}" "${TAG}"
fi
rm -f "${RELEASE_NOTES}"

echo -e "\033[32mSuccess!\033[0m"
