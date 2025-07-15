#!/bin/bash
set -euo pipefail

OCI_DISK_IMAGE_REPO=""
OCI_IMAGE_TAG="latest"
OUTPUT_DIR="output-diskimage"

usage() {
  cat <<EOF
Usage: $0 -i <image[:tag]> [-o <output-dir>]

Options:
  -i <image[:tag]>   OCI disk image repo with optional tag (e.g. quay.io/user/repo:tag) [required]
  -o <output-dir>    Output directory (default: output-diskimage)
  -h                 Show this help message
EOF
  exit 1
}

while getopts ":i:o:h" opt; do
  case $opt in
    i)
      full_image="$OPTARG"
      # Default tag
      OCI_IMAGE_TAG="latest"
      # If full_image contains a colon after last slash, split
      # Extract last part after slash
      last_part="${full_image##*/}"
      if [[ "$last_part" == *":"* ]]; then
        OCI_DISK_IMAGE_REPO="${full_image%:*}"
        OCI_IMAGE_TAG="${full_image##*:}"
      else
        OCI_DISK_IMAGE_REPO="$full_image"
      fi
      ;;
    o) OUTPUT_DIR="$OPTARG" ;;
    h) usage ;;
    \?) echo "Invalid option: -$OPTARG" >&2; usage ;;
    :) echo "Option -$OPTARG requires an argument." >&2; usage ;;
  esac
done

if [[ -z "$OCI_DISK_IMAGE_REPO" ]]; then
  echo "Error: -i <image[:tag]> is required" >&2
  usage
fi

echo "Extracting contents from ${OCI_DISK_IMAGE_REPO}:${OCI_IMAGE_TAG}"
echo "skopeo copy docker://${OCI_DISK_IMAGE_REPO}:${OCI_IMAGE_TAG} dir:${OUTPUT_DIR}"
skopeo copy "docker://${OCI_DISK_IMAGE_REPO}:${OCI_IMAGE_TAG}" "dir:${OUTPUT_DIR}"

media_type=$(jq -r '.layers[0].mediaType' "${OUTPUT_DIR}/manifest.json")

case "$media_type" in
  application/*.iso)  ext="iso" ; echo "Media: iso" ;;
  application/*.qcow2) ext="qcow2"  ; echo "Media: qcow2" ;;
  application/*.vmdk) ext="vmdk" ; echo "Media: vmdk" ;;
  application/*.raw)  ext="raw" ; echo "Media: raw" ;;
  application/*.ami)  ext="ami" ; echo "Media: ami" ;;
  application/*.vhd)  ext="vhd" ; echo "Media: vhd" ;;
  application/*.gce)  ext="gce" ; echo "Media: gce" ;;
  *)
    echo "Error: Unknown media type '$media_type'" >&2
    exit 1
    ;;
esac

disk_file=$(find "$OUTPUT_DIR" -type f ! -name 'manifest.json' ! -name 'version' ! -name '*.json')
echo "Disk file: $disk_file"

#mv "$disk_file" "${OUTPUT_DIR}/disk.${ext}"
echo "✅ Extracted disk image: ${OUTPUT_DIR}/disk.${ext}"
