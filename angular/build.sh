#Build the docker image
docker build --no-cache -t ondewo-angular-proto-compiler:latest "$(dirname "$0")"
