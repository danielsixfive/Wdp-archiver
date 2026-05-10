#!/bin/bash
set -euo pipefail

CROPS_FILE="crops.txt"

if [ ! -f "$CROPS_FILE" ]; then
  echo "Error: $CROPS_FILE not found"
  exit 1
fi

# Collect all potential snapshots (any .png with "snapshot" in the name)
ALL_SNAPS=( *snapshot*.png )
if [ ${#ALL_SNAPS[@]} -eq 0 ]; then
  echo "No snapshot files found at all."
  exit 1
fi

# Current time in seconds since epoch
NOW_EPOCH=$(date +%s)

# Full regeneration mode (set FULL_REGEN=true in workflow to use all snapshots)
if [ "${FULL_REGEN:-false}" = "true" ]; then
  echo "Full regeneration requested – using all ${#ALL_SNAPS[@]} snapshots."
  SNAPSHOTS=("${ALL_SNAPS[@]}")
else
  # Filter to only snapshots from the last 24 hours
  SNAPSHOTS=()
  for s in "${ALL_SNAPS[@]}"; do
    # Extract timestamp part from filename, e.g., wdpsnapshot_20260509_223954.png -> 20260509_223954
    ts_part="${s#*snapshot_}"   # remove everything up to and including "snapshot_"
    ts_part="${ts_part%_crop}"  # safety if cropped frame sneaks in
    ts_part="${ts_part%.png}"   # remove extension

    # Reformat to YYYY-MM-DD HH:MM:SS
    ts_fmt="${ts_part:0:4}-${ts_part:4:2}-${ts_part:6:2} ${ts_part:9:2}:${ts_part:11:2}:${ts_part:13:2}"

    # Convert to epoch
    file_epoch=$(date -d "$ts_fmt" +%s 2>/dev/null || echo "0")
    if [ "$file_epoch" -eq 0 ]; then
      echo "  Skipping $s (could not parse date)" >&2
      continue
    fi

    if [ $(( NOW_EPOCH - file_epoch )) -le 86400 ]; then
      SNAPSHOTS+=("$s")
    fi
  done

  if [ ${#SNAPSHOTS[@]} -eq 0 ]; then
    echo "No snapshots from the last 24 hours found. Nothing to do."
    exit 0
  fi
fi

echo "Using ${#SNAPSHOTS[@]} snapshots."

# Normal delay between frames (1/100 sec)
NORMAL_DELAY=20
# Extra delay for the last frame (larger -> longer pause)
END_DELAY=100

# Read each crop definition
while read -r name x y w h outfile; do
  [[ -z "$name" || "$name" == \#* ]] && continue

  echo "--- Processing crop: $name -> $outfile ---"

  tmpdir="tmp_${name}"
  mkdir -p "$tmpdir"

  # Determine font size proportional to crop height (minimum 10px)
  FONT_SIZE=$(( h / 20 ))
  [ "$FONT_SIZE" -lt 10 ] && FONT_SIZE=10

  # Banner height: font size * 1.2, calculated using bc for floating-point
  BANNER_HEIGHT=$(echo "$FONT_SIZE * 1.2" | bc | cut -d'.' -f1)
  # Ensure minimum height to hold text comfortably
  if [ "$BANNER_HEIGHT" -lt "$((FONT_SIZE + 4))" ]; then
    BANNER_HEIGHT=$((FONT_SIZE + 4))
  fi

  i=0
  for snap in "${SNAPSHOTS[@]}"; do
    # Extract timestamp for overlay
    ts_part="${snap#*snapshot_}"
    ts_part="${ts_part%.png}"
    ts_fmt="${ts_part:0:4}-${ts_part:4:2}-${ts_part:6:2} ${ts_part:9:2}:${ts_part:11:2}:${ts_part:13:2}"

    outframe="${tmpdir}/frame_$(printf "%04d" $i).png"
    echo "  cropping & annotating $snap (${x},${y} ${w}x${h}) – $ts_fmt"

    CROPPED="${tmpdir}/temp_cropped_${i}.png"
    convert "$snap" -crop "${w}x${h}+${x}+${y}" +repage "$CROPPED"

    BANNER="${tmpdir}/temp_banner_${i}.png"
    convert -size "${w}x${BANNER_HEIGHT}" xc:black \
      -gravity Center \
      -pointsize "$FONT_SIZE" \
      -fill white \
      -annotate +0+0 "$ts_fmt" \
      "$BANNER"

    # Stack banner on top
    convert "$BANNER" "$CROPPED" -append +repage "$outframe"

    rm "$CROPPED" "$BANNER"
    i=$((i+1))
  done

  # Build GIF with end pause
  frame_files=("${tmpdir}"/*.png)
  last_frame="${tmpdir}/last_hold.png"
  cp "${frame_files[-1]}" "$last_frame"

  convert \
    -delay $NORMAL_DELAY "${frame_files[@]}" \
    -delay $END_DELAY "$last_frame" \
    -loop 0 \
    "$outfile"

  echo "  GIF saved: $outfile (${#frame_files[@]} frames + end pause)"
  rm -rf "$tmpdir"
done < "$CROPS_FILE"

echo "All crops processed."
