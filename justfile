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