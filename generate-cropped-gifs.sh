#!/bin/bash
set -euo pipefail

CROPS_FILE="crops.txt"

if [ ! -f "$CROPS_FILE" ]; then
  echo "Error: $CROPS_FILE not found"
  exit 1
fi

# Collect snapshots (matches any .png with "snapshot" in the name)
SNAPSHOTS=( *snapshot*.png )
if [ ${#SNAPSHOTS[@]} -eq 0 ]; then
  echo "No snapshot files found."
  exit 1
fi

echo "Found ${#SNAPSHOTS[@]} snapshots."

# Read each line, split by any whitespace (space or tab)
while read -r name x y w h outfile; do
  # Skip blank or comment lines
  [[ -z "$name" || "$name" == \#* ]] && continue

  echo "--- Processing crop: $name -> $outfile ---"

  # Create a temp directory for this crop's frames
  tmpdir="tmp_${name}"
  mkdir -p "$tmpdir"

  # Crop every snapshot
  for snap in "${SNAPSHOTS[@]}"; do
    outframe="${tmpdir}/${snap%.png}_crop.png"
    echo "  cropping $snap (${x},${y} ${w}x${h})"
    convert "$snap" -crop "${w}x${h}+${x}+${y}" +repage "$outframe"
  done

  # Generate GIF from cropped frames (sorted alphabetically = timestamp order)
  convert -delay 20 -loop 0 "${tmpdir}"/*.png "$outfile"
  echo "  GIF saved: $outfile"

  # Clean up
  rm -rf "$tmpdir"
done < "$CROPS_FILE"

echo "All crops processed."
