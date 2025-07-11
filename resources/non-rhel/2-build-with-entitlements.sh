#!/bin/bash
set -e

# Default values
ARCH="x86_64"
ENTITLEMENTS_DIR="$HOME/.rh-entitlements"
PULL_SECRET_FILE="$HOME/.pull-secret.json"
CONTAINERFILE="Containerfile"
CONTEXT="."
IMAGE=""

usage() {
    echo "Usage: $0 [OPTIONS] -i IMAGE"
    echo ""
    echo "OPTIONS:"
    echo "  -i IMAGE             Container image name (required)"
    echo "  -a ARCH              Architecture (default: x86_64)"
    echo "  -e ENTITLEMENTS_DIR  Path to entitlements directory (default: ~/.rh-entitlements)"
    echo "  -s PULL_SECRET_FILE  Path to pull secret file (default: ~/.pull-secret.json)"
    echo "  -f CONTAINERFILE     Path to Containerfile (default: Containerfile)"
    echo "  -c CONTEXT           Build context directory (default: .)"
    echo "  -P                   Push image after build (default: false)"
    echo "  -h                   Show this help message"
    echo ""
    echo "Examples:"
    echo "  # Basic build"
    echo "  $0 -i myregistry.com/myimage:latest"
    echo ""
    echo "  # Build for arm64 with custom entitlements"
    echo "  $0 -i myregistry.com/myimage:latest -a arm64 -e /path/to/entitlements"
    echo ""
    echo "  # Build with custom Containerfile"
    echo "  $0 -i myregistry.com/myimage:latest -f custom.Containerfile -c /path/to/context"
    exit 1
}

while getopts "i:a:e:s:f:c:t:Ph" opt; do
    case $opt in
        i)
            IMAGE="$OPTARG"
            ;;
        a)
            ARCH="$OPTARG"
            ;;
        e)
            ENTITLEMENTS_DIR="$OPTARG"
            ;;
        s)
            PULL_SECRET_FILE="$OPTARG"
            ;;
        f)
            CONTAINERFILE="$OPTARG"
            ;;
        c)
            CONTEXT="$OPTARG"
            ;;
        P)
            PUSH_IMAGE=true
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

if [ -z "$IMAGE" ]; then
    echo "Error: Image name is required."
    echo "Use -i to specify the container image name."
    echo ""
    usage
fi

ENTITLEMENTS_DIR="${ENTITLEMENTS_DIR/#\~/$HOME}"
PULL_SECRET_FILE="${PULL_SECRET_FILE/#\~/$HOME}"
CONTAINERFILE="${CONTAINERFILE/#\~/$HOME}"
CONTEXT="${CONTEXT/#\~/$HOME}"

IMAGE="${IMAGE#http://}"
IMAGE="${IMAGE#https://}"
IMAGE="${IMAGE//\/\//\/}"


echo "Bootc Build Configuration"
echo "-------------------------"
echo "Architecture: $ARCH"
echo "Image: $IMAGE"
echo "Containerfile: $CONTAINERFILE"
echo "Build context: $CONTEXT"
echo "Pull-Secret file: $PULL_SECRET_FILE"
echo "Entitlements directory: ${ENTITLEMENTS_DIR}/${ARCH}"
echo "Push after build: $PUSH_IMAGE"
echo "-------------------------"
echo ""

# Validate required files and directories
if [ ! -f "$PULL_SECRET_FILE" ]; then
    echo "Error: Pull secret file not found at $PULL_SECRET_FILE"
    exit 1
fi

if [ ! -f "$CONTAINERFILE" ]; then
    echo "Error: Containerfile not found at $CONTAINERFILE"
    exit 1
fi

if [ ! -d "$CONTEXT" ]; then
    echo "Error: Build context directory not found at $CONTEXT"
    exit 1
fi

if [ ! -d "${ENTITLEMENTS_DIR}/${ARCH}" ]; then
    echo "Error: Entitlements directory not found at ${ENTITLEMENTS_DIR}/${ARCH}"
    echo "Please run the entitlements script first to generate entitlements for $ARCH"
    exit 1
fi

# Check if entitlements directory is empty
if [ -z "$(ls -A "${ENTITLEMENTS_DIR}/${ARCH}")" ]; then
    echo "Error: Entitlements directory is empty at ${ENTITLEMENTS_DIR}/${ARCH}"
    echo "Please run the entitlements script first to generate entitlements for $ARCH"
    exit 1
fi

# Setup cross-architecture support if needed
if [[ "$(uname -m)" != "$ARCH" ]]; then
    echo "Enabling binfmt_misc for cross-arch builds..."
    podman run --rm --privileged docker.io/multiarch/qemu-user-static --reset -p yes 2>/dev/null \
        || echo "binfmt setup completed (some handlers may have already existed)"
else
    echo "Host architecture matches target ($ARCH), no binfmt setup needed."
fi

echo "Building image for $ARCH..."

echo "Running: build --authfile $PULL_SECRET_FILE --platform $ARCH -f $CONTAINERFILE -t $IMAGE -v ${ENTITLEMENTS_DIR}:/run/secrets:z $CONTEXT"


podman build \
    --authfile "$PULL_SECRET_FILE" \
    --platform "$ARCH" \
    -f "$CONTAINERFILE" \
    -t "$IMAGE" \
    -v "${ENTITLEMENTS_DIR}/${ARCH}:/run/secrets:z" \
    "$CONTEXT"

echo "Build completed successfully!"
echo "Image tagged as: $IMAGE"

