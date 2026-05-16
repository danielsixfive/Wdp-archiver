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

NOW_EPOCH=$(date +%s)

# Helper: extract epoch seconds from a snapshot filename
get_epoch() {
  local f="$1"
  local ts_part="${f#*snapshot_}"
  ts_part="${ts_part%_crop}"
  ts_part="${ts_part%.png}"
  local ts_fmt="${ts_part:0:4}-${ts_part:4:2}-${ts_part:6:2} ${ts_part:9:2}:${ts_part:11:2}:${ts_part:13:2}"
  date -d "$ts_fmt" +%s 2>/dev/null || echo "0"
}

echo "Total snapshots available: ${#ALL_SNAPS[@]}"

# Read each crop definition
while read -r name x y w h outfile time_min interval_min delay; do
  [[ -z "$name" || "$name" == \#* ]] && continue

  # Set defaults if columns are missing
  time_min="${time_min:-1440}"      # 24 hours in minutes
  interval_min="${interval_min:-0}"
  normal_delay="${delay:-10}"       # in 1/100 s

  # Compute time window and interval in seconds
  local TIME_WINDOW_SEC=$(( time_min * 60 ))
  local INTERVAL_SEC=$(( interval_min * 60 ))

  # End delay = max(100, 2 * normal_delay)
  local END_DELAY=$(( 2 * normal_delay ))
  [ "$END_DELAY" -lt 100 ] && END_DELAY=100

  echo "--- Processing crop: $name -> $outfile ---"
  echo "  time window: ${time_min} min, interval: ${interval_min} min, delay: ${normal_delay}, end delay: ${END_DELAY}"

  # Determine which snapshots to use
  local CROP_SNAPS=()
  if [ "${FULL_REGEN:-false}" = "true" ]; then
    # Use all snapshots (ignore time window but still apply interval if >0)
    echo "  Full regeneration mode – using all snapshots"
    CROP_SNAPS=("${ALL_SNAPS[@]}")
  else
    # Filter by time window
    for s in "${ALL_SNAPS[@]}"; do
      local epoch=$(get_epoch "$s")
      if [ "$epoch" -ne 0 ] && [ $(( NOW_EPOCH - epoch )) -le "$TIME_WINDOW_SEC" ]; then
        CROP_SNAPS+=("$s")
      fi
    done
  fi

  if [ ${#CROP_SNAPS[@]} -eq 0 ]; then
    echo "  No snapshots in time window – skipping."
    continue
  fi

  # If interval > 0, subsample the snapshots (walk from newest to oldest)
  if [ "$INTERVAL_SEC" -gt 0 ]; then
    local SUBSAMPLED=()
    # sort by epoch descending (newest first)
    local sorted
    sorted=$(for s in "${CROP_SNAPS[@]}"; do
               printf "%s\t%s\n" "$(get_epoch "$s")" "$s"
             done | sort -rn)
    local last_epoch=""
    while IFS=$'\t' read -r ep snap; do
      if [ -z "$last_epoch" ] || [ $(( last_epoch - ep )) -ge "$INTERVAL_SEC" ]; then
        SUBSAMPLED+=("$snap")
        last_epoch="$ep"
      fi
    done <<< "$sorted"
    # Reverse to chronological order (oldest first)
    local tmp=()
    for (( idx=${#SUBSAMPLED[@]}-1; idx>=0; idx-- )); do
      tmp+=("${SUBSAMPLED[idx]}")
    done
    CROP_SNAPS=("${tmp[@]}")
    echo "  Subsampled to ${#CROP_SNAPS[@]} snapshots (interval ${interval_min} min)"
  fi

  if [ ${#CROP_SNAPS[@]} -eq 0 ]; then
    echo "  No snapshots after subsampling – skipping."
    continue
  fi

  # Create temporary directory for frames
  local tmpdir="tmp_${name}"
  mkdir -p "$tmpdir"

  # Determine font size proportional to crop height (minimum 10px)
  FONT_SIZE=$(( h / 20 ))
  [ "$FONT_SIZE" -lt 10 ] && FONT_SIZE=10

  # Banner height: font size * 1.2, using bc for floating-point
  BANNER_HEIGHT=$(echo "$FONT_SIZE * 1.2" | bc | cut -d'.' -f1)
  if [ "$BANNER_HEIGHT" -lt "$((FONT_SIZE + 4))" ]; then
    BANNER_HEIGHT=$((FONT_SIZE + 4))
  fi

  local i=0
  for snap in "${CROP_SNAPS[@]}"; do
    ts_part="${snap#*snapshot_}"
    ts_part="${ts_part%.png}"
    ts_fmt="${ts_part:0:4}-${ts_part:4:2}-${ts_part:6:2} ${ts_part:9:2}:${ts_part:11:2}:${ts_part:13:2}"

    local outframe="${tmpdir}/frame_$(printf "%04d" $i).png"
    echo "  frame $i: $snap (${x},${y} ${w}x${h}) – $ts_fmt"

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
  local frame_files=("${tmpdir}"/*.png)
  local last_frame="${tmpdir}/last_hold.png"
  cp "${frame_files[-1]}" "$last_frame"

  convert \
    -delay "$normal_delay" "${frame_files[@]}" \
    -delay "$END_DELAY" "$last_frame" \
    -loop 0 \
    "$outfile"

  echo "  GIF saved: $outfile (${#frame_files[@]} frames + end pause)"
  rm -rf "$tmpdir"
done < "$CROPS_FILE"

echo "All crops processed."
