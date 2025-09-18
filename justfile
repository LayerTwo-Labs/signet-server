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

    all_services=$(uv tool run yq -r '.services | keys[]' docker-compose.yml )
    if ! echo "$all_services" | grep -q "{{ service }}"; then
        echo "service '{{ service }}' not found"
        exit 1
    fi

    image=$(uv tool run yq -r '.services["{{ service }}"].image' docker-compose.yml)
    
    
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
