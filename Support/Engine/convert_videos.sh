#!/bin/bash
set -u

usage() {
  cat <<'EOF'
Usage: convert_videos.sh --source FOLDER --destination FOLDER [options]

Options:
  --jobs 1..4                         Parallel conversions (default: 2)
  --resolution 720p|1080p|2160p|original
                                      Maximum output size (default: 1080p)
  --quality low|medium|high|very-high
                                      SDR quality/file-size preset (default: high)

Converts MOV/MP4 videos to HEVC on Apple Silicon. Originals are read-only.
Capture time and QuickTime GPS coordinates are preserved and verified.
EOF
}

die() { printf '[FATAL] %s\n' "$*"; exit 2; }
hash_for() { md5 -q -s "$1"; }

configure_profile() {
  case "$target_resolution" in
    720p) max_long=1280; max_short=720; av_preset=PresetHEVC1920x1080 ;;
    1080p) max_long=1920; max_short=1080; av_preset=PresetHEVC1920x1080 ;;
    2160p) max_long=3840; max_short=2160; av_preset=PresetHEVC3840x2160 ;;
    original) max_long=0; max_short=0; av_preset=PresetHEVCHighestQuality ;;
    *) die "Invalid resolution preset: $target_resolution" ;;
  esac
  case "$quality" in
    low) quality_value=35; use_multipass=0 ;;
    medium) quality_value=50; use_multipass=0 ;;
    high) quality_value=60; use_multipass=1 ;;
    very-high) quality_value=75; use_multipass=1 ;;
    *) die "Invalid quality preset: $quality" ;;
  esac
}

probe_json() {
  ffprobe -v error -show_entries \
    stream=index,codec_type,codec_name,codec_tag_string,profile,width,height,pix_fmt,r_frame_rate,avg_frame_rate,color_space,color_transfer,color_primaries:stream_disposition:stream_side_data:format=duration,nb_streams:format_tags \
    -of json "$1"
}

core_signature() {
  exiftool -api QuickTimeUTC=1 -n -G1 -a -j \
    -QuickTime:CreateDate -Keys:CreationDate '-*GPSCoordinates*' "$1" 2>/dev/null \
    | jq -Sc '.[0] | {
        createDate: .["QuickTime:CreateDate"],
        localCreationDate: .["Keys:CreationDate"],
        gps: ([to_entries[] | select(.key | test("GPSCoordinates")) | .value] | first)
      }'
}

restore_core_metadata() {
  local src="$1" out="$2"
  exiftool -overwrite_original -api QuickTimeUTC=1 \
    -TagsFromFile "$src" \
    -QuickTime:CreateDate -QuickTime:ModifyDate \
    -Keys:CreationDate -Keys:GPSCoordinates \
    '-FileModifyDate<FileModifyDate' "$out" >/dev/null
}

active_video_packets() {
  ffprobe -v error -select_streams V:0 -show_packets -show_entries packet=flags \
    -of default=nw=1:nk=1 "$1" 2>/dev/null \
    | awk '$0 !~ /D/{n++} END{print n+0}'
}

verify_output() {
  local src="$1" out="$2" sj="$3" oj="$4" sp op valid
  [ -s "$out" ] || return 2
  probe_json "$src" > "$sj" || return 2
  probe_json "$out" > "$oj" || return 2
  sp=$(active_video_packets "$src")
  op=$(active_video_packets "$out")
  valid=$(jq -n --arg sp "$sp" --arg op "$op" --arg target "$target_resolution" \
    --argjson maxLong "$max_long" --argjson maxShort "$max_short" \
    --slurpfile s "$sj" --slurpfile o "$oj" '
    def v($x): [$x.streams[] | select(.codec_type=="video" and (.disposition.attached_pic//0)==0)][0];
    def videos($x): [$x.streams[] | select(.codec_type=="video")];
    def coreaudio($x): [$x.streams[] | select(.codec_type=="audio" and .codec_name!="apple_apac") | .codec_name];
    def rot($x): ((v($x).side_data_list//[] | map(select(has("rotation")) | .rotation) | first)//0);
    def crop($x): ((v($x).side_data_list//[] | map(select(.side_data_type=="Frame Cropping")) | first)//{});
    def dims($x): [(v($x).width-(crop($x).crop_left//0)-(crop($x).crop_right//0)),
                   (v($x).height-(crop($x).crop_top//0)-(crop($x).crop_bottom//0))] as $d |
                  if ((rot($x)|fabs)==90) then [$d[1],$d[0]] else $d end;
    def long($d): [$d[0],$d[1]]|max;
    def short($d): [$d[0],$d[1]]|min;
    def dv($x): ((v($x).side_data_list//[]) | map(select(.side_data_type=="DOVI configuration record")) | length);
    ($s[0]) as $a | ($o[0]) as $b | (dims($a)) as $sd | (dims($b)) as $od |
    (if $target=="720p" and ((dv($a)>0) or ((v($a).pix_fmt//"")|contains("10")))
     then [1920,1080] else [$maxLong,$maxShort] end) as $limits |
    (if $limits[0]==0 then 1 else ([1,$limits[0]/long($sd),$limits[1]/short($sd)]|min) end) as $scale |
    [
      ((videos($b)|length)==1),
      (v($b).codec_name=="hevc"),
      (((($a.format.duration|tonumber)-($b.format.duration|tonumber))|fabs)<=0.15),
      (($sp!="") and ($sp==$op)),
      (((long($od)-(long($sd)*$scale))|fabs)<=4),
      (((short($od)-(short($sd)*$scale))|fabs)<=4),
      (((($sd[0]/$sd[1])-($od[0]/$od[1]))|fabs)<=0.01),
      ((dv($a)==0) or (dv($b)>0)),
      (((v($a).pix_fmt//"")|contains("10")|not) or ((v($b).pix_fmt//"")|contains("10"))),
      (((v($a).color_transfer//"")=="") or ((v($a).color_transfer//"")== (v($b).color_transfer//""))),
      (((v($a).color_primaries//"")=="") or ((v($a).color_primaries//"")== (v($b).color_primaries//""))),
      (coreaudio($a)==coreaudio($b))
    ] | all')
  [ "$valid" = true ] || return 3
  cmp -s <(core_signature "$src") <(core_signature "$out") || return 4
  return 0
}

safe_parts() {
  local stem="$1"
  if [[ "$stem" == */* ]]; then
    SAFE_DIR=${stem%/*}; SAFE_BASE=${stem##*/}
  else
    SAFE_DIR=.; SAFE_BASE=$stem
  fi
}

park_file() {
  local file="$1" reason="$2" stem="$3" hash="$4" folder
  safe_parts "$stem"
  folder="$problem_dir/$reason/$hash/$SAFE_DIR"
  mkdir -p "$folder"
  mv "$file" "$folder/$SAFE_BASE.mov"
}

write_error() {
  local row="$1" rel="$2" mode="$3" message="$4" size
  size=$(stat -f '%z' "$source_dir/$rel" 2>/dev/null || printf 0)
  printf '%s\tERROR\t%s\t%s\t0\t0\t\t\tFAILED\t%s\n' "$rel" "$mode" "$size" "$message" > "$row"
}

write_success() {
  local src="$1" rel="$2" out="$3" row="$4" mode="$5" sj="$6" oj="$7" note="$8"
  local old_size new_size saving codec dims
  old_size=$(stat -f '%z' "$src"); new_size=$(stat -f '%z' "$out")
  saving=$(awk -v a="$old_size" -v b="$new_size" 'BEGIN{printf "%.2f",100*(a-b)/a}')
  codec=$(jq -r '[.streams[]|select(.codec_type=="video")][0].codec_name//""' "$oj")
  dims=$(jq -r '[.streams[]|select(.codec_type=="video")][0] | "\(.width)x\(.height)"' "$oj")
  printf '%s\tSUCCESS\t%s\t%s\t%s\t%s\t%s\t%s\tOK\t%s\n' \
    "$rel" "$mode" "$old_size" "$new_size" "$saving" "$codec" "$dims" "$note" > "$row"
}

progress_line() {
  local complete ok failed counts
  counts=$(find "$rows_dir" -type f -name '*.tsv' -exec cat {} + 2>/dev/null \
    | awk -F '\t' '{n++; if($2=="SUCCESS")ok++; else if($2=="ERROR")bad++} END{printf "%d %d %d",n,ok,bad}')
  read -r complete ok failed <<< "$counts"
  printf '[PROGRESS] %s %s %s %s\n' "$complete" "$total_files" "$ok" "$failed"
}

convert_worker() {
  local src="$1" rel stem hash row log out raw sj oj recovered
  local total_video main_video attached codec pix width height long short dv mode note rc fits_target
  rel=${src#"$source_dir"/}; stem=${rel%.*}; hash=$(hash_for "$rel")
  row="$rows_dir/$hash.tsv"; log="$logs_dir/$hash.log"
  raw="$work_dir/$hash.mov"; out="$destination_dir/$stem.mov"
  sj="$work_dir/$hash.src.json"; oj="$work_dir/$hash.out.json"

  if [ -e "$out" ]; then
    if verify_output "$src" "$out" "$sj" "$oj"; then
      write_success "$src" "$rel" "$out" "$row" "existing" "$sj" "$oj" "Existing output verified"
      printf '[OK] %s (already exists)\n' "$rel"; progress_line; return 0
    fi
    park_file "$out" "Invalid_existing_output" "$stem" "$hash"
  fi

  recovered="$problem_dir/Verification_failed_4/$hash/$stem.mov"
  if [ -e "$recovered" ] && verify_output "$src" "$recovered" "$sj" "$oj"; then
    mkdir -p "$(dirname "$out")"
    mv "$recovered" "$out"
    write_success "$src" "$rel" "$out" "$row" "recovered" "$sj" "$oj" \
      "Recovered a previously encoded file after canonical metadata verification"
    printf '[RECOVERED] %s — no re-encoding required\n' "$rel"
    progress_line
    return 0
  fi

  [ ! -e "$raw" ] || park_file "$raw" "Incomplete" "$stem" "$hash"
  probe_json "$src" > "$sj" || { write_error "$row" "$rel" probe "Source is unreadable"; printf '[ERROR] %s\n' "$rel"; progress_line; return 1; }

  total_video=$(jq '[.streams[]|select(.codec_type=="video")]|length' "$sj")
  main_video=$(jq '[.streams[]|select(.codec_type=="video" and (.disposition.attached_pic//0)==0)]|length' "$sj")
  attached=$(jq '[.streams[]|select(.codec_type=="video" and (.disposition.attached_pic//0)==1)]|length' "$sj")
  [ "$main_video" -eq 1 ] || { write_error "$row" "$rel" streams "Expected exactly one primary video track"; printf '[ERROR] %s — multiple primary video tracks\n' "$rel"; progress_line; return 1; }
  codec=$(jq -r '[.streams[]|select(.codec_type=="video" and (.disposition.attached_pic//0)==0)][0].codec_name//""' "$sj")
  pix=$(jq -r '[.streams[]|select(.codec_type=="video" and (.disposition.attached_pic//0)==0)][0].pix_fmt//""' "$sj")
  width=$(jq -r '[.streams[]|select(.codec_type=="video" and (.disposition.attached_pic//0)==0)][0].width//0' "$sj")
  height=$(jq -r '[.streams[]|select(.codec_type=="video" and (.disposition.attached_pic//0)==0)][0].height//0' "$sj")
  dv=$(jq '[.streams[]|select(.codec_type=="video" and (.disposition.attached_pic//0)==0)][0].side_data_list//[]|map(select(.side_data_type=="DOVI configuration record"))|length' "$sj")
  if [ "$width" -gt "$height" ]; then long=$width; short=$height; else long=$height; short=$width; fi

  fits_target=1
  if [ "$max_long" -gt 0 ] && { [ "$long" -gt "$max_long" ] || [ "$short" -gt "$max_short" ]; }; then
    fits_target=0
  fi

  if [ "$codec" = hevc ] && [ "$fits_target" -eq 1 ] && [ "$attached" -eq 0 ]; then
    mode="Copy"
    note="Already compatible HEVC; copied without quality loss"
    printf '[START] %s — Copy\n' "$rel"
    cp -p "$src" "$raw" >"$log" 2>&1 || rc=$?
  elif [ "$dv" -gt 0 ] || [[ "$pix" == *10* ]]; then
    mode="HDR"
    note="10-bit HDR/Dolby Vision preserved; optional Apple auxiliary tracks may be omitted"
    if [ "$target_resolution" = 720p ]; then
      note="$note; Apple HDR export uses 1080p as its smallest HEVC preset"
      printf '[NOTICE] %s — Apple HDR export uses a 1080p minimum\n' "$rel"
    fi
    printf '[START] %s — HDR\n' "$rel"
    if [ "$use_multipass" -eq 1 ]; then
      /usr/bin/avconvert --source "$src" --preset "$av_preset" \
        --output "$raw" --disableMetadataFilter --multiPass --progress >"$log" 2>&1
    else
      /usr/bin/avconvert --source "$src" --preset "$av_preset" \
        --output "$raw" --disableMetadataFilter --progress >"$log" 2>&1
    fi
    rc=$?
    if [ "$use_multipass" -eq 1 ] && { [ "$rc" -ne 0 ] || [ ! -s "$raw" ]; }; then
      rm -f "$raw"
      printf '[RETRY] %s — single-pass HDR\n' "$rel"
      /usr/bin/avconvert --source "$src" --preset "$av_preset" \
        --output "$raw" --disableMetadataFilter --progress >>"$log" 2>&1
      rc=$?
    fi
  else
    mode="SDR"
    if [ "$total_video" -gt 1 ]; then note="Embedded preview image removed"; else note="HEVC hardware encoding"; fi
    if [ "$target_resolution" = original ]; then max_long=$long; max_short=$short; fi
    printf '[START] %s — SDR\n' "$rel"
    ffmpeg -hide_banner -y -noautorotate -i "$src" \
      -map 0:V:0 -map '0:a?' -map_metadata 0 -map_chapters 0 \
      -c copy -c:v hevc_videotoolbox -profile:v main -q:v "$quality_value" \
      -vf "scale=w='if(gte(iw,ih),min($max_long,iw),min($max_short,iw))':h='if(gte(iw,ih),min($max_short,ih),min($max_long,ih))':force_original_aspect_ratio=decrease:force_divisible_by=2:flags=lanczos" \
      -fps_mode passthrough -tag:v hvc1 -movflags use_metadata_tags "$raw" >"$log" 2>&1
    rc=$?
  fi

  rc=${rc:-0}
  if [ "$rc" -ne 0 ] || [ ! -s "$raw" ]; then
    [ ! -e "$raw" ] || park_file "$raw" "Conversion_failed" "$stem" "$hash"
    write_error "$row" "$rel" "$mode" "Conversion failed; see log"
    printf '[ERROR] %s — conversion\n' "$rel"; progress_line; return 1
  fi
  if ! restore_core_metadata "$src" "$raw" >>"$log" 2>&1; then
    park_file "$raw" "Metadata_failed" "$stem" "$hash"
    write_error "$row" "$rel" "$mode" "Core metadata could not be written"
    printf '[ERROR] %s — metadata\n' "$rel"; progress_line; return 1
  fi
  verify_output "$src" "$raw" "$sj" "$oj"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    park_file "$raw" "Verification_failed_$rc" "$stem" "$hash"
    write_error "$row" "$rel" "$mode" "Post-conversion verification failed (code $rc)"
    printf '[ERROR] %s — verification %s\n' "$rel" "$rc"; progress_line; return 1
  fi

  mkdir -p "$(dirname "$out")"
  mv "$raw" "$out"
  write_success "$src" "$rel" "$out" "$row" "$mode" "$sj" "$oj" "$note; capture time and GPS verified"
  printf '[OK] %s\n' "$rel"; progress_line
}

build_report() {
  printf 'File\tStatus\tMode\tOriginal_Bytes\tOutput_Bytes\tSavings_Percent\tCodec\tResolution\tMetadata\tNote\n' > "$report_file"
  find "$rows_dir" -type f -name '*.tsv' -exec cat {} + | LC_ALL=C sort >> "$report_file"
  awk -F '\t' 'NR>1{n++;a+=$4;b+=$5;if($2=="SUCCESS")ok++;else bad++}END{printf "Videos: %d\nSucceeded: %d\nFailed: %d\nOriginal (bytes): %.0f\nOutput (bytes): %.0f\nSaved (bytes): %.0f\nSaved (percent): %.2f\n",n,ok,bad,a,b,a-b,(a?100*(a-b)/a:0)}' \
    "$report_file" > "$summary_file"
}

if [ "${1:-}" = --worker ]; then
  source_dir=$MVC_SOURCE_DIR; destination_dir=$MVC_DESTINATION_DIR
  work_dir=$MVC_WORK_DIR; rows_dir=$MVC_ROWS_DIR; logs_dir=$MVC_LOGS_DIR
  problem_dir=$MVC_PROBLEM_DIR; total_files=$MVC_TOTAL_FILES
  target_resolution=$MVC_TARGET_RESOLUTION; quality=$MVC_QUALITY
  configure_profile
  convert_worker "$2"
  exit
fi

source_dir=""; destination_dir=""; jobs=2; target_resolution=1080p; quality=high
while [ "$#" -gt 0 ]; do
  case "$1" in
    --source) source_dir=${2:-}; shift 2 ;;
    --destination) destination_dir=${2:-}; shift 2 ;;
    --jobs) jobs=${2:-}; shift 2 ;;
    --resolution) target_resolution=${2:-}; shift 2 ;;
    --quality) quality=${2:-}; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done
configure_profile
[ -d "$source_dir" ] || die "Source folder does not exist."
[ -n "$destination_dir" ] || die "No destination folder was provided."
case "$jobs" in ''|*[!0-9]*) die "The job count must be a number.";; esac
[ "$jobs" -ge 1 ] && [ "$jobs" -le 4 ] || die "One to four parallel jobs are supported."
for tool in ffmpeg ffprobe exiftool jq md5; do
  command -v "$tool" >/dev/null 2>&1 || die "Missing dependency: $tool. See README."
done
[ "$(uname -m)" = arm64 ] || die "This program requires an Apple Silicon Mac."
[ -x /usr/bin/avconvert ] || die "Apple's avconvert tool was not found."

mkdir -p "$destination_dir"
source_dir=$(cd "$source_dir" && pwd -P)
destination_dir=$(cd "$destination_dir" && pwd -P)
[ "$source_dir" != "$destination_dir" ] || die "Source and destination must be different."
case "$destination_dir/" in "$source_dir/"*) die "The destination must not be inside the source folder.";; esac

state_dir="$destination_dir/.mseries-video-converter"
work_dir="$state_dir/work"; rows_dir="$state_dir/rows"; logs_dir="$state_dir/logs"
problem_dir="$destination_dir/Problems"
report_file="$destination_dir/conversion-report.tsv"
summary_file="$destination_dir/summary.txt"
mkdir -p "$work_dir" "$rows_dir" "$logs_dir" "$problem_dir"
candidate_file="$state_dir/candidates.nul"
source_marker="$state_dir/source-folder.txt"
if [ -f "$source_marker" ] && [ "$(cat "$source_marker")" != "$source_dir" ]; then
  die "This destination belongs to a different source folder. Choose an empty destination."
fi
settings_marker="$state_dir/settings.txt"
settings="$target_resolution/$quality"
if [ -f "$settings_marker" ] && [ "$(cat "$settings_marker")" != "$settings" ]; then
  die "This destination was created with different output settings. Choose an empty destination."
fi
if [ -f "$source_marker" ] && [ ! -f "$settings_marker" ] && [ "$settings" != "1080p/high" ]; then
  die "This legacy destination uses the 1080p/high defaults. Choose an empty destination for different settings."
fi
printf '%s\n' "$source_dir" > "$source_marker"
printf '%s\n' "$settings" > "$settings_marker"

printf '[SCAN] Searching for MOV and MP4 files…\n'
find "$source_dir" -type f \( -iname '*.mov' -o -iname '*.mp4' \) -print0 > "$candidate_file"
total_files=$(LC_ALL=C tr -cd '\000' < "$candidate_file" | wc -c | tr -d ' ')
[ "$total_files" -gt 0 ] || die "No videos were found in the source folder."
printf '[SCAN] %s videos found; %s parallel jobs; %s; %s quality\n' "$total_files" "$jobs" "$target_resolution" "$quality"

export MVC_SOURCE_DIR="$source_dir" MVC_DESTINATION_DIR="$destination_dir"
export MVC_WORK_DIR="$work_dir" MVC_ROWS_DIR="$rows_dir" MVC_LOGS_DIR="$logs_dir"
export MVC_PROBLEM_DIR="$problem_dir" MVC_TOTAL_FILES="$total_files"
export MVC_TARGET_RESOLUTION="$target_resolution" MVC_QUALITY="$quality"

batch_pid=""
stop_batch() {
  printf '[STOP] Stopping; completed files remain available.\n'
  [ -z "$batch_pid" ] || kill -TERM "$batch_pid" 2>/dev/null || true
  [ -z "$batch_pid" ] || pkill -TERM -P "$batch_pid" 2>/dev/null || true
  exit 130
}
trap stop_batch INT TERM HUP

xargs -0 -n 1 -P "$jobs" "$0" --worker < "$candidate_file" &
batch_pid=$!
wait "$batch_pid"
batch_rc=$?
build_report
progress_line
cat "$summary_file"
exit "$batch_rc"
