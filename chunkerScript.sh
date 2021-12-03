#!/bin/bash

set -eo pipefail

# Make Sure The Environment Is Non-Interactive
export DEBIAN_FRONTEND=noninteractive

echo "::group:: Prepare Tools"
sudo apt-fast install mkvtoolnix -qqy
curl -sL https://rclone.org/install.sh | sudo bash 1>/dev/null
mkdir -p ~/.config/rclone
curl -sL "${RCLONE_CONFIG_URL}" > ~/.config/rclone/rclone.conf
cd "$(mktemp -d)"
wget -q $(curl -H "Accept: application/vnd.github.v3+json" -s "${FTOOL_API}" | jq -r '.assets[] | select(.browser_download_url | contains("linux64-nonfree-4.4.tar.xz")) | .browser_download_url')
tar -xJf ff*.tar.xz --strip-components 1
sudo mv bin/* /usr/local/bin/
cd -
echo "::endgroup::"

echo "::group:: Prepare File"
set -xv
printf "Downloading Media File, Please Wait...\n"
aria2c -c -x16 -s16 \"${Input_Movie_Link}\" . || {
  aria2c -c -x16 -s16 "'"${Input_Movie_Link}"'" . || exit 1
}
export ConvertedName="${Input_Movie_Link##*/}"
set +xv
printf "\nMediaInfo of the File:\n\n"
mediainfo "$ConvertedName"
echo "::endgroup::"

echo "::group:: Split Source Video"
export TotalFrames="$(mediainfo --Output='Video;%FrameCount%' ${ConvertedName})"
export ChunkDur="120"
FrameRate="$(mediainfo --Output='Video;%FrameRate%' ${ConvertedName})"
if [[ ${FrameRate} == "23.976" || ${FrameRate} == "24.000" ]]; then
  export FrameRate="24"
elif [[ ${FrameRate} == "25.000" ]]; then
  export FrameRate="25"
elif [[ ${FrameRate} == "29.976" ]]; then
  export FrameRate="30"
fi
export ChunkFramecount="$((FrameRate * ChunkDur))"
export Partitions=$(( TotalFrames / ChunkFramecount ))
export Chunks=$((Partitions + 1))

printf "[!] The Source \"%s\" Has \"%s\" Frames With \"%s\" Frames Per Second\n" "${ConvertedName}" "${TotalFrames}" "${FrameRate}"
printf "    Expected Number of Video Chunks = %s\n\n" "${Chunks}"

printf "Getting Positional Information of I-frames ...\n\n"
ffprobe -hide_banner -loglevel warning -threads 8 -select_streams v -show_frames \
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
mkvmerge --quiet --output SourceVideoChunks/${ConvertedName/mkv/part_%02d.mkv} -A -S -B -M -T \
  --no-global-tags --no-chapters --split frames:"${BOUNDARY_GOP}" "${ConvertedName}"

ls -lAog SourceVideoChunks
echo "::endgroup::"

echo "::group:: Upload Chunks"
printf "Wait Till All The Chunks Are Uploaded\n"
rclone copy SourceVideoChunks/ "${LocationOnIndex4MovieChunks}/${ConvertedName%.*}/SourceVideoChunks/" && printf "All Chunks Have Been Uploaded Successfully\n"
echo "::endgroup::"
