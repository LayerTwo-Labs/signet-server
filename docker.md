This document describes how to run and interact with a Drivechain 
infrastructure stack through Docker Compose. 

The file `docker-compose.yml` contains our different services. 

### Starting

Start all services, and detach from them. They'll keep running in the background.

```bash
$ docker compose up -d
```

### Inspecting the services

List all running services, and their status. A "good" service will have a status of `healthy`.

```bash
$ docker compose ps
```

### Inspecting the logs

```bash
$ docker compose logs [-f] [--tail=N] [service(s)]
```

These logs can also be piped to a file, or other commands. A recommended
tool for inspecting logs is [`lnav`](https://github.com/tstack/lnav).

### Executing commands on running services

```bash
# In general: 
$ docker compose exec SERVICE COMMAND

# For example: 
$ docker compose exec mainchain drivechain-cli -rpcuser=user -rpcpassword=password -signet -getinfo
```

### Mining

Mining is done through calling the GenerateBlocks endpoint on the enforcer. 

```bash
$ docker compose run --rm buf curl \
    --protocol grpc --http2-prior-knowledge \
    http://enforcer:50051/cusf.mainchain.v1.WalletService/GenerateBlocks
```
