#!/bin/bash

set -eo pipefail

# Make Sure The Environment Is Non-Interactive
export DEBIAN_FRONTEND=noninteractive

echo "::group:: Prepare Tools"
git clone --filter=blob:none https://github.com/ZeoRexDevs/EncToolZ ~/EncToolZ
rm -rf ~/EncToolZ/.git
chmod 755 /home/runner/EncToolZ/bento4/usr/bin/* /home/runner/EncToolZ/ftools/usr/bin/ff* /home/runner/EncToolZ/mtools/usr/bin/mkv* /home/runner/EncToolZ/rtools/usr/bin/r* /home/runner/EncToolZ/ytools/usr/bin/y*
export PATH="/home/runner/EncToolZ/bento4/usr/bin:/home/runner/EncToolZ/ftools/usr/bin:/home/runner/EncToolZ/mtools/usr/bin:/home/runner/EncToolZ/rtools/usr/bin:/home/runner/EncToolZ/ytools/usr/bin:${PATH}"
mkdir -p ~/.config/rclone
curl -sL "${RCLONE_CONFIG_URL}" >~/.config/rclone/rclone.conf
echo "::endgroup::"

echo "::group:: Prepare File"
function urld () { [[ "${1}" ]] || return 1; : "${1//+/ }"; echo -e "${_//%/\\x}"; }
export unsanitized_filename=$(awk -F'/' '{printf $NF}' <<<$(urld "${Input_Movie_Link}"))
export ConvertedName=$(sed 's/[()]//g;s/ - /\./g;s/ /\./g;s/,/\./g;s/&/and/g;s/\.\./\./g' <<<"${unsanitized_filename}")
printf "Downloading Media File, Please Wait...\n"
aria2c -c -x16 -s16 "${Input_Movie_Link}" -o ${ConvertedName} || {
  curl -sL "${Input_Movie_Link}" -o ${ConvertedName} || exit 1
}
printf "\nMediaInfo of the File:\n\n"
mediainfo "$ConvertedName"
echo "::endgroup::"

echo "::group:: Split Source Video"
export TotalFrames="$(mediainfo --Output='Video;%FrameCount%' ${ConvertedName})"
export ChunkDur="60"
FrameRate="$(mediainfo --Output='Video;%FrameRate%' ${ConvertedName})"
if [[ ${FrameRate} == "23.976" || ${FrameRate} == "24.000" ]]; then
  export FrameRate="24"
elif [[ ${FrameRate} == "25.000" ]]; then
  export FrameRate="25"
elif [[ ${FrameRate} == "29.970" || ${FrameRate} == "30.000" ]]; then
  export FrameRate="30"
fi
export ChunkFramecount="$((FrameRate * ChunkDur))"
export Partitions=$(( TotalFrames / ChunkFramecount ))
export Chunks=$((Partitions + 1))

printf "[!] The Source \"%s\" Has \"%s\" Frames With \"%s\" Frames Per Second\n" "${ConvertedName}" "${TotalFrames}" "${FrameRate}"
printf "    Expected Number of Video Chunks = %s\n\n" "${Chunks}"

printf "Getting Positional Information of I-frames ...\n\n"
LD_LIBRARY_PATH="/home/runner/EncToolZ/ftools/usr/lib:${LD_LIBRARY_PATH}" ffprobe \
  -hide_banner -loglevel warning -threads 2 -select_streams v -show_frames \
  -show_entries frame=pict_type -of csv ${ConvertedName} | grep -n I | cut -d ':' -f 1 > Iframe_indices.txt

printf "Getting GOP Boundaries for every Chunk\n\n"
BOUNDARY_GOP=""
for x in $(seq 1 ${Partitions}); do
  for i in $(< Iframe_indices.txt); do
    if [[ ${i} -lt "$((ChunkFramecount * x))" ]]; then continue; fi
    BOUNDARY_GOP+="$((i - 1))," && break
  done
done
BOUNDARY_GOP=$(echo ${BOUNDARY_GOP} | sed 's/,,$//;s/,$//')
if [[ $(( TotalFrames - ${BOUNDARY_GOP##*,} )) -le $(( ChunkFramecount / 4 )) ]]; then
  BOUNDARY_GOP=${BOUNDARY_GOP%,*}
fi
printf "[i] GOP Boundaries in Source Video:\n%s\n\n" "${BOUNDARY_GOP}"

printf "Splitting Source Video into Multiple Chunks\n\n"
mkdir -p SourceVideoChunks
LD_LIBRARY_PATH="/home/runner/EncToolZ/mtools/usr/lib:${LD_LIBRARY_PATH}" mkvmerge \
  --quiet --output SourceVideoChunks/${ConvertedName/mkv/part_%03d.mkv} -A -S -B -M -T \
  --no-global-tags --no-chapters --split frames:"${BOUNDARY_GOP}" "${ConvertedName}"

ls -lAog SourceVideoChunks
echo "::endgroup::"

echo "::group:: Upload Chunks"
printf "Wait Till All The Chunks Are Uploaded\n"
rclone copy SourceVideoChunks/ "${LocationOnIndex4MovieChunks}/${ConvertedName%.*}/SourceVideoChunks/" \
  && printf "All Chunks Have Been Uploaded Successfully\n"
echo "::endgroup::"
