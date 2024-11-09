#!/bin/bash
#
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
#

playground_dir="$(dirname "${BASH_SOURCE-$0}")"
playground_dir="$(
  cd "${playground_dir}" >/dev/null || exit 1
  pwd
)"

playgroundRuntimeName="gravitino-playground"

requiredDiskSpaceGB=25
requiredRamGB=8
requiredCpuCores=2
requiredPorts=(8090 9001 3307 19000 19083 60070 13306 15342 18080 18888 19090 13000)

runtime=""

testDocker() {
  echo "[INFO] Testing Docker environment by running hello-world..."
  # Use always to test network connection
  docker run --rm --pull always hello-world:linux >/dev/null 2>&1

  if [ $? -eq 0 ]; then
    echo "[INFO] Docker check passed: Docker is working correctly!"
  else
    echo "[ERROR] Docker check failed: There was an issue running the hello-world container. Please check your Docker installation."
    exit 1
  fi
}

checkDockerCompose() {
  isExist=$(which docker compose)

  if [ ${isExist} ]; then
    echo "[INFO] Docker compose check passed: Docker compose is working correctly!"
  else
    echo "[ERROR] Docker compose check failed: No docker service environment found. Please install docker compose."
    exit 1
  fi
}

checkDockerDisk() {
    # Step 1: Get Docker Root Directory
    local dockerRootDir="$(docker info 2>/dev/null | grep "Docker Root Dir" | awk '{print $NF}')"

    # Step 2: Check if the Docker directory exists
    if [ -z "${dockerRootDir}" ]; then
      echo "[ERROR] Disk check failed: Docker is not running or Docker Root Directory not found."
      exit 1
    fi

    local availableSpaceKB

    if [ -d "${dockerRootDir}" ]; then
      # Check available space in the Docker directory's partition
      availableSpaceKB=$(df --output=avail "${dockerRootDir}" | awk 'NR==2 {print $1}')
    else
      # Check available space in the root partition if the directory doesn't exist (special case for WSL)
      availableSpaceKB=$(df --output=avail / | awk 'NR==2 {print $1}')
    fi

    # Step 3: Check if available space is greater than required
    local availableSpaceGB=$((${availableSpaceKB} / 1024 / 1024))

    if [ "${availableSpaceGB}" -ge "${requiredDiskSpaceGB}" ]; then
      echo "[INFO] Disk check passed: ${availableSpaceGB} GB available."
    else
      echo "[ERROR] Disk check failed: ${availableSpaceGB} GB available, ${requiredDiskSpaceGB} GB or more required."
      exit 1
    fi
}

checkDockerRam() {
    local totalRamBytes=$(docker info --format '{{.MemTotal}}')
    # Convert from bytes to GB
    local totalRamGB=$((totalRamBytes / 1024 / 1024 / 1024))

    if [ "${totalRamGB}" -ge "${requiredRamGB}" ]; then
        echo "[INFO] RAM check passed: ${totalRamGB} GB available."
    else
        echo "[ERROR] RAM check failed: Only ${totalRamGB} GB available, ${requiredRamGB} GB or more required."
        exit 1
    fi
}

checkDockerCpu() {
    local cpuCores=$(docker info --format '{{.NCPU}}')

    if [ "${cpuCores}" -ge "${requiredCpuCores}" ]; then
        echo "[INFO] CPU check passed: ${cpuCores} cores available."
    else
        echo "[ERROR] CPU check failed: Only ${cpuCores} cores available, ${requiredCpuCores} cores or more required."
        exit 1
    fi
}

testK8s() {
  echo "[INFO] Testing K8s environment ..."
  kubectl cluster-info
  if [ $? -eq 0 ]; then
    echo "[INFO] K8s is working correctly!"
  else
    echo "[ERROR] There was an issue running kubectl cluster-info, please check you K8s cluster."
    exit 1
  fi
}

checkHelm() {
  isExist=$(which helm)
  if [ $isExist ]; then
    true # Placeholder, do nothing
  else
    echo "[ERROR] Helm command not found, Please install helm v3."
    exit
  fi
  # check version
  # version will be like:
  # Version:"v3.15.2"
  regex="Version:\"(v[0-9]\.[0-9]+\.[0-9])\""
  version=$(helm version)
  echo "$version"
  if [[ $version =~ $regex ]]; then
    major_version="${BASH_REMATCH[1]}"
    echo "$major_version"
    if [[ $major_version =~ "v3" ]]; then
      echo "[INFO] helm check PASS."
      return
    else
      echo "[ERROR] Please install helm v3"
      exit
    fi
  fi
}

checkPortsInUse() {
  local usedPorts=()
  local availablePorts=()

  for port in "${requiredPorts[@]}"; do
    if [[ "$(uname)" == "Darwin" ]]; then
      openPort=$(lsof -i :${port} -sTCP:LISTEN)
    # Use sudo only when necessary
    elif [[ "$(uname)" == "Linux" ]]; then
      openPort=$(sudo lsof -i :${port} -sTCP:LISTEN)
    fi

    if [ -z "${openPort}" ]; then
      availablePorts+=("${port}")
    else
      usedPorts+=("${port}")
    fi
  done

  echo "[INFO] Port status check results:"

  if [ ${#availablePorts[@]} -gt 0 ]; then
    echo "[INFO] Available ports: ${availablePorts[*]}"
  fi

  if [ ${#usedPorts[@]} -gt 0 ]; then
    echo "[ERROR] Ports in use: ${usedPorts[*]}"
    echo "[ERROR] Please check the ports."
    exit 1
  fi
}

checkRuntime() {
  runtime=""

  echo "[INFO] Checking runtime: ${runtime}"
  # Check if Docker is available
  local dockerAvailable=false
  if command -v docker >/dev/null 2>&1; then
    dockerAvailable=true
  fi

  # Check if kubectl is available
  local k8sAvailable=false
  if command -v kubectl >/dev/null 2>&1; then
    k8sAvailable=true
  fi

  # If no runtime is available
  if [ "${dockerAvailable}" = false ] && [ "${k8sAvailable}" = false ]; then
    echo "[ERROR] No runtime found. Please install Docker or Kubernetes."
    exit 1
  fi

  # If both are available, let user choose
  if [ "${dockerAvailable}" = true ] && [ "${k8sAvailable}" = true ]; then
    read -p "Both Docker and K8s are available. Which runtime would you like to use? [docker/k8s] (default: docker): " choice

    case "$choice" in
      k8s)
        runtime="k8s"
        ;;
      docker|"")  # Empty input defaults to docker
        runtime="docker"
        ;;
      *)
        echo "[ERROR] Invalid choice. Using default: docker"
        runtime="docker"
        ;;
    esac
    return
  fi

  # If only Docker is available
  if [ "${dockerAvailable}" = true ]; then
    runtime="docker"
    return
  fi

  # If only K8s is available
  if [ "${k8sAvailable}" = true ]; then
    runtime="k8s"
    return
  fi
}

checkCurrentRuntime() {
  runtime=""

  # Check if gravitino-playground is running in Docker
  if command -v docker >/dev/null 2>&1; then
    if docker compose ls | grep -q "${playgroundRuntimeName}"; then
      echo "[INFO] gravitino-playground is running in Docker"
      runtime="docker"
      return
    fi
  fi

  # Check if gravitino-playground is running in K8s
  if command -v kubectl >/dev/null 2>&1; then
    if kubectl get namespace "${playgroundRuntimeName}" >/dev/null 2>&1; then
      if kubectl -n "${playgroundRuntimeName}" get pods | grep -q "Running"; then
        echo "[INFO] gravitino-playground is running in Kubernetes"
        runtime="k8s"
        return
      fi
    fi
  fi

  echo "[INFO] gravitino-playground is not currently running"
  exit 1
}

start() {
  echo "[INFO] Starting the playground..."
  echo "[INFO] The playground requires ${requiredCpuCores} CPU cores, ${requiredRamGB} GB of RAM, and ${requiredDiskSpaceGB} GB of disk storage to operate efficiently."

  checkRuntime

  case "${runtime}" in
  k8s)
    testK8s
    checkHelm
    ;;
  docker)
    testDocker
    checkDockerCompose
    checkDockerDisk
    checkDockerRam
    checkDockerCpu
    checkPortsInUse
    ;;
  esac

  cd ${playground_dir} || exit 1
  echo "[INFO] Preparing packages..."
  ./init/spark/spark-dependency.sh
  ./init/gravitino/gravitino-dependency.sh
  ./init/jupyter/jupyter-dependency.sh

  case "${runtime}" in
  k8s)
    helm upgrade --install ${playgroundRuntimeName} ./helm-chart/ \
      --create-namespace --namespace ${playgroundRuntimeName} \
      --set projectRoot=$(pwd)
    ;;
  docker)
    logSuffix=$(date +%Y%m%d%H%M%s)
    docker compose -p ${playgroundRuntimeName} up --detach
    docker compose -p ${playgroundRuntimeName} logs -f  >${playground_dir}/playground-${logSuffix}.log 2>&1 &
    echo "[INFO] Check log details: ${playground_dir}/playground-${logSuffix}.log"
    ;;
  esac
}

status() {
  checkCurrentRuntime

  case "${runtime}" in
  k8s)
    kubectl -n gravitino-playground get pods -o wide
    ;;
  docker)
    docker compose ps -a
    ;;
  esac
}

stop() {
  checkCurrentRuntime

  echo "[INFO] Stopping the playground..."

  case "${runtime}" in
  k8s)
    helm uninstall --namespace gravitino-playground gravitino-playground
    ;;
  docker)
    docker compose down
    if [ $? -eq 0 ]; then
      echo "[INFO] Playground stopped!"
    fi
    ;;
  esac
}

case "$1" in
start)
  start
  ;;
status)
  status
  ;;
stop)
  stop
  ;;
*)
  echo "Usage: $0 [start|status|stop]"
  exit 1
  ;;
esac