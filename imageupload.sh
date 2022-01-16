##!/bin/bash

imgdir=$( dialog "${optbox[@]}" --title 'Image file:' --stdout --dselect $PWD/ 20 40 )
imgfiles=$( ls -1 "$imgdir"/rAudio*.img.xz 2> /dev/null )
[[ -z $imgfiles ]] && echo "No image files found in $imgdir" && exit

optbox=( --colors --no-shadow --no-collapse )

dialog "${optbox[@]}" --yesno "
\Z1Image files list:\Z0

$imgfiles

" 0 0
[[ $? != 0 ]] && exit

user=rern
repo=rAudio-1
release=i$( echo ${imgfiles[0]/*-} | cut -d. -f1 )
token=$( dialog "${optbox[@]}" --output-fd 1 --nocancel --inputbox "
Token: (https://github.com/settings/tokens)
" 9 50 )
id=$( curl -sH "Authorization: token $token" \
		https://api.github.com/repos/$user/$repo/releases/tags/$release \
		| jq .id )

col=$( tput cols )

dialog "${optbox[@]}" --output-fd 1 --msgbox "
Make sure release \Z1$release\Z0 exists.
" 7 50

banner() {
	echo
	def='\e[0m'
	bg='\e[44m'
    printf "$bg%*s$def\n" $col
    printf "$bg%-${col}s$def\n" "  $1"
    printf "$bg%*s$def\n" $col
}

imageUpload() {
	file="$1"
	filename=$( basename "$file" )
	
	banner "$filename"
	
	curl \
		-H "Authorization: token $token" \
		-H "Content-Type: application/x-xz" \
		--data-binary @"$file" \
		"https://uploads.github.com/repos/$user/$repo/releases/$id/assets?name=$filename" \
		| jq
}

echo
banner "rAudio Image Files: $release"

readarray -t imgfiles <<< "$imgfiles"
for file in "${imgfiles[@]}"; do
	imageUpload "$file"
done
