## Ondewo Protos Compiler for Python

The compiler compiles the protobuf files into Python. 

To use:

1. put your protobuf files in the `protos` directory
2. run `make build` command 
3. run `make run` command 

When running the `run` recipe you can specify different .env variables:

|  Env Variables  |                              Description                                            |
| --------------- | ----------------------------------------------------------------------------------- |
| OUTPUT_DIR      |  Output directory where to put the compiled files                                   | 
| PROTO_DIR       |  Main directory where the protos to compile are                                     | 
| EXTRA_PROTO_DIR |  Extra directory with protos that are usually depndencies to the main ones          | 
| TARGET_DIR      |  Proto directory to compile. Defaults to everything                                 |

Your generated Python files will be in the `output` directory.

Example:

```bash
make -f python/Makefile run PROTO_DIR='ondewo-survey-api/ondewo' EXTRA_PROTO_DIR='ondewo-survey-api/googleapis/google'
```



