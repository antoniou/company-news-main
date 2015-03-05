#!/bin/bash
set -e

GIT_REPOSITORY_SOURCE=github.com:antoniou
GIT_REPOSITORIES=( ansible-company-news terraform-company-news)
ANSIBLE_DIR=${GIT_REPOSITORIES}
TERRAFORM_DIR=${GIT_REPOSITORIES[1]}
PACKER_DIR=packer
AWS_REGION=eu-west-1
SKIP_PACKING=0

PACKAGE_DEPENDENCIES=( git packer terraform )
_V=0

usage() {
  cat <<EOF
    Usage: $0 [options] environment

    -h    Display help message
    -v    Verbose mode
    -s    skip building image
EOF
exit 1;
}

log () {
  if [[ $_V -eq 1 ]]; then
      echo "$@"
      echo ""
  fi
}

check_for_dependencies() {
  for d in "${PACKAGE_DEPENDENCIES[@]}";
  do
    command -v  $d >/dev/null 2>&1 || { echo >&2 "$d binary not found. Please make sure it is installed."; exit 1; }
  done
}

check_credentials() {
  log "Checking if AWS credentials are provided in the environment"
  [ -n "$AWS_ACCESS_KEY_ID" ] || { echo >&2 "AWS_ACCESS_KEY_ID is not exported. Please export in ENV"; exit 1; }
  [ -n "$AWS_SECRET_ACCESS_KEY" ] || { echo  >&2 "AWS_SECRET_ACCESS_KEY is not exported. Please export in ENV"; exit 1; }
}

clone_repositories() {
  for repo in "${GIT_REPOSITORIES[@]}";
  do
    log "Cloning repository $repo"
    [ -d $repo ] && { log "Dir $repo already exists, not cloning"; continue;}
    repo_url="git@$GIT_REPOSITORY_SOURCE/$repo"
    git clone $repo_url
  done
}

pack_images() {
  for p in $PACKER_DIR/*.json
  do

    if [ $SKIP_PACKING -eq 0 ];
    then
      log "Packing image with $p"
      packer build \
        -var "AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID" \
        -var "AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY" \
        -var "ANSIBLE_DIR=$ANSIBLE_DIR" \
        $p | tee packer.log
      test ${PIPESTATUS[0]} -eq 0;
    fi

    AMI=$(cat packer.log| grep "amazon-ebs: AMI:"|awk '{print $4}'|cut -c1-12)
  done
}

deploy() {
  log "Deploying infrastructure for env $ENVIRONMENT with AMI $AMI"
  cd $TERRAFORM_DIR
  terraform apply \
    -var "web_ami.${AWS_REGION}=$AMI" \
    -var "access_key=${AWS_ACCESS_KEY_ID}" \
    -var "secret_key=${AWS_SECRET_ACCESS_KEY}" \
    -var-file="environments/${ENVIRONMENT}.tfvars"

  elb_url=$(terraform output "elb")
  [ -d "../$TERRAFORM_DIR" ] && cd ..
}

wait_until_ready() {
  log "Waiting until environment becomes ready..."
  response="404"
  while [ $response != "200" ]
  do
    sleep 5
    response=$(curl -sL -w "%{http_code} \\n" "$elb_url" -o /dev/null) || echo
    log "Response from $elb_url was $response"
  done
}

[ "$#" -lt  1 ] && usage
ENVIRONMENT="${@: -1}"

while getopts "hvs" opt; do
  case $opt in
    h)
      usage
      exit 0
      ;;
    v)
      _V=1
      ;;
    s)
      SKIP_PACKING=1
      ;;
  esac
done

check_for_dependencies
check_credentials
clone_repositories
pack_images
deploy
wait_until_ready
