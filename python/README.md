## Ondewo Protos Compiler for Python

The compiler compiles the protobuf files into Python. 

To use:

1. put your protobuf files in this directory
2. `make build` 
3. `docker run -v ${shell pwd}:/opt/ondewo-proto-compiler -e PROTOS_DIR=YOUR_PROTOS_DIR -e APIS_DIR=YOUR_APIS_DIR -e OUTPUT_FOLDER=YOUR_OUTPUT_FOLDER ondewo-python-proto-compiler`

See `make run_example` for an example of the docker run command. 
