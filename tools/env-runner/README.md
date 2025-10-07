# env-runner

This is a simple tool that templates command arguments with environment variables. In other words, this allows usage of environment variables
as arguments without the need for a shell (sh, bash, etc).

Example usage:
```shell
env-runner srcds_linux -game insurgency +map '${MY_MAP}'
```
