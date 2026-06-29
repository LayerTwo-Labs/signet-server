compose-signet *args="":
    #! /usr/bin/env bash
    if [ docker context inspect l2l-signet > /dev/null 2>&1 ]; then
        echo "❌ No Docker context named 'l2l-signet' found"
        exit 1
    fi

    docker --context l2l-signet compose \
        --env-file .env.signet \
        --profile signet \
        -f docker-compose.base.yml \
        -f docker-compose.signet.yml {{ args }}

# Bootstrap a freshly generated signet onto the remote node, end to end
bootstrap-signet gen_dir:
    #! /usr/bin/env bash
    set -euo pipefail
    gen_dir="{{ gen_dir }}"; gen_dir="${gen_dir%/}"
    gen_env="$gen_dir/env.signet"
    wallet="$gen_dir/signet-miner.dat"
    [ -f "$gen_env" ] || { echo "❌ no env.signet in $gen_dir"; exit 1; }
    [ -f "$wallet" ] || { echo "❌ no signet-miner.dat in $gen_dir"; exit 1; }

    for key in SIGNET_VERSION SIGNET_CHALLENGE NETWORK_MAGIC SIGNET_MINER_COINBASE_RECIPIENT; do
        if [ "$(grep "^$key=" "$gen_env")" != "$(grep "^$key=" .env.signet)" ]; then
            echo "❌ $key in .env.signet does not match $gen_env"
            echo "   copy all four values from $gen_env into .env.signet, then retry"
            exit 1
        fi
    done

    compose=(docker --context l2l-signet compose --env-file .env.signet --profile signet
        -f docker-compose.base.yml -f docker-compose.signet.yml)
    current="signet-server-$(grep '^SIGNET_VERSION=' .env.signet | cut -d= -f2)"

    # Remove containers from any older signet-server-* projects (their data volumes are left intact).
    for proj in $(docker --context l2l-signet compose ls --all --format json 2>/dev/null \
        | jq -r '.[].Name' | grep '^signet-server-' | grep -vx "$current" || true); do
        echo ">> removing containers from older version $proj"
        ids="$(docker --context l2l-signet ps -aq --filter "label=com.docker.compose.project=$proj")"
        [ -z "$ids" ] || docker --context l2l-signet rm -f $ids >/dev/null
    done

    echo ">> starting mainchain (project $current)"
    "${compose[@]}" up -d mainchain
    for i in $(seq 1 60); do
        "${compose[@]}" exec -T mainchain drivechain-cli -rpccookiefile=/cookie -chain=signet getblockchaininfo >/dev/null 2>&1 && break
        [ "$i" = 60 ] && { echo "❌ mainchain RPC never came up"; "${compose[@]}" logs --tail 20 mainchain; exit 1; }
        sleep 1
    done

    echo ">> loading wallet"
    "${compose[@]}" cp "$wallet" mainchain:/tmp/wallet.dat
    "${compose[@]}" exec -u root -T mainchain chmod a+r /tmp/wallet.dat
    "${compose[@]}" exec -T mainchain drivechain-cli -rpccookiefile=/cookie -chain=signet restorewallet signet-miner /tmp/wallet.dat true
    "${compose[@]}" exec -T mainchain rm -f /tmp/wallet.dat

    echo ">> bringing up the rest of the stack"
    "${compose[@]}" up -d

    echo ">> waiting for enforcer, then mining the first block"
    for i in $(seq 1 90); do
        [ -n "$(docker --context l2l-signet ps -q --filter "name=$current-enforcer-1" --filter health=healthy)" ] && break
        [ "$i" = 90 ] && { echo "❌ enforcer never became healthy"; exit 1; }
        sleep 2
    done
    "${compose[@]}" run --rm buf curl --protocol grpc --http2-prior-knowledge \
        --data '{"blocks":1,"ackAllProposals":true}' \
        http://enforcer:50051/cusf.mainchain.v1.WalletService/GenerateBlocks
    echo "✅ signet bootstrapped and mining"

compose-forknet *args="":
    #! /usr/bin/env bash
    if [ docker context inspect l2l-forknet > /dev/null 2>&1 ]; then
        echo "❌ No Docker context named 'l2l-forknet' found"
        exit 1
    fi

    docker --context l2l-forknet compose \
        --env-file .env.forknet \
        --profile forknet \
        -f docker-compose.base.yml \
        -f docker-compose.forknet.yml {{ args }}

compose-mainnet *args="":
    #! /usr/bin/env bash
    if [ docker context inspect l2l-mainnet > /dev/null 2>&1 ]; then
        echo "❌ No Docker context named 'l2l-mainnet' found"
        exit 1
    fi

    # mainnet is a standalone, self-contained stack: it does NOT extend
    # docker-compose.base.yml, so there's no --env-file or base layering here.
    docker --context l2l-mainnet compose \
        -f docker-compose.mainnet.yml {{ args }}

# Push caddy/Caddyfile.mainnet to the mainnet host's /etc/caddy/Caddyfile and reload Caddy.
# Caddy runs under systemd (not in the compose stack), so this goes over SSH as
# root rather than through the Docker context. The host's systemd unit reads
# /etc/caddy/Caddyfile, so that's the deploy target. Validates a staged copy
# before swapping it in, and backs up the previous config, so a bad edit can't
# take the proxy down.
[doc("Deploy caddy/Caddyfile.mainnet to the mainnet host and reload Caddy")]
update-mainnet-caddy:
    #! /usr/bin/env bash
    set -euo pipefail
    host="root@l2l-mainnet"
    echo ">> staging caddy/Caddyfile.mainnet on $host"
    ssh "$host" 'cat > /etc/caddy/Caddyfile.new' < caddy/Caddyfile.mainnet
    echo ">> validating staged config"
    ssh "$host" 'caddy validate --config /etc/caddy/Caddyfile.new'
    echo ">> backing up current config and swapping in the new one"
    ssh "$host" 'cp -a /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true; mv /etc/caddy/Caddyfile.new /etc/caddy/Caddyfile'
    echo ">> reloading caddy"
    ssh "$host" 'systemctl reload caddy && systemctl is-active caddy'
    echo "✅ caddy config updated on mainnet host"

rpcauth-commit := "fa5f29774872d18febc0df38831a6e45f3de69cc"
# https://github.com/bitcoin/bitcoin/blob/master/share/rpcauth/rpcauth.py
[doc("Generate RPC credentials for bitcoin.conf using Bitcoin Core's rpcauth.py. Empty password argument will generate a random password.")]
gen-bitcoin-core-pass username password='':
    #! /usr/bin/env bash
    script_file=$(mktemp)
    curl --fail --silent --output $script_file https://raw.githubusercontent.com/bitcoin/bitcoin/{{ rpcauth-commit }}/share/rpcauth/rpcauth.py

    output=$(uv run python $script_file --json {{ username }} {{ password }})
    echo "RPC username: $(echo "$output" | jq -r '.username')"
    echo "RPC password: $(echo "$output" | jq -r '.password')"
    echo ""
    echo "Add this to bitcoin.conf:"
    echo "rpcauth=$(echo "$output" | jq -r '.rpcauth')"


get-latest-image service:
    #! /usr/bin/env bash
    if ! which uv > /dev/null; then
        echo "uv is not installed"
        exit 1
    fi
    
    if ! which gh > /dev/null; then
        echo "gh (GitHub CLI) is not installed"
        exit 1
    fi

    all_services=$(uv tool run yq -r '.services | keys[]' docker-compose.base.yml)
    if ! echo "$all_services" | grep -q "{{ service }}"; then
        echo "service '{{ service }}' not found"
        exit 1
    fi

    image=$(uv tool run yq -r '.services["{{ service }}"].image' docker-compose.base.yml)
    
    
    # if it is not a ghcr.io image, exit
    if ! [[ "$image" == ghcr.io/* ]]; then
        echo "❌ Only GitHub Container Registry (ghcr.io) images are supported"
        echo "This image is from a different registry and cannot be checked automatically"
        exit 1
    fi

    # Extract repository name from image
    repo=$(echo "$image" | cut -d':' -f1)
        
    # Get the package name (last part after /)
    package=$(echo "$repo" | sed 's/.*\///')
        
    # Get the org/user (part between ghcr.io/ and last /)
    org=$(echo "$repo" | sed 's/ghcr.io\///' | sed 's/\/[^\/]*$//')
        
    # Fetch the sha tag of the "latest" tag
    tag=$(gh api \
        "orgs/$org/packages/container/$package/versions?state=active&per_page=10" | \
        jq -r '.[] | select(.metadata.container.tags | contains(["latest"])) | .metadata.container.tags[] | select(startswith("sha-"))')

    
    if [ -z "$tag" ]; then
        echo "❌ No sha tag found for the 'latest' tag"
        exit 1
    fi

    echo "$tag"

prettier-version := "3.8.1"

prettier-write: 
    npx --yes prettier@{{ prettier-version }} --write .

prettier-check:
    npx --yes prettier@{{ prettier-version }} --check .