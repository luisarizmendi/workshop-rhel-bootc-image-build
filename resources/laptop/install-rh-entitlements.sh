#!/bin/bash

# Default values
ARCH="x86_64"
PULL_SECRET_FILE="$HOME/.pull-secret.json"
ENTITLEMENTS_DIR="$HOME/.rh-entitlements"
USERNAME=""
PASSWORD=""
CREDENTIALS_FILE=""

SUBS_FROM="registry.redhat.io/rhel9/rhel-bootc:9.6"

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "OPTIONS:"
    echo "  -a ARCH              Architecture (default: x86_64)"
    echo "  -s PULL_SECRET_FILE  Path to pull secret file (default: ~/.pull-secret.json)"
    echo "  -e ENTITLEMENTS_DIR  Path to entitlements directory (default: ~/.rh-entitlements)"
    echo "  -u USERNAME          Red Hat username (optional, can use RH_USERNAME env var)"
    echo "  -p PASSWORD          Red Hat password (optional, can use RH_PASSWORD env var)"
    echo "  -c CREDENTIALS_FILE  Path to credentials file (optional)"
    echo "  -h                   Show this help message"
    echo ""
    echo "Credential Priority (first found is used):"
    echo "  1. Command line options (-u/-p)"
    echo "  2. Environment variables (RH_USERNAME/RH_PASSWORD)"
    echo "  3. Credentials file specified with -c"
    echo "  4. Default credentials file (~/.rh-credentials)"
    echo ""
    echo "Examples:"
    echo "  # Using environment variables (recommended)"
    echo "  export RH_USERNAME=myuser"
    echo "  export RH_PASSWORD=mypassword"
    echo "  $0"
    echo ""
    echo "  # Using credentials file"
    echo "  echo 'myuser' > ~/.rh-credentials"
    echo "  echo 'mypassword' >> ~/.rh-credentials"
    echo "  $0"
    echo ""
    echo "  # Using command line (less secure)"
    echo "  $0 -u myuser -p mypassword"
    exit 1
}

while getopts "a:s:e:u:p:c:h" opt; do
    case $opt in
        a)
            ARCH="$OPTARG"
            ;;
        s)
            PULL_SECRET_FILE="$OPTARG"
            ;;
        e)
            ENTITLEMENTS_DIR="$OPTARG"
            ;;
        u)
            USERNAME="$OPTARG"
            ;;
        p)
            PASSWORD="$OPTARG"
            ;;
        c)
            CREDENTIALS_FILE="$OPTARG"
            ;;
        h)
            usage
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            usage
            ;;
        :)
            echo "Option -$OPTARG requires an argument." >&2
            usage
            ;;
    esac
done

shift $((OPTIND-1))

# Function to read credentials from file
read_credentials_file() {
    local file="$1"
    if [ -f "$file" ]; then
        USERNAME=$(sed -n '1p' "$file" | tr -d '\r\n')
        PASSWORD=$(sed -n '2p' "$file" | tr -d '\r\n')
        return 0
    fi
    return 1
}

# Credential priority: command line > environment variables > credentials file > default credentials file
if [ -z "$USERNAME" ] || [ -z "$PASSWORD" ]; then
    # Try environment variables
    if [ -n "$RH_USERNAME" ] && [ -n "$RH_PASSWORD" ]; then
        USERNAME="$RH_USERNAME"
        PASSWORD="$RH_PASSWORD"
        echo "Using credentials from environment variables"
    # Try specified credentials file
    elif [ -n "$CREDENTIALS_FILE" ] && read_credentials_file "$CREDENTIALS_FILE"; then
        echo "Using credentials from file: $CREDENTIALS_FILE"
    # Try default credentials file
    elif read_credentials_file "$HOME/.rh-credentials"; then
        echo "Using credentials from default file: $HOME/.rh-credentials"
    fi
fi

# Check for required credentials
if [ -z "$USERNAME" ] || [ -z "$PASSWORD" ]; then
    echo "Error: Red Hat credentials are required."
    echo "Please provide credentials using one of these methods:"
    echo "  1. Command line: -u username -p password"
    echo "  2. Environment variables: RH_USERNAME and RH_PASSWORD"
    echo "  3. Credentials file: -c /path/to/credentials"
    echo "  4. Default credentials file: ~/.rh-credentials"
    echo ""
    usage
fi

PULL_SECRET_FILE="${PULL_SECRET_FILE/#\~/$HOME}"
ENTITLEMENTS_DIR="${ENTITLEMENTS_DIR/#\~/$HOME}"

echo "Checking entitlements"
echo "---------------------"
echo "Architecture: $ARCH"
echo "Pull-Secret file: $PULL_SECRET_FILE"
echo "Entitlements directory for $ARCH: ${ENTITLEMENTS_DIR}/${ARCH}"
echo "Username: $USERNAME"
echo "---------------------"
echo ""


if [ ! -d "${ENTITLEMENTS_DIR}/${ARCH}" ]; then
    mkdir -p ${ENTITLEMENTS_DIR}/${ARCH}
fi

# Check if entitlements already exist
if [ -d "${ENTITLEMENTS_DIR}/${ARCH}" ] && find "${ENTITLEMENTS_DIR}/${ARCH}" -mindepth 1 -maxdepth 1 -type f | grep -q .; then
    echo "Entitlements already exist for $ARCH"
    exit 0
fi

if [ ! -f "$PULL_SECRET_FILE" ]; then
    echo "Red Hat pull-secret not found at $PULL_SECRET_FILE"
    exit 1
else
    echo "Using provided username and password for Red Hat credentials"
fi

if [[ "$(uname -m)" != "$ARCH" ]]; then
    echo "Enabling binfmt_misc for cross-arch builds..."
    podman run --rm --privileged docker.io/multiarch/qemu-user-static --reset -p yes 2>/dev/null \
        || echo "binfmt setup completed (some handlers may have already existed)"
else
    echo "Host architecture matches target ($ARCH), no binfmt setup needed."
fi

echo "Getting entitlements for $ARCH..."

# Check if the container image already exists and remove it
if podman images --quiet "local-$ARCH" | grep -q .; then
    echo "Container image local-$ARCH already exists, removing it..."
    podman rmi -f "local-$ARCH"
fi

cat <<EOF > Containerfile.subs
FROM $SUBS_FROM
ARG RH_USERNAME=""
ARG RH_PASSWORD=""
RUN if [ -n "\$RH_USERNAME" ] && [ -n "\$RH_PASSWORD" ]; then \
    echo "Registering with Red Hat subscription manager..."  && rm -rf /etc/rhsm-host && subscription-manager register --username "\$RH_USERNAME" --password "\$RH_PASSWORD" | tee /tmp/register_output && echo \$(grep -o 'ID: [a-f0-9-]*' /tmp/register_output | cut -d' ' -f2) > /etc/rhsm/system_id && echo \$(grep -o 'system name is: [a-f0-9-]*' /tmp/register_output | cut -d' ' -f4) > /etc/rhsm/host_id && rm -f /tmp/register_output ; \
    else \
    echo "Red Hat credentials not found; skipping subscription registration."; \
    fi
RUN dnf -y --nogpgcheck install curl jq && dnf clean all
RUN mkdir -p /entitlements && cp -a /etc/pki/entitlement/* /entitlements/
RUN if [ -n "\$RH_USERNAME" ] && [ -n "\$RH_PASSWORD" ]; then \
    echo "Unregistering from Red Hat Cloud inventory..." && for uuid in \$(curl -s -u "\$RH_USERNAME:\$RH_PASSWORD" https://cloud.redhat.com/api/inventory/v1/hosts?fqdn=\$(cat /etc/rhsm/host_id) | grep -o '"id":"[^"]*' | grep -o '[^"]*\$') ; do curl -u "\$RH_USERNAME:\$RH_PASSWORD" -X DELETE https://cloud.redhat.com/api/inventory/v1/hosts/\$uuid -H  "accept: */*" ;done && subscription-manager unregister && subscription-manager clean && ln -s /run/secrets/rhsm /etc/rhsm-host; \
    else \
    echo "Red Hat credentials not found; skipping subscription clean-up."; \
    fi
EOF

echo "Building entitlement container for $ARCH..."
mkdir -p entitlements/$ARCH
podman build -f Containerfile.subs \
    --authfile "$PULL_SECRET_FILE" \
    --build-arg RH_USERNAME="$USERNAME" \
    --build-arg RH_PASSWORD="$PASSWORD" \
    --platform "$ARCH" \
    -t "local-$ARCH" .

CONTAINER_ID=$(podman create "local-$ARCH")
podman cp "${CONTAINER_ID}:/entitlements/." "entitlements/$ARCH/"
podman rm "${CONTAINER_ID}"
podman rmi "local-$ARCH"

mkdir -p "${ENTITLEMENTS_DIR}/${ARCH}"
cp -r "entitlements/$ARCH"/* "${ENTITLEMENTS_DIR}/${ARCH}"

echo "Entitlements gathered for $ARCH:"
ls -la "${ENTITLEMENTS_DIR}/${ARCH}"

# Clean up temporary files
rm -f Containerfile.subs
rm -rf entitlements